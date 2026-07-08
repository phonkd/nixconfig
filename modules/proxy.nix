{ inputs, self, ... }:

{
  flake.homeModules.proxy =
    { pkgs, lib, config, ... }:
    {
      imports = [ inputs.sops-nix.homeManagerModules.sops ];

      options.proxy.ipRanges = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "IP ranges to route through WireGuard proxy and generate SSH ProxyCommand entries for.";
      };

      options.proxy.tcpForwards = lib.mkOption {
        type = lib.types.listOf (
          lib.types.submodule {
            options = {
              listenPort = lib.mkOption { type = lib.types.port; };
              address = lib.mkOption { type = lib.types.str; };
              port = lib.mkOption { type = lib.types.port; };
            };
          }
        );
        default = [ ];
        description = "Local 127.0.0.1 listeners forwarded to a fixed destination through the wg outbound, for proxy-unaware clients (e.g. Finder SMB).";
      };

      config = {
        # sops.age.keyFile = "${config.home.homeDirectory}/.config/sops/age/keys.txt";

        # sops.secrets.wg-endpoint = {
        #   sopsFile = self + "${config.home.homeDirectory}/.config/wg-endpoint.json";
        #   format = "json";
        #   key = "";
        # };
        programs.ssh.matchBlocks = lib.listToAttrs (map (range:
          let ip = builtins.head (lib.splitString "/" range);
          in lib.nameValuePair ip {
            proxyCommand = "nc -X 5 -x 127.0.0.1:2080 %h %p";
          }
        ) config.proxy.ipRanges);

        home.packages = [
          (self.wrappers.sing-box-sel.wrap {
            inherit pkgs;
            ipRanges = config.proxy.ipRanges;
            tcpForwards = config.proxy.tcpForwards;
            # secretsFile = config.sops.secrets.wg-endpoint.path;
            secretsFile = "${config.home.homeDirectory}/.config/wg-endpoint.json";
            additionalConfigFile = "${config.home.homeDirectory}/git/bedag-setup/singbox.json";
          })
          pkgs.socat
        ];
        home.sessionVariables = {
          http_proxy = "http://localhost:2080";
          https_proxy = "http://localhost:2080";
          no_proxy = "localhost,127.0.0.1";
        };
      };
    };

  flake.wrappers.sing-box-sel =
    { config, pkgs, wlib, lib, ... }:
    {
      imports = [ wlib.modules.default ];

      options = {
        secretsFile = lib.mkOption {
          type = lib.types.str;
          description = "Path to sops-decrypted WireGuard endpoint config merged into sing-box.";
        };
        additionalConfigFile = lib.mkOption {
          type = lib.types.str;
          description = "Path to additional sing-box config file.";
        };
        wgLocalAddress = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ "10.8.0.2/24" ];
        };
        domains = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [
            ".w.phonkd.net"
            # Spotify: route through wg (homelab) instead of direct.
            ".spotify.com"
            ".scdn.co"
            ".spotifycdn.com"
          ];
        };
        ipRanges = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
        };
        tcpForwards = lib.mkOption {
          type = lib.types.listOf (
            lib.types.submodule {
              options = {
                listenPort = lib.mkOption { type = lib.types.port; };
                address = lib.mkOption { type = lib.types.str; };
                port = lib.mkOption { type = lib.types.port; };
              };
            }
          );
          default = [ ];
        };
        listenPort = lib.mkOption {
          type = lib.types.int;
          default = 2080;
        };
      };

      config = {
        constructFiles.singBoxConfig.content = builtins.toJSON {
          log.level = "info";
          inbounds = [
            {
              type = "mixed";
              tag = "mixed-in";
              listen = "127.0.0.1";
              listen_port = config.listenPort;
            }
          ]
          # Plain TCP forwards for proxy-unaware clients (Finder SMB etc.):
          # each listener dials its fixed destination through the wg outbound.
          ++ map (f: {
            type = "direct";
            tag = "fwd-${toString f.listenPort}";
            listen = "127.0.0.1";
            listen_port = f.listenPort;
            override_address = f.address;
            override_port = f.port;
          }) config.tcpForwards;
          outbounds = [
            { type = "direct"; tag = "direct"; }
          ];
          route = {
            rules =
              lib.optional (config.tcpForwards != [ ]) {
                inbound = map (f: "fwd-${toString f.listenPort}") config.tcpForwards;
                outbound = "wg";
              }
              ++ [
                (
                  { outbound = "wg"; }
                  // lib.optionalAttrs (config.domains != [ ]) { domain_suffix = config.domains; }
                  // lib.optionalAttrs (config.ipRanges != [ ]) { ip_cidr = config.ipRanges; }
                )
              ];
            final = "direct";
          };
        };
        constructFiles.singBoxConfig.relPath = "etc/sing-box/config.json";

        package = pkgs."sing-box";
        addFlag = [
          "run"
          "--config" config.constructFiles.singBoxConfig.path
          "--config" config.secretsFile
          "--config" config.additionalConfigFile
        ];
      };
    };
}
