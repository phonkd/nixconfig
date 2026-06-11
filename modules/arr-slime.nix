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
            lidarr = {
              ip = "192.168.3.203";
              port = 8686;
              dashboard.enable = true;
              traefik = {
                enable = true;
                domain = "lidarr.int.w.phonkd.net";
                auth = false;
                ipfilter = true;
              };
            };
            slskd = {
              ip = "192.168.3.203";
              port = 5030;
              dashboard.enable = true;
              traefik = {
                enable = true;
                domain = "slskd.int.w.phonkd.net";
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
          sops.secrets."lidarr-api-key" = { };
          sops.secrets."lidarr-password" = { };
          sops.secrets."slskd-slsk-username" = { };
          sops.secrets."slskd-slsk-password" = { };
          sops.secrets."slskd-web-username" = { };
          sops.secrets."slskd-web-password" = { };
          sops.secrets."prowlarr-api-key" = { };
          sops.secrets."prowlarr-password" = { };
          sops.secrets."nzblife-api-key" = { };
          sops.secrets."nzbgeek-api-key" = { };
          sops.secrets."scenenzbs-api-key" = { };
          sops.secrets."sabnzbd-api-key" = { };
          sops.secrets."sabnzbd-nzb-key" = { };
          sops.secrets."sabnzbduser" = { };
          sops.secrets."sabnzbdpw" = { };
          sops.secrets."seerr-api-key" = { };
          sops.secrets."jellyfin-api-key" = { };
          sops.secrets."jellyfin-admin-password" = { };
          systemd.tmpfiles.rules = [
            "d /mnt/solo-sata/nixflix/downloads/usenet 0755 root root -"
            "d /mnt/solo-sata/nixflix/music 0775 slskd media -"
            "d /mnt/solo-sata/nixflix/downloads/slskd 0755 slskd slskd -"
            "d /mnt/solo-sata/nixflix/downloads/slskd/complete 0755 slskd slskd -"
            "d /mnt/solo-sata/nixflix/downloads/slskd/incomplete 0755 slskd slskd -"
          ];

          nixflix = {
            # globals = {
            #   libraryOwner.group = "nixflix";
            # };
            enable = true;
            stateDir = "/var/lib/nixflix";
            mediaDir = "/mnt/solo-sata/nixflix";
            #mediausers = [ "nixflix" ];
            downloadsDir = "/mnt/solo-sata/nixflix/downloads";

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
            lidarr = {
              enable = true;
              config = {
                apiKey._secret = "/run/secrets/lidarr-api-key";
                hostConfig = {
                  username = "phonkd";
                  password._secret = "/run/secrets/lidarr-password";
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
                    name = "Generic Newznab";
                    #implementationName = "Generic Newznab;

                    baseUrl = "https://scenenzbs.com/";
                    apiKey._secret = "/run/secrets/scenenzbs-api-key";
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
                activeDirectory = "/mnt/solo-sata/nixflix/tv";
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
                enableTonemapping = true;
              };
            };
          };

          sops.templates."slskd.env" = {
            content = ''
              SLSKD_SLSK_USERNAME=${config.sops.placeholder."slskd-slsk-username"}
              SLSKD_SLSK_PASSWORD=${config.sops.placeholder."slskd-slsk-password"}
              SLSKD_USERNAME=${config.sops.placeholder."slskd-web-username"}
              SLSKD_PASSWORD=${config.sops.placeholder."slskd-web-password"}
            '';
            owner = "slskd";
          };

          services.slskd = {
            enable = true;
            openFirewall = true;
            domain = null;
            environmentFile = config.sops.templates."slskd.env".path;
            settings = {
              flags.force_share_scan = false;
              shares = {
                directories = [ "/mnt/solo-sata/nixflix/music" ];
                filters = [
                  "\\.ini$"
                  "Thumbs.db$"
                  "\\.DS_Store$"
                ];
              };
              rooms = [ ];
              soulseek.description = "slskd";
              global = {
                upload = {
                  slots = 10;
                  speed_limit = 2147483647;
                };
                download = {
                  slots = 10;
                  speed_limit = 2147483647;
                };
              };
              filters.search.request = [ ];
              retention = {
                transfers = {
                  upload = {
                    succeeded = 2147483647;
                    errored = 2147483647;
                    cancelled = 2147483647;
                  };
                  download = {
                    succeeded = 2147483647;
                    errored = 2147483647;
                    cancelled = 2147483647;
                  };
                };
                files = {
                  complete = 2147483647;
                  incomplete = 2147483647;
                };
              };
              directories = {
                downloads = "/mnt/solo-sata/nixflix/downloads/slskd/complete";
                incomplete = "/mnt/solo-sata/nixflix/downloads/slskd/incomplete";
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

          # Upstream nixflix bug: sabnzbd-categories pipes the response of
          # `mode=get_config` straight into jq, but SAB 5.x's reply doesn't
          # parse — script dies with `jq: parse error: Invalid numeric`.
          # Skip the get_config/diff step entirely and just push each desired
          # category through `set_config`, which is idempotent.
          systemd.services.sabnzbd-categories.script = lib.mkForce ''
            set -euo pipefail

            BASE_URL="http://${config.nixflix.usenetClients.sabnzbd.connectionAddress}:${toString config.nixflix.usenetClients.sabnzbd.settings.misc.port}${config.nixflix.usenetClients.sabnzbd.settings.misc.url_base}"
            API_KEY=$(cat /run/secrets/sabnzbd-api-key)

            # curl -K reads URL from stdin so the api_key never lands in argv
            # (visible in `ps`).
            api_call() {
              local mode="$1"; shift
              local url="$BASE_URL/api?mode=$mode&output=json&apikey=$API_KEY"
              for param in "$@"; do url="$url&$param"; done
              curl -sSf -K - <<EOF
            url = $url
            EOF
            }

            echo "Waiting for SABnzbd API..."
            for i in $(seq 1 30); do
              if api_call version >/dev/null 2>&1; then
                echo "SABnzbd API is ready"
                break
              fi
              if [ "$i" -eq 30 ]; then
                echo "Timeout waiting for SABnzbd API"
                exit 1
              fi
              sleep 2
            done

            CATEGORIES_JSON='${builtins.toJSON config.nixflix.usenetClients.sabnzbd.settings.categories}'
            echo "$CATEGORIES_JSON" | ${pkgs.jq}/bin/jq -c '.[]' | while IFS= read -r category; do
              name=$(echo "$category" | ${pkgs.jq}/bin/jq -r '.name')
              params=$(echo "$category" | ${pkgs.jq}/bin/jq -r '
                to_entries
                | map("\(.key)=\(.value | tostring | @uri)")
                | join("&")
              ')
              if api_call set_config "section=categories" "$params" >/dev/null; then
                echo "Configured category: $name"
              else
                echo "Warning: Failed to configure category: $name"
              fi
            done

            echo "SABnzbd categories configured successfully"
          '';

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
