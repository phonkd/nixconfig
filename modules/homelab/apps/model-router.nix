{ inputs, ... }:
{
  flake.nixosModules.homelab-model-router =
    { config, pkgs, ... }:
    {
      # Stable lacks this module. Keep the upstream module and its package
      # together on our existing unstable pin; no local service wrapper.
      imports = [
        "${inputs.nixpkgs-unstable}/nixos/modules/services/misc/cliproxyapi.nix"
      ];

      # This newer module adds manual anchors absent from stable's redirect
      # table. The manual can still build without validating that table.
      documentation.nixos.checkRedirects = false;

      sops.secrets.cliproxyapi-api-key = {
        restartUnits = [ "cliproxyapi.service" ];
      };
      sops.secrets.cliproxyapi-management-key = {
        restartUnits = [ "cliproxyapi.service" ];
      };

      services.cliproxyapi = {
        enable = true;
        package = inputs.nixpkgs-unstable.legacyPackages.${pkgs.stdenv.hostPlatform.system}.cliproxyapi;
        settings = {
          config-version = 8;
          server = {
            host = "127.0.0.1";
            port = 8317;
            trusted-proxies = [ "127.0.0.1" ];
          };
          access.api-keys = [
            { _secret = config.sops.secrets.cliproxyapi-api-key.path; }
          ];
          management = {
            # Reachable through the tailnet-only route, with its own key.
            allow-remote = true;
            secret-key._secret = config.sops.secrets.cliproxyapi-management-key.path;
          };
          # OAuth tokens are mutable: the daemon refreshes them in its private
          # state directory. Enroll through the management UI or CLI once.
          oauth.auth-dir = "/var/lib/cliproxyapi";
        };
      };

      environment.systemPackages = [ config.services.cliproxyapi.package ];

      phonkds.modules.models = {
        ip = "127.0.0.1";
        port = config.services.cliproxyapi.settings.server.port;
        traefik = {
          enable = true;
          domain = "models.home.phonkd.net";
          ipfilter = true;
          # API clients authenticate with their bearer key.
          auth = false;
        };
        dashboard = {
          enable = true;
          icon = "openai";
          link = "https://models.home.phonkd.net/management.html";
        };
      };
    };
}
