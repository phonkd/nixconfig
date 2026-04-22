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

      config = {
        # sops.age.keyFile = "${config.home.homeDirectory}/.config/sops/age/keys.txt";

        # sops.secrets.wg-endpoint = {
        #   sopsFile = self + "${config.home.homeDirectory}/.config/wg-endpoint.json";
        #   format = "json";
        #   key = "";
        # };
        proxy.ipRanges = [ "192.168.1.47/32" "192.168.1.201/32" "192.168.1.203/32" "192.168.1.46/32" "192.168.1.200/32" "192.168.1.150/32" ];

        # programs.ssh.matchBlocks = lib.listToAttrs (map (range:
        #   let ip = builtins.head (lib.splitString "/" range);
        #   in lib.nameValuePair ip {
        #     proxyCommand = "nc -X 5 -x 127.0.0.1:2080 %h %p";
        #   }
        # ) config.proxy.ipRanges);

        home.packages = [
          (self.wrappers.sing-box-sel.wrap {
            inherit pkgs;
            ipRanges = config.proxy.ipRanges;
            # secretsFile = config.sops.secrets.wg-endpoint.path;
            secretsFile = "${config.home.homeDirectory}/.config/wg-endpoint.json";
            additionalConfigFile = "${config.home.homeDirectory}/git/bedag-setup/singbox.json";
          })
          pkgs.socat
        ];
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
          default = [ ".w.phonkd.net" ];
        };
        ipRanges = lib.mkOption {
          type = lib.types.listOf lib.types.str;
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
          ];
          outbounds = [
            { type = "direct"; tag = "direct"; }
          ];
          route = {
            rules = [
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
