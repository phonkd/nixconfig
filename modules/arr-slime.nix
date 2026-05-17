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
        };

        sops.secrets."sonarr-api-key" = { };
        sops.secrets."sonarr-password" = { };
        sops.secrets."prowlarr-api-key" = { };
        sops.secrets."prowlarr-password" = { };
        sops.secrets."sabnzbd-api-key" = { };
        sops.secrets."sabnzbd-nzb-key" = { };

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

          jellyfin.enable = false;
        };

        services.jellyfin.enable = true;
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
