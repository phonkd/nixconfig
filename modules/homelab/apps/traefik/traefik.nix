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
      # phonkds.modules apps with traefik enabled and a domain configured; the
      # option type lives in modules/phonkds-options.nix.
      traefikservices = lib.filterAttrs (
        name: app: app.traefik.enable && app.traefik.domain != null
      ) config.phonkds.modules;
      autoTraefikConfig = {
        http = {
          services = lib.mapAttrs (name: svc: {
            loadBalancer = {
              servers = [
                { url = "${svc.traefik.scheme}://${svc.ip}:${toString svc.port}${toString svc.path}"; }
              ];
              passHostHeader = true;
            }
            // (lib.optionalAttrs (svc.traefik.transport != null) {
              serversTransport = svc.traefik.transport;
            });
          }) traefikservices;

          routers = lib.mapAttrs (name: svc: {
            entryPoints = [ "websecure" ];
            rule = "Host(`${svc.traefik.domain}`)";
            service = name;
            tls.certResolver = "cloudflare";

            # Which forward-auth applies depends on the domain: authelia can only set a
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
                # service 403s away from home, since a remote client arrives as
                # 100.64.0.x rather than a LAN address — verified live: an
                # ipfilter route over the tailnet 403'd while the same route
                # with ipfilter = false returned 302. Trust-equivalent to the
                # LAN: headscale-authenticated, holds only our own devices.
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

            # ── Matrix client autodiscovery ────────────────────────────────
            # Element resolves @phonkd:phonkd.net via
            # https://phonkd.net/.well-known/matrix/client, and the apex
            # resolves *here*, not to ext-mail where synapse lives. Redirect to
            # the document ext-mail already serves rather than keeping a
            # second copy in sync (spec allows 30x here). Only the *client*
            # document: /.well-known/matrix/server is left to 404, so a remote
            # server falls through to the _matrix-fed._tcp SRV record and
            # federation keeps working off DNS alone.
            matrix-wellknown-redirect = {
              redirectRegex = {
                regex = "^https://phonkd\\.net/\\.well-known/matrix/client/?$";
                replacement = "https://matrix.phonkd.net/.well-known/matrix/client";
                permanent = false;
              };
            };

            # A cross-origin fetch runs the CORS check against *every* response
            # in a redirect chain, not just the final one, so the 302 itself
            # needs the header -- without it Element Web fails here and never
            # reaches ext-mail (which does send it). Listed before the redirect
            # below so it wraps it and can stamp the 302 on the way out.
            matrix-wellknown-cors = {
              headers.customResponseHeaders."Access-Control-Allow-Origin" = "*";
            };
          };
          serversTransports = {
            insecureTransport = {
              insecureSkipVerify = true;
            };
          };

          routers.matrix-wellknown = {
            entryPoints = [ "websecure" ];
            # Path(), not PathPrefix(): this must not shadow anything else that
            # ever wants to live on the bare apex.
            rule = "Host(`phonkd.net`) && Path(`/.well-known/matrix/client`)";
            service = "matrix-wellknown-sink";
            middlewares = [
              "matrix-wellknown-cors"
              "matrix-wellknown-redirect"
            ];
            # First router to claim the bare apex, so this is also what makes
            # traefik get a certificate for it -- via the same cloudflare
            # DNS-01 resolver as everything else.
            tls.certResolver = "cloudflare";
          };

          # Never actually reached: the redirect middleware answers before the
          # backend is dialled. Traefik still requires every router to name a
          # service, so this is a deliberate dead end -- if the redirect ever
          # stops firing, a 502 here says so loudly instead of failing quietly.
          services.matrix-wellknown-sink.loadBalancer.servers = [
            { url = "http://127.0.0.1:1"; }
          ];
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
              http = {
                tls = { };
              };
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
                  # Check propagation against the zone's AUTHORITATIVE
                  # nameservers, not a recursive resolver. These were
                  # 1.1.1.1/1.0.0.1, and that quietly broke every new domain:
                  # lego queries the challenge name *before* creating the TXT
                  # record (walking up for the SOA), so the recursive resolver
                  # caches an NXDOMAIN that sticks for phonkd.net's 1800s SOA
                  # minimum while lego gives up after ~2 minutes. Symptom:
                  # `dns01: time limit exceeded: ... did not return the
                  # expected TXT record`, took out all 14 names in the
                  # home.phonkd.net migration at once. Cloudflare's own
                  # nameservers answer authoritatively with no caching layer.
                  # By name, not IP: these are anycast addresses that change
                  # (chin ≈ 108.162.192.84, drake ≈ 108.162.195.14 today).
                  resolvers = [
                    "chin.ns.cloudflare.com:53"
                    "drake.ns.cloudflare.com:53"
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

      # Secret file must contain: CF_DNS_API_TOKEN=supersecrettoken
      systemd.services.traefik.serviceConfig = {
        EnvironmentFile = [ config.sops.secrets.CF_DNS_API_TOKEN.path ];
      };

      # Ship traefik's Prometheus metrics through the local Alloy into Mimir.
      # Alloy loads every *.alloy file in /etc/alloy into one shared namespace,
      # forwarding into the remote_write pipeline config.alloy defines. Gated
      # on that tag so the reference can't dangle if the tags ever diverge.
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
