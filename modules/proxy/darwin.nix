{ self, ... }:

# sing-box on the Mac: an unprivileged launchd agent putting a mixed (HTTP +
# SOCKS) listener on 127.0.0.1:2080, handing everything the work config
# doesn't claim straight out.
#
# Shares only the package with modules/proxy/nixos.nix: no tun, no root, no
# second traffic class, no secret, and the DNS cleverness below is a
# macOS-only fix with no Linux analogue -- cheaper to keep them apart than
# make the differences conditional.
#
# The SOCKS half is load-bearing: the work repo's `Host *` ssh catch-all
# reaches it via `socat - SOCKS:127.0.0.1:%h:%p,socksport=2080`, so this
# can't just be an HTTP proxy like privoxy.
#
# A launchd agent, not `brew services`: brew's plist hardcodes a single
# `--config /opt/homebrew/etc/sing-box/config.json` with no way to add
# arguments, so it can't express the two-file merge this needs.

{
  flake.homeModules.proxy =
    {
      pkgs,
      config,
      lib,
      ...
    }:
    let
      # Bound once: the same derivation backs both the CLI on PATH and the
      # agent, so the plist always points at the generation being activated.
      sing-box-work = self.wrappers.sing-box-sel.wrap {
        inherit pkgs;
        additionalConfigFiles = [ "${config.home.homeDirectory}/git/bedag-setup/singbox.json" ];
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
          # Restart on crash, not on a clean exit -- also what makes
          # `http_proxy` below honest: it's exported into every shell
          # unconditionally, so a shell opened while sing-box wasn't running
          # would otherwise point at a dead port.
          KeepAlive = {
            Crashed = true;
            SuccessfulExit = false;
          };
          # If ~/git/bedag-setup/singbox.json is missing sing-box exits at
          # startup; back off rather than spin.
          ThrottleInterval = 30;
          # No `ProcessType = "Background"`, unlike the syncthing agent next
          # door: this sits in the interactive path (browsers, ssh) and
          # shouldn't take launchd's I/O throttling.
          StandardOutPath = "${config.home.homeDirectory}/Library/Logs/sing-box.log";
          StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/sing-box.log";
        };
      };

      home.sessionVariables = {
        http_proxy = "http://localhost:2080";
        https_proxy = "http://localhost:2080";
        # `.phonkd.net` and the tailnet range bypass sing-box so env-proxy
        # clients reach them direct over the mesh; work domains are unaffected.
        no_proxy = "localhost,127.0.0.1,.phonkd.net,100.64.0.0/10";
      };
    };

  # Darwin-only. The NixOS side generates its config inline and installs it to
  # /etc instead, for path-ordering reasons documented there.
  flake.wrappers.sing-box-sel =
    {
      config,
      pkgs,
      lib,
      wlib,
      ...
    }:
    {
      imports = [ wlib.modules.default ];

      options = {
        additionalConfigFiles = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = ''
            Further sing-box config files, each appended as another `--config`.
            In practice one: the private bedag config, which supplies the SOCKS
            outbounds and the rules picking between them.
          '';
        };

        listenPort = lib.mkOption {
          type = lib.types.int;
          default = 2080;
          description = ''
            Mixed (HTTP + SOCKS) inbound. Changing it means changing the work
            repo's ssh catch-all too, which hardcodes `socksport=2080`.
          '';
        };

        homelabDnsServer = lib.mkOption {
          type = lib.types.str;
          default = "127.0.0.1";
          description = ''
            Resolver to hand `.phonkd.net` to, bypassing sing-box's own `local`
            server. The local dnsmasq that modules/dns.nix installs.
          '';
        };
      };

      config = {
        constructFiles.singBoxConfig.content = builtins.toJSON {
          # "info" logs a line per connection -- merely noisy with no tun to
          # feed it. Left at "warn" to match the Linux side; raise by hand
          # when debugging.
          log.level = "warn";

          # The macOS-only wrinkle this file doesn't share with the Linux one:
          # sing-box does its own name resolution, and `type = "local"` reads
          # /etc/resolv.conf -- the legacy file holding the work nameservers
          # on macOS, NOT the scoped /etc/resolver/<domain> entries
          # modules/dns.nix installs (only mDNSResponder clients like Safari
          # see those). So every homelab name here resolved via public DNS to
          # 192.168.3.201 -- 201's LAN address, unroutable off-home -- and
          # timed out, while the same URL in a proxy-less browser resolved
          # 100.64.0.5 and worked.
          #
          # Fix: hand `.phonkd.net` to the local dnsmasq, which answers
          # 100.64.0.5 for internal zones and forwards the rest; work DNS
          # stays on the system resolver.
          dns = {
            servers = [
              {
                type = "local";
                tag = "local";
              }
              {
                type = "udp";
                tag = "homelab";
                server = config.homelabDnsServer;
              }
            ];
            final = "local";
          };

          inbounds = [
            {
              type = "mixed";
              tag = "mixed-in";
              listen = "127.0.0.1";
              listen_port = config.listenPort;
            }
          ];

          outbounds = [
            {
              type = "direct";
              tag = "direct";
            }
            # Dial-time resolution is a per-outbound field since sing-box 1.12
            # and does NOT consult `dns.rules` -- a `dns.rules` entry for
            # `.phonkd.net` is silently ignored (verified: still resolved
            # 192.168.3.201). A second direct outbound carrying
            # `domain_resolver` is what actually works.
            {
              type = "direct";
              tag = "direct-homelab";
              domain_resolver = "homelab";
            }
          ];

          route = {
            # Mandatory once a `dns` block exists (1.12 deprecation, hard error
            # in 1.14). "local" is the behaviour this config had implicitly.
            default_domain_resolver = "local";
            # The only rule here: the work config brings its own and touches
            # nothing under phonkd.net. Anything unmatched goes straight out.
            rules = [
              {
                domain_suffix = [ ".phonkd.net" ];
                outbound = "direct-homelab";
              }
            ];
            final = "direct";
          };
        };
        constructFiles.singBoxConfig.relPath = "etc/sing-box/config.json";

        package = pkgs."sing-box";
        # sing-box merges these by file PATH, not the order given here -- see
        # modules/proxy/nixos.nix, where that bites. Harmless on darwin: the
        # single `.phonkd.net` rule below competes with nothing in the work
        # config, and there's no sniffing whose position would matter.
        addFlag = [
          "run"
          "--config"
          config.constructFiles.singBoxConfig.path
        ]
        ++ lib.concatMap (f: [
          "--config"
          f
        ]) config.additionalConfigFiles;
      };
    };
}
