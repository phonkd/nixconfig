{
  self,
  inputs,
  ...
}:
{
  flake.nixosModules.homelab-traefik =
    {
      config,
      pkgs,
      lib,
      noughtyLib,
      ...
    }:
    let
      # apps are sourced across all nixos modules containing phonkds.modules configs
      # the option type lives in modules/phonkds-options.nix
      # Filter apps that have traefik enabled and a domain configured
      traefikservices = lib.filterAttrs (
        name: app: app.traefik.enable && app.traefik.domain != null
      ) config.phonkds.modules;
      autoTraefikConfig = {
        http = {
          services = lib.mapAttrs (name: svc: {
            loadBalancer = {
              servers = [
                # Use svc.traefik.scheme instead of hardcoded "http"
                { url = "${svc.traefik.scheme}://${svc.ip}:${toString svc.port}${toString svc.path}"; }
              ];
              # Only add serversTransport if one is defined
              passHostHeader = true; # Generally safe to default to true
            }
            // (lib.optionalAttrs (svc.traefik.transport != null) {
              serversTransport = svc.traefik.transport;
            });
          }) traefikservices;

          # ERROR WAS HERE: "middlewares" removed from here.
          # You cannot assign a list here, and 'traefikservices' doesn't have an .auth property.

          routers = lib.mapAttrs (name: svc: {
            entryPoints = [ "websecure" ];
            rule = "Host(`${svc.traefik.domain}`)";
            service = name;
            tls.certResolver = "cloudflare";

            # CORRECT LOCATION: Apply middlewares dynamically to this specific router
            #
            # Which forward-auth depends on the domain: authelia can only set a
            # session cookie for a parent it lives under, so a service on
            # home.phonkd.net must be sent to the portal on THAT domain or it
            # authenticates and still gets bounced. Picked by suffix here so no
            # service has to declare it.
            middlewares =
              [ ]
              ++ (lib.optionals (svc.traefik.auth or false) [
                (
                  if lib.hasSuffix ".home.phonkd.net" svc.traefik.domain then
                    "forward-auth-home"
                  else
                    "forward-auth"
                )
              ])
              ++ (lib.optionals (svc.traefik.ipfilter or false) [ "ip-filter" ])
              ++ svc.traefik.extraMiddlewares;

          }) traefikservices;
        };
      };

      # middleware
      manualTraefikConfig = {
        http = {
          middlewares = {
            pve-headers = {
              headers = {
                customRequestHeaders = {
                  "X-Forwarded-Proto" = "https";
                };
              };
            };
            ip-filter = {
              ipAllowList.sourceRange = [
                "192.168.3.0/24"
                "192.168.1.0/24"
                "192.168.2.0/24"
                "10.8.0.0/16"
                # The headscale tailnet. Without it every `ipfilter = true`
                # service 403s whenever you're away from home, since a remote
                # client arrives as 100.64.0.x rather than a LAN address —
                # verified live: notes.int over the tailnet returned 403 while
                # an ipfilter = false route on the same host returned 302.
                # Trust-equivalent to the LAN: the tailnet is authenticated by
                # headscale and holds only our own devices. Same reasoning as
                # samba's `hosts allow` on 203.
                "100.64.0.0/10"
              ];
            };
            forward-auth = {
              forwardAuth = {
                address = "http://127.0.0.1:9091/api/authz/forward-auth?rd=https://auth.w.phonkd.net/";
                trustForwardHeader = true;
                authResponseHeaders = [
                  "Remote-User"
                  "Remote-Groups"
                  "Remote-Name"
                  "Remote-Email"
                ];
              };
            };
            # Same authelia instance, but the redirect (`rd=`) points at the
            # portal name under home.phonkd.net. Attached automatically to
            # auth = true routers on that domain — see the router middleware
            # selection above and session.cookies in authelia.nix.
            forward-auth-home = {
              forwardAuth = {
                address = "http://127.0.0.1:9091/api/authz/forward-auth?rd=https://auth.home.phonkd.net/";
                trustForwardHeader = true;
                authResponseHeaders = [
                  "Remote-User"
                  "Remote-Groups"
                  "Remote-Name"
                  "Remote-Email"
                ];
              };
            };
            vnc-root-rewrite = {
              replacePathRegex = {
                regex = "^/$";
                replacement = "/vnc.html";
              };
            };
          };
          serversTransports = {
            insecureTransport = {
              insecureSkipVerify = true;
            };
          };
        };

      };
    in
    lib.mkIf (noughtyLib.hostHasTag "reverse-proxy") {
      sops.secrets.CF_DNS_API_TOKEN = {
        sopsFile = ./traefik-secret.txt;
        format = "binary";
        owner = "traefik";
      };

      services.traefik = {
        enable = true;
        environmentFiles = [ "${config.sops.secrets.CF_DNS_API_TOKEN.path}" ];
        staticConfigOptions = {
          # OTLP log export is still experimental in traefik 3.7 and must be
          # switched on here before log.otlp / accessLog.otlp are accepted.
          experimental.otlpLogs = true;

          entryPoints = {
            # Prometheus metrics, localhost-only — scraped by the local
            # Alloy (see alloy/traefik.alloy below), never exposed.
            # NOT 8082: homepage-dashboard sits there (its nixpkgs default).
            metrics.address = "127.0.0.1:8083";
            websecure = {
              address = ":443";
              # traefik v3 defaults readTimeout to 60s, which kills any
              # request body still streaming after a minute — i.e. large
              # oCIS tus upload chunks. ownCloud's own traefik example
              # uses 12h for upload workloads.
              transport.respondingTimeouts.readTimeout = "12h";
              # We keep TLS generic here; router will say which certResolver to use
              http = {
                tls = { };
              };
              # Trust forwarded headers from local network
              forwardedHeaders = {
                trustedIPs = [
                  "192.168.3.0/24"
                  "127.0.0.1/32"
                ];
              };
            };
          };

          metrics.prometheus = {
            entryPoint = "metrics";
            addEntryPointsLabels = true;
            addRoutersLabels = true;
            addServicesLabels = true;
          };

          # Application + access logs also go to Loki on the observability
          # server, straight over OTLP/HTTP (Loki ingests OTLP natively on
          # /otlp/v1/logs, no collector needed). host.name ends up as
          # structured metadata; the Loki label is service_name="traefik".
          log = {
            level = "INFO";
            filePath = "${config.services.traefik.dataDir}/traefik.log";
            format = "json";
            otlp = {
              resourceAttributes."host.name" = config.networking.hostName;
              http.endpoint = "http://100.64.0.4:3100/otlp/v1/logs";
            };
          };
          accessLog.otlp = {
            resourceAttributes."host.name" = config.networking.hostName;
            http.endpoint = "http://100.64.0.4:3100/otlp/v1/logs";
          };

          certificatesResolvers = {
            cloudflare = {
              acme = {
                email = "bhonk123@gmail.com";
                storage = "/var/lib/traefik/acme.json";
                dnsChallenge = {
                  provider = "cloudflare";
                  resolvers = [
                    "1.1.1.1:53"
                    "1.0.0.1:53"
                  ];
                };
              };
            };
          };
          api = {
            dashboard = true;
            insecure = true; # turn off once it's all working
          };
        };
        dynamicConfigOptions = lib.recursiveUpdate autoTraefikConfig manualTraefikConfig;
      };

      # systemd: load CF token env file correctly
      systemd.services.traefik.serviceConfig = {
        # the secret file itself must contain lines like:
        # CF_DNS_API_TOKEN=supersecrettoken
        EnvironmentFile = [ config.sops.secrets.CF_DNS_API_TOKEN.path ];
      };

      # Ship traefik's Prometheus metrics through the local Alloy into Mimir.
      # Alloy loads every *.alloy file in /etc/alloy into one shared
      # namespace, so this forwards straight into the remote_write pipeline
      # that config.alloy (observability-sender module) defines. Gated on
      # that tag so the reference can't dangle if the tags ever diverge.
      environment.etc."alloy/traefik.alloy" = lib.mkIf (noughtyLib.hostHasTag "observability-sender") {
        text = ''
          prometheus.scrape "traefik" {
            targets    = [{"__address__" = "127.0.0.1:8083"}]
            job_name   = "integrations/traefik"
            forward_to = [prometheus.remote_write.nixvms.receiver]
          }
        '';
      };
    };
}
