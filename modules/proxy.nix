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
#
# It runs as a launchd user agent rather than being started by hand. The
# home-manager `launchd.agents` route is used, NOT `brew services`: brew's
# sing-box formula does ship a service, but its plist hardcodes a single
# `--config /opt/homebrew/etc/sing-box/config.json` and offers no way to add
# arguments, so it cannot express the two-file merge above. Nothing about the
# homebrew package is needed here — the nixpkgs build is the same 1.13.18.

{
  flake.homeModules.proxy =
    { pkgs, config, ... }:
    let
      # bound once: the same derivation backs both the CLI on PATH and the agent,
      # so the plist always points at the generation being activated.
      sing-box-work = self.wrappers.sing-box-sel.wrap {
        inherit pkgs;
        additionalConfigFile = "${config.home.homeDirectory}/git/bedag-setup/singbox.json";
      };
    in
    {
      home.packages = [
        sing-box-work
        # for the work ssh catch-all's SOCKS ProxyCommand (see above)
        pkgs.socat
      ];

      # The wrapper already carries `run --config … --config …`, so the agent
      # only needs the binary itself.
      launchd.agents.sing-box = {
        enable = true;
        config = {
          ProgramArguments = [ "${sing-box-work}/bin/sing-box" ];
          RunAtLoad = true;
          # Restart on crash, but not on a clean exit. NB this is also what
          # makes `http_proxy` below honest: it is exported into every shell
          # unconditionally, so before this agent existed any shell opened while
          # sing-box wasn't hand-started had its proxy pointing at a dead port.
          KeepAlive = {
            Crashed = true;
            SuccessfulExit = false;
          };
          # If ~/git/bedag-setup/singbox.json is missing, sing-box exits at
          # startup; back off instead of spinning.
          ThrottleInterval = 30;
          # Deliberately no `ProcessType = "Background"`, unlike the syncthing
          # agent next door: this proxy sits in the interactive path (browsers,
          # ssh) and should not take launchd's background I/O throttling.
          StandardOutPath = "${config.home.homeDirectory}/Library/Logs/sing-box.log";
          StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/sing-box.log";
        };
      };

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
