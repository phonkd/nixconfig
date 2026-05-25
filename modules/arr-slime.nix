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

      config = lib.mkMerge [
        # ── Routing + dashboard intent ────────────────────────────────
        # Lives on the reverse-proxy host (201), because that's where
        # traefik and homepage actually run and read config.phonkds.modules.
        # The ip values point at 192.168.3.203, so 201 routes across to the
        # media-server VM.
        (lib.mkIf (noughtyLib.hostHasTag "reverse-proxy") {
          phonkds.modules = {
            jellyfin = {
              ip = "192.168.3.203";
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
              ip = "192.168.3.203";
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
              ip = "192.168.3.203";
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
              ip = "192.168.3.203";
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
              ip = "192.168.3.203";
              port = 5055;
              dashboard.enable = true;
              traefik = {
                enable = true;
                domain = "seerr.int.w.phonkd.net";
                auth = false;
                ipfilter = true;
              };
            };
            radarr = {
              ip = "192.168.3.203";
              port = 7878;
              dashboard.enable = true;
              traefik = {
                enable = true;
                domain = "radarr.int.w.phonkd.net";
                auth = false;
                ipfilter = true;
              };
            };
          };

          # Homepage runs on the reverse-proxy host, so its SABnzbd widget
          # (and the api-key it needs) belong here, not on the media-server.
          sops.secrets."sabnzbd-api-key" = { };

          sops.templates."homepage.env".content = ''
            HOMEPAGE_VAR_SABNZBD_KEY=${config.sops.placeholder."sabnzbd-api-key"}
          '';

          services.homepage-dashboard = {
            environmentFile = config.sops.templates."homepage.env".path;
            services = [
              {
                "Downloaders" = [
                  {
                    "SABnzbd" = {
                      icon = "sabnzbd.png";
                      href = "https://sabnzbd.int.w.phonkd.net";
                      description = "sabnzbd.int.w.phonkd.net";
                      widget = {
                        type = "sabnzbd";
                        url = "http://192.168.3.203:8085";
                        key = "{{HOMEPAGE_VAR_SABNZBD_KEY}}";
                        fields = [
                          "rate"
                          "queue"
                          "timeleft"
                        ];
                      };
                    };
                  }
                ];
              }
            ];
          };
        })

        # ── Media workloads ───────────────────────────────────────────
        # The actual *arr/jellyfin/sabnzbd services live on the
        # media-server host (203-media).
        (lib.mkIf (noughtyLib.hostHasTag "media-server") {
          # Open every port to the reverse-proxy host (201) only. nftables is
          # the active backend (gigaplayer-server tag), so use extraInputRules.
          networking.firewall.extraInputRules = ''
            ip saddr 192.168.3.201 accept
          '';

          sops.secrets."sonarr-api-key" = { };
          sops.secrets."sonarr-password" = { };
          sops.secrets."radarr-api-key" = { };
          sops.secrets."radarr-password" = { };
          sops.secrets."prowlarr-api-key" = { };
          sops.secrets."prowlarr-password" = { };
          sops.secrets."nzblife-api-key" = { };
          sops.secrets."nzbgeek-api-key" = { };
          sops.secrets."sabnzbd-api-key" = { };
          sops.secrets."sabnzbd-nzb-key" = { };
          sops.secrets."sabnzbduser" = { };
          sops.secrets."sabnzbdpw" = { };
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
            radarr = {
              enable = true;
              config = {
                apiKey._secret = "/run/secrets/radarr-api-key";
                hostConfig = {
                  username = "phonkd";
                  password._secret = "/run/secrets/radarr-password";
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
                indexers = [
                  {
                    name = "Nzb.life";
                    apiKey._secret = "/run/secrets/nzblife-api-key";
                  }
                  {
                    name = "NZBgeek";
                    apiKey._secret = "/run/secrets/nzbgeek-api-key";
                  }
                  {
                    name = "SceneNZBs";
                    implementationName = "Generic Newznab";

                    baseUrl = "https://scenenzbs.com/";
                    apiKey = "/run/secrets/sceneznbs-api-key";
                    #appProfileId = 1;
                  }
                ];
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
              settings.servers = [
                {
                  name = "newshosting";
                  displayname = "Newshosting";
                  host = "news.newshosting.com";
                  port = 563;
                  ssl = true;
                  connections = 50;
                  username._secret = "/run/secrets/sabnzbduser";
                  password._secret = "/run/secrets/sabnzbdpw";
                }
              ];
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
              encoding = {
                enableHardwareEncoding = true;
                hardwareAccelerationType = "nvenc";
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

          # NVIDIA RTX 3060 Ti (Ampere, GA104) passed through to the VM ->
          # Jellyfin NVENC/NVDEC. Was Intel iGPU (i915 + VAAPI/iHD) before.
          services.xserver.videoDrivers = [ "nvidia" ];
          hardware.nvidia = {
            open = true; # Ampere is supported by the open kernel modules
            modesetting.enable = true;
            nvidiaSettings = false; # headless server, no GUI
            package = config.boot.kernelPackages.nvidiaPackages.stable;
          };
          hardware.graphics = {
            enable = true;
            extraPackages = with pkgs; [
              nvidia-vaapi-driver # optional VAAPI shim over NVDEC
            ];
          };
          users.users.jellyfin = {
            extraGroups = [
              "render"
              "video"
              "phonkd"
            ];
          };
          hardware.enableRedistributableFirmware = true;
        })
      ];
    };
}
