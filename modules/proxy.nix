{ self, ... }:

# sing-box on the Mac, work-only.
#
# Everything homelab left this proxy when the headscale mesh landed
# (plans/headscale-mesh.md): ssh/deploy, observability, SMB and homelab web all
# ride the tailnet now. Spotify-via-home was the last homelab-ish rule and is
# dropped too, which retires the WireGuard outbound (~/.config/wg-endpoint.json)
# and with it the only thing here that a plain HTTP proxy could not have done.
#
# What is left is entirely the bedag work setup, and it is NOT defined in this
# repo — `~/git/bedag-setup/singbox.json` supplies six SOCKS outbounds
# (127.0.0.1:30001-30006, the ssh -D gateway tunnels) plus the domain/ip_cidr
# rules that pick between them. It has no `inbounds` and no `route.final`, so
# this module's whole remaining job is to supply those: the mixed (HTTP+SOCKS)
# listener on 127.0.0.1:2080 and a direct fallback. sing-box merges the two
# files given as repeated `--config`.
#
# The SOCKS half of that listener is load-bearing: the work repo's `Host *` ssh
# catch-all reaches it via `socat - SOCKS:127.0.0.1:%h:%p,socksport=2080`. That
# is why this cannot simply become privoxy, which is HTTP-only.

{
  flake.homeModules.proxy =
    { pkgs, config, ... }:
    {
      home.packages = [
        (self.wrappers.sing-box-sel.wrap {
          inherit pkgs;
          additionalConfigFile = "${config.home.homeDirectory}/git/bedag-setup/singbox.json";
        })
        # for the work ssh catch-all's SOCKS ProxyCommand (see above)
        pkgs.socat
      ];
      home.sessionVariables = {
        http_proxy = "http://localhost:2080";
        https_proxy = "http://localhost:2080";
        # `.phonkd.net` (all homelab web) + the tailnet range bypass sing-box so
        # env-proxy CLI clients reach them direct over the mesh. Work domains are
        # unaffected (not under phonkd.net).
        no_proxy = "localhost,127.0.0.1,.phonkd.net,100.64.0.0/10";
      };
    };

  flake.wrappers.sing-box-sel =
    { config, pkgs, lib, wlib, ... }:
    {
      imports = [ wlib.modules.default ];

      options = {
        additionalConfigFile = lib.mkOption {
          type = lib.types.str;
          description = "Path to additional sing-box config file, merged as a second --config.";
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
          # No rules here — the work config brings its own. Anything they don't
          # match goes straight out.
          route.final = "direct";
        };
        constructFiles.singBoxConfig.relPath = "etc/sing-box/config.json";

        package = pkgs."sing-box";
        addFlag = [
          "run"
          "--config" config.constructFiles.singBoxConfig.path
          "--config" config.additionalConfigFile
        ];
      };
    };
}
