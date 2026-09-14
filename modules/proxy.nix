{ self, ... }:

# sing-box, work-only. On the Mac and (since plans/work-setup-on-nixos.md) on
# any NixOS host carrying the "work" tag.
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
# this module's remaining job is to supply those: the mixed (HTTP+SOCKS)
# listener on 127.0.0.1:2080 and a direct fallback — plus one homelab
# concession, the `.phonkd.net` DNS route explained at the `dns` block below.
# sing-box merges the two files given as repeated `--config`.
#
# The SOCKS half of that listener is load-bearing: the work repo's `Host *` ssh
# catch-all reaches it via `socat - SOCKS:127.0.0.1:%h:%p,socksport=2080`. That
# is why this cannot simply become privoxy, which is HTTP-only.
#
# It runs as a supervised user service rather than being started by hand. On
# macOS that is a launchd agent, NOT `brew services`: brew's sing-box formula
# does ship a service, but its plist hardcodes a single
# `--config /opt/homebrew/etc/sing-box/config.json` and offers no way to add
# arguments, so it cannot express the two-file merge above. Nothing about the
# homebrew package is needed here — the nixpkgs build is the same 1.13.18.
#
# On NixOS (z14, gated on the "work" host tag — see modules/work/default.nix)
# the same wrapper runs as a systemd user unit instead. Everything else about
# this module is shared: the module branches internally rather than existing
# twice, and each platform imports it exactly once — macOS via
# `darwinModules.gui-darwin`, Linux via `nixosModules.work`.

{
  flake.homeModules.proxy =
    {
      pkgs,
      config,
      lib,
      ...
    }:
    let
      isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
      # bound once: the same derivation backs both the CLI on PATH and the
      # service, so the unit always points at the generation being activated.
      sing-box-work = self.wrappers.sing-box-sel.wrap {
        inherit pkgs;
        additionalConfigFile = "${config.home.homeDirectory}/git/bedag-setup/singbox.json";
        # The `.phonkd.net` split-DNS route exists only to work around macOS
        # scoped resolvers being invisible to sing-box (see the wrapper). On
        # Linux there is no local dnsmasq to point at — `darwinModules.dns` is
        # Mac-only — so 127.0.0.1 would be a dead resolver. Drop the route and
        # let the system resolver answer; homelab names bypass this proxy
        # entirely via `no_proxy` below anyway.
        homelabDnsServer = if isDarwin then "127.0.0.1" else null;
      };
    in
    {
      home.packages = [
        sing-box-work
        # for the work ssh catch-all's SOCKS ProxyCommand (see above)
        pkgs.socat
      ];

      # The wrapper already carries `run --config … --config …`, so the service
      # only needs the binary itself.
      launchd.agents.sing-box = lib.mkIf isDarwin {
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

      # Linux equivalent of the agent above. Logs go to the journal
      # (`journalctl --user -u sing-box`) rather than to a file in ~/Library.
      systemd.user.services.sing-box = lib.mkIf (!isDarwin) {
        Unit = {
          Description = "sing-box (bedag work proxy)";
          After = [ "network.target" ];
          # If ~/git/bedag-setup/singbox.json is missing, sing-box exits at
          # startup. This pair is the analogue of launchd's
          # ThrottleInterval = 30: back off instead of spinning, and give up
          # after a few tries rather than restarting forever.
          StartLimitIntervalSec = 300;
          StartLimitBurst = 5;
        };
        Service = {
          ExecStart = "${sing-box-work}/bin/sing-box";
          # Matches the launchd KeepAlive above: restart on a crash, but treat
          # a clean exit as intentional.
          Restart = "on-failure";
          RestartSec = 30;
        };
        Install.WantedBy = [ "default.target" ];
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
        additionalConfigFile = lib.mkOption {
          type = lib.types.str;
          description = "Path to additional sing-box config file, merged as a second --config.";
        };
        listenPort = lib.mkOption {
          type = lib.types.int;
          default = 2080;
        };
        homelabDnsServer = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = "127.0.0.1";
          description = ''
            Resolver to hand `.phonkd.net` to, bypassing sing-box's own
            `local` server. null disables the split entirely (no extra DNS
            server, no `direct-homelab` outbound, no route rule) — the right
            setting anywhere there is no local dnsmasq to point at.
          '';
        };
      };

      config =
        let
          useHomelabDns = config.homelabDnsServer != null;
        in
        {
          constructFiles.singBoxConfig.content = builtins.toJSON {
            log.level = "info";

            # sing-box does its own name resolution, and its `local` server reads
            # /etc/resolv.conf — which on macOS is the legacy file holding the
            # work nameservers, NOT the scoped /etc/resolver/<domain> entries
            # modules/dns.nix installs. Only mDNSResponder clients (Safari, curl
            # without a proxy, anything going through getaddrinfo) see those. So
            # every homelab name sent through this proxy resolved via public DNS
            # to 192.168.3.201 — 201's LAN address, unroutable from anywhere but
            # home — and the dial timed out, while the same URL in a proxy-less
            # browser resolved 100.64.0.5 and worked over the tailnet.
            #
            # Fix: hand `.phonkd.net` to the local dnsmasq (127.0.0.1), which
            # answers 100.64.0.5 for the internal zones and forwards the rest.
            # Everything else keeps the system resolver, so work DNS is untouched.
            #
            # All of that is macOS-shaped, hence `homelabDnsServer`: set it null
            # (as the Linux consumer does) and the whole split disappears —
            # server, outbound and rule — leaving the plain `local` resolver that
            # is already correct on a host whose /etc/resolv.conf is honest.
            dns = {
              servers = [
                {
                  type = "local";
                  tag = "local";
                }
              ]
              ++ lib.optional useHomelabDns {
                type = "udp";
                tag = "homelab";
                server = config.homelabDnsServer;
              };
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
            ]
            # Dial-time resolution is a per-outbound field since sing-box 1.12
            # and does NOT consult `dns.rules` — a `dns.rules` entry for
            # `.phonkd.net` is silently ignored here (verified: still resolved
            # 192.168.3.201). A second direct outbound carrying
            # `domain_resolver` is the route that actually works.
            ++ lib.optional useHomelabDns {
              type = "direct";
              tag = "direct-homelab";
              domain_resolver = "homelab";
            };
            route = {
              # Mandatory once a `dns` block exists (1.12 deprecation, hard error
              # in 1.14). "local" is the implicit behaviour this config had before.
              default_domain_resolver = "local";
              # The only rule here — the work config brings its own and nothing in
              # it touches phonkd.net. Anything neither set matches goes straight
              # out. With `homelabDnsServer = null` this list is empty and the
              # work config's own rules are the whole routing table.
              rules = lib.optional useHomelabDns {
                domain_suffix = [ ".phonkd.net" ];
                outbound = "direct-homelab";
              };
              final = "direct";
            };
          };
          constructFiles.singBoxConfig.relPath = "etc/sing-box/config.json";

          package = pkgs."sing-box";
          addFlag = [
            "run"
            "--config"
            config.constructFiles.singBoxConfig.path
            "--config"
            config.additionalConfigFile
          ];
        };
    };
}
