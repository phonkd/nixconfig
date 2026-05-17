{
  self,
  inputs,
  ...
}:
{
  flake.nixosModules."homelab-arr-slime" =
    {
      config,
      pkgs,
      lib,
      noughtyLib,
      ...
    }:
    {
      imports = [ inputs.nixflix.nixosModules.default ];

      config = lib.mkIf (noughtyLib.hostHasTag "homelab-server") {
        phonkds.modules = {
          jellyfin = {
            ip = "127.0.0.1";
            port = 8096;
            dashboard.enable = true;
            traefik = {
              enable = true;
              domain = "jellyfin.int.w.phonkd.net";
              auth = false;
              ipfilter = true;
            };
          };
          sonarr = {
            ip = "127.0.0.1";
            port = 8989;
            dashboard.enable = true;
            traefik = {
              enable = true;
              domain = "sonarr.int.w.phonkd.net";
              auth = false;
              ipfilter = true;
            };
          };
          prowlarr = {
            ip = "127.0.0.1";
            port = 9696;
            dashboard.enable = true;
            traefik = {
              enable = true;
              domain = "prowlarr.int.w.phonkd.net";
              auth = false;
              ipfilter = true;
            };
          };
          sabnzbd = {
            ip = "127.0.0.1";
            port = 8085;
            dashboard.enable = true;
            traefik = {
              enable = true;
              domain = "sabnzbd.int.w.phonkd.net";
              auth = false;
              ipfilter = true;
            };
          };
          seerr = {
            ip = "127.0.0.1";
            port = 5055;
            dashboard.enable = true;
            traefik = {
              enable = true;
              domain = "seerr.int.w.phonkd.net";
              auth = false;
              ipfilter = true;
            };
          };
        };

        sops.secrets."sonarr-api-key" = { };
        sops.secrets."sonarr-password" = { };
        sops.secrets."prowlarr-api-key" = { };
        sops.secrets."prowlarr-password" = { };
        sops.secrets."sabnzbd-api-key" = { };
        sops.secrets."sabnzbd-nzb-key" = { };
        sops.secrets."seerr-api-key" = { };
        sops.secrets."jellyfin-api-key" = { };
        sops.secrets."jellyfin-admin-password" = { };

        nixflix = {
          enable = true;
          stateDir = "/var/lib/nixflix";
          mediaDir = "/mnt/Shares/nixflix";
          downloadsDir = "/mnt/Shares/nixflix/downloads";

          sonarr = {
            enable = true;
            config = {
              apiKey._secret = "/run/secrets/sonarr-api-key";
              hostConfig = {
                username = "phonkd";
                password._secret = "/run/secrets/sonarr-password";
                authenticationRequired = "disabledForLocalAddresses";
              };
            };
          };

          prowlarr = {
            enable = true;
            config = {
              apiKey._secret = "/run/secrets/prowlarr-api-key";
              hostConfig = {
                username = "phonkd";
                password._secret = "/run/secrets/prowlarr-password";
                authenticationRequired = "disabledForLocalAddresses";
              };
            };
          };

          usenetClients.sabnzbd = {
            enable = true;
            settings.misc.port = 8085;
            settings.misc.host_whitelist = "sabnzbd.int.w.phonkd.net";
            settings.misc.api_key = {
              _secret = "/run/secrets/sabnzbd-api-key";
            };
            settings.misc.nzb_key = {
              _secret = "/run/secrets/sabnzbd-nzb-key";
            };
          };

          seerr = {
            enable = true;
            apiKey._secret = "/run/secrets/seerr-api-key";
            sonarr.main = {
              apiKey._secret = "/run/secrets/sonarr-api-key";
              activeDirectory = "/mnt/Shares/nixflix/tv";
              isDefault = true;
              syncEnabled = true;
            };
          };

          jellyfin = {
            enable = true;
            apiKey._secret = "/run/secrets/jellyfin-api-key";
            users.phonkd = {
              password._secret = "/run/secrets/jellyfin-admin-password";
              policy.isAdministrator = true;
            };
          };
        };

        # Upstream nixflix bug: seerr-sonarr.service hard-codes a Requires
        # on seerr-radarr.service even when radarr is disabled, blocking
        # the oneshot from running. Force-drop the bad ref.
        systemd.services.seerr-sonarr = {
          after = lib.mkForce [ "sonarr-config.service" ];
          requires = lib.mkForce [ "sonarr-config.service" ];
        };

        boot.kernelParams = [ "i915.enable_guc=3" ];
        boot.initrd.kernelModules = [ "i915" ];
        hardware.graphics = {
          enable = true;
          extraPackages = with pkgs; [
            intel-media-driver
            intel-vaapi-driver
            libva-vdpau-driver
            libvdpau-va-gl
            intel-compute-runtime
            vpl-gpu-rt
          ];
        };
        users.users.jellyfin = {
          extraGroups = [
            "render"
            "video"
            "phonkd"
          ];
        };
        systemd.services.jellyfin.environment = {
          LIBVA_DRIVER_NAME = "iHD";
        };
        hardware.enableRedistributableFirmware = true;
      };
    };
}
