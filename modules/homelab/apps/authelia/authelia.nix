{
  self,
  inputs,
  ...
}:
{
  flake.nixosModules.homelab-authelia =
    {
      config,
      pkgs,
      lib,
      noughtyLib,
      ...
    }:

    lib.mkIf (noughtyLib.hostHasTag "reverse-proxy") {
      phonkds.modules.authelia = {
        ip = "127.0.0.1";
        port = 9091;
        dashboard.enable = true;
        traefik = {
          enable = true;
          domain = "auth.w.phonkd.net";
          ipfilter = false;
        };
      };
      # The same authelia instance under the internal parent domain. Needed
      # because a login redirect has to land on a host that can SET the cookie
      # for home.phonkd.net (see session.cookies below) — a redirect to
      # auth.w.phonkd.net would authenticate and then hand back a cookie the
      # protected service never receives. Not on the dashboard: it is the same
      # portal, just a second name.
      phonkds.modules.authelia-home = {
        ip = "127.0.0.1";
        port = 9091;
        dashboard.enable = false;
        traefik = {
          enable = true;
          domain = "auth.home.phonkd.net";
          # Deliberately NOT ipfilter'd, matching auth.w: the portal must stay
          # reachable to complete a login, and it is the auth boundary itself.
          ipfilter = false;
        };
      };
      sops.secrets.authelia_jwt_secret = {
        sopsFile = ./authelia-secret.yaml;
        owner = "authelia-main";
      };
      sops.secrets.authelia_session_secret = {
        sopsFile = ./authelia-secret.yaml;
        owner = "authelia-main";
      };
      sops.secrets.authelia_storage_encryption_key = {
        sopsFile = ./authelia-secret.yaml;
        owner = "authelia-main";
      };
      sops.secrets.authelia_users_database = {
        sopsFile = ./authelia-secret.yaml;
        owner = "authelia-main";
      };

      services.authelia.instances.main = {
        enable = true;
        secrets = {
          jwtSecretFile = config.sops.secrets.authelia_jwt_secret.path;
          sessionSecretFile = config.sops.secrets.authelia_session_secret.path;
          storageEncryptionKeyFile = config.sops.secrets.authelia_storage_encryption_key.path;
        };
        settings = {
          theme = "dark";
          default_2fa_method = "totp";
          server.address = "127.0.0.1:9091";
          # server = {
          #   host = "127.0.0.1";
          #   port = 9091;
          # };

          log = {
            level = "debug";
          };

          server.endpoints.authz.forward-auth.implementation = "ForwardAuth";

          totp = {
            issuer = "auth.w.phonkd.net";
          };

          authentication_backend = {
            file = {
              path = config.sops.secrets.authelia_users_database.path;
            };
          };
          definitions.network.internal = [
            "192.168.3.0/24"
            "192.168.1.0/24"
            # The headscale tailnet. Load-bearing since internal services moved
            # to home.phonkd.net and resolve to 201's tailnet IP: every request
            # now arrives as 100.64.0.x, so without this the `networks =
            # [ "internal" ]` rules below stop matching and the bypass rules
            # silently escalate to two_factor — including dashboard.w and
            # priv.s3.w, which never moved domain. Same reasoning, and the same
            # trap, as the tailnet entry in traefik's `ip-filter` allow-list.
            "100.64.0.0/10"
            # These two exist purely to keep this list in step with that
            # `ip-filter` allow-list (traefik.nix). A source that ip-filter
            # calls "home" but this list does not is the worst case available:
            # the request passes the firewall, matches no `networks =
            # [ "internal" ]` rule, and falls through to
            # default_policy = "deny" — a 403 with no login prompt and no way
            # in. Harmless while a route is `auth = false`, which is why it
            # went unnoticed; it bites the moment one is flipped on.
            "192.168.2.0/24"
            "10.8.0.0/16"
          ];

          access_control = {
            default_policy = "deny";
            rules = [
              # Rules for the Authelia portal itself. Two names, one instance:
              # a cookie is only valid for the domain that set it, so the
              # portal must also be reachable under home.phonkd.net to serve
              # the services that moved there.
              {
                domain = "auth.w.phonkd.net";
                policy = "bypass";
              }
              {
                domain = "auth.home.phonkd.net";
                policy = "bypass";
              }
              # Apps that carry their OWN login. Authelia is attached to them
              # (`auth = true`) for one reason only: to be the second lock on
              # the outside. From `internal` it must get out of the way, or
              # every visit costs two logins for one session — Authelia's, then
              # the app's — which is the opposite of single sign-on. Rules are
              # first-match-wins, so this has to stay ABOVE the generic
              # *.home.phonkd.net rule below.
              #
              # From anywhere else there is deliberately no rule: the request
              # falls through to default_policy = "deny". traefik's ip-filter
              # already 403s those sources, so this is defence in depth — it is
              # what keeps them shut if a route is ever flipped to
              # `ipfilter = false` by accident.
              {
                domain = [
                  "paperless.home.phonkd.net"
                  "seerr.home.phonkd.net"
                  "affine.home.phonkd.net"
                ];
                policy = "bypass";
                networks = [ "internal" ];
              }
              # Internal subdomain - one factor from internal network
              {
                domain = "*.home.phonkd.net";
                policy = "one_factor";
                networks = [ "internal" ];
              }
              # All other subdomains - bypass from internal network
              {
                domain = "*.w.phonkd.net";
                policy = "bypass";
                networks = [ "internal" ];
              }
              # All other subdomains - two factor from external
              {
                domain = "*.w.phonkd.net";
                policy = "two_factor";
              }
            ];
          };

          session = {
            # One cookie per parent domain. Authelia can only set a cookie for
            # a domain the portal itself is under, so w.phonkd.net's cookie is
            # worthless to a service on home.phonkd.net — hence the second
            # entry and the second portal name. traefik picks the matching
            # forward-auth middleware by domain suffix (see traefik.nix), so
            # nothing per-service has to know about this.
            cookies = [
              {
                domain = "w.phonkd.net";
                authelia_url = "https://auth.w.phonkd.net";
              }
              {
                domain = "home.phonkd.net";
                authelia_url = "https://auth.home.phonkd.net";
              }
            ];
          };

          storage = {
            local = {
              path = "/var/lib/authelia-main/db.sqlite3";
            };
          };

          notifier = {
            filesystem = {
              filename = "/var/lib/authelia-main/notification.txt";
            };
          };
        };
      };
    };
}
