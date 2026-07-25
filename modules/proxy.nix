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
            # secretsFile = config.sops.secrets.wg-endpoint.path;
            secretsFile = "${config.home.homeDirectory}/.config/wg-endpoint.json";
            additionalConfigFile = "${config.home.homeDirectory}/git/bedag-setup/singbox.json";
          })
          pkgs.socat
        ];
        home.sessionVariables = {
          http_proxy = "http://localhost:2080";
          https_proxy = "http://localhost:2080";
          # `.phonkd.net` (all homelab web) + the tailnet range bypass sing-box
          # so env-proxy CLI clients reach them direct over the mesh, not via the
          # SOCKS proxy. Spotify (.spotify.com/.scdn.co/...) still routes through
          # sing-box. Work domains are unaffected (not under phonkd.net).
          no_proxy = "localhost,127.0.0.1,.phonkd.net,100.64.0.0/10";
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
            # Spotify only — routed through the homelab wg outbound instead of
            # direct. Homelab web (.w.phonkd.net) is deliberately NOT here: it's
            # reached over the tailnet now (201's traefik at 100.64.0.5, resolved
            # by the Mac's scoped dnsmasq in modules/dns.nix). sing-box is left
            # with just Spotify + the bedag work VPN (additionalConfigFile).
            ".spotify.com"
            ".scdn.co"
            ".spotifycdn.com"
          ];
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
