{ ... }:

# sing-box on NixOS: an HTTP + SOCKS proxy on 127.0.0.1:2080, run as a root
# systemd service. Gated on `noughty.proxy.enable`, which `nixosModules.work`
# sets from the "work" host tag -- today that means z14 and nothing else. See
# plans/work-setup-on-nixos.md, which also carries the history of how this was
# got working; the comments here are limited to what you need to change it
# safely.
#
# APP-LAYER BY DEFAULT. `transparent` -- the tun inbound with `auto_route`,
# which is what made this a system-wide proxy capturing every socket -- is OFF,
# and so is the in-process tailscale endpoint. Only traffic that opts in comes
# through: anything honouring $http_proxy, plus the work ssh catch-all, which
# dials the SOCKS half by hand through socat. Both mechanisms are still
# implemented and both default off; the traps they cost to find are in the
# README, and turning either back on is a one-line change at its option.
#
# "System service" is a SEPARATE axis from "system-wide proxy", and only the
# second was given up. Root still earns its keep without the tun:
# `environment.sessionVariables` reaches every login session and every
# graphical app greetd starts, where home-manager's session variables reach
# only its own shells.
#
# This shares nothing with the macOS half (modules/proxy/darwin.nix) beyond the
# package. They looked similar once and the similarity was misleading: the Mac
# runs an unprivileged launchd agent with one inbound and one routing concern,
# this one keeps the tun, the extra traffic class and the secret available even
# while they are switched off.
#
# TWO traffic classes as configured today:
#
#   bedag (the work config's own domain/ip rules) -> SOCKS ssh tunnels
#   everything else                               -> direct
#
# The homelab is a third class that deliberately never reaches sing-box at all:
# `no_proxy` below carries `.phonkd.net` and 100.64.0.0/10, so those go
# straight to tailscaled over the headscale mesh. `transparent` +
# `tailscaleOutbound` would pull it back in here (homelab -> sing-box's own
# tsnet node), which is the arrangement the README and the plan describe.
#
# THREE config files, merged by sing-box and split by who may read them:
#
#   1. /etc/sing-box/config.json -- generated here. Public: inbounds, DNS,
#      routing. Note the path; see `environment.etc` below, it is load-bearing.
#   2. ~/git/bedag-setup/singbox.json -- the bedag SOCKS outbounds and the
#      rules picking between them. Private repo, referenced by path, never
#      restated here.
#   3. /run/secrets/rendered/singbox-tailscale.json -- the tailscale endpoint,
#      rendered by sops at activation because it carries a pre-auth key. Only
#      written, and only passed to sing-box, under `tailscaleOutbound.enable`,
#      so today it does not exist.
#
# That split is what keeps this repo publishable: nothing secret is ever a
# store path.

{
  flake.nixosModules.proxy =
    {
      pkgs,
      lib,
      config,
      ...
    }:
    let
      cfg = config.noughty.proxy;
      ts = cfg.tailscaleOutbound;

      # Rendered at activation, not built into the store: it carries the
      # headscale pre-auth key. `sops.placeholder` is a marker string sops-nix
      # substitutes when it writes /run/secrets/rendered (0400 root), so the
      # key exists only there -- not in /nix/store, which is world-readable.
      tailscaleConfigFile = config.sops.templates."singbox-tailscale.json".path;

      # "https://hs.phonkd.net" -> "hs.phonkd.net", so the rules can name the
      # control plane. It has to be excluded from the tailscale endpoint by
      # both name and route; see `tailscaleBypassDomains`.
      controlHost =
        let
          afterScheme = lib.last (lib.splitString "//" ts.controlUrl);
        in
        lib.head (lib.splitString ":" (lib.head (lib.splitString "/" afterScheme)));

      bypassDomains = lib.optional ts.enable controlHost;

      singBoxConfig = {
        # "info" logs a line per connection AND per packet-connection. Raise it
        # to "debug" to diagnose routing -- the `router: match[N] => ...` lines
        # are the only way to see which rule won -- and put it back after.
        log.level = cfg.logLevel;

        dns = {
          servers = [
            {
              type = "udp";
              tag = "upstream";
              server = cfg.upstreamDns;
            }
          ]
          # MagicDNS answered by sing-box's own tailscale node rather than by
          # tailscaled's resolv.conf, because with the tun capturing the
          # tailnet the host resolver is no longer necessarily the one that
          # knows these names.
          ++ lib.optional ts.enable {
            type = "tailscale";
            tag = "ts-dns";
            endpoint = ts.tag;
          };

          # The control plane resolves upstream, NOT via the endpoint's own
          # MagicDNS: it ends in .phonkd.net, so it would otherwise match the
          # suffix rule below and ask the endpoint to resolve the address it
          # needs in order to exist. This rule must precede that one.
          rules = lib.optional (ts.enable && bypassDomains != [ ]) {
            domain = bypassDomains;
            server = "upstream";
          }
          ++ lib.optional ts.enable {
            domain_suffix = cfg.homelabDomainSuffixes;
            server = "ts-dns";
          };

          final = "upstream";
        };

        inbounds = [
          # Kept unconditionally, transparent mode included: the work ssh
          # catch-all dials it by hand with
          # `socat - SOCKS:127.0.0.1:%h:%p,socksport=2080`, which is asking for
          # SOCKS rather than for a route, so the tun would not serve it.
          {
            type = "mixed";
            tag = "mixed-in";
            listen = "127.0.0.1";
            listen_port = cfg.listenPort;
          }
        ]
        ++ lib.optional cfg.transparent {
          type = "tun";
          tag = "tun-in";
          # A /30 nothing else here uses; only ever carries traffic between
          # the kernel and sing-box.
          address = [ "172.19.0.1/30" ];
          auto_route = true;
          # `strict_route` also hijacks other interfaces' traffic, which is
          # exactly the fight not to pick with tailscale0.
          strict_route = false;
          # Only while the tailnet is a bypass. With a real endpoint those
          # packets must reach sing-box, so excluding them would defeat the
          # rule that sends them to it.
          route_exclude_address = lib.optional (!ts.enable) cfg.tailnetCidr;
          stack = cfg.tunStack;
        };

        outbounds = [
          {
            type = "direct";
            tag = "direct";
          }
        ];

        route = {
          # Mandatory once a `dns` block exists (1.12 deprecation, hard error
          # in 1.14).
          default_domain_resolver = "upstream";

          # NOT optional with a tun, and omitting it is what made the first
          # attempt melt the laptop. `auto_route` points the kernel default
          # route at the tun; an outbound with no bound interface then follows
          # that route, so every "direct" dial left via the tun, was picked
          # straight back up by `tun-in` (source 172.19.0.1, the tun's own
          # address) and routed to `direct` again. ~4.6 cores, self-feeding.
          # Harmless without a tun, so it is unconditional.
          auto_detect_interface = true;

          rules =
            # MUST be first, and is what makes the work config's rules work at
            # all under the tun. Those rules are almost entirely
            # `domain_suffix` (".bedag.ch" and friends). An $http_proxy client
            # sends `CONNECT wiki.bedag.ch:443` and hands sing-box the name;
            # the tun offers no such courtesy -- the client resolves the name
            # itself, sing-box sees only an address, matches no domain rule and
            # falls through to `direct`. Sniffing recovers the name from the
            # TLS ClientHello SNI or an HTTP Host header.
            lib.optional cfg.transparent { action = "sniff"; }

            # ORDER IS LOAD-BEARING: these two carve-outs must precede the
            # tailnet rules, because both describe traffic that falls inside
            # the tailnet by address or name but must not go to the endpoint --
            # MagicDNS, and the control plane the endpoint dials to come up at
            # all. Put them after and the endpoint can never bootstrap.
            ++ lib.optional (ts.enable && cfg.tailscaleBypassCidrs != [ ]) {
              ip_cidr = cfg.tailscaleBypassCidrs;
              outbound = "direct";
            }
            ++ lib.optional (ts.enable && bypassDomains != [ ]) {
              domain = bypassDomains;
              outbound = "direct";
            }

            # Both forms are needed: `ip_cidr` catches what is already resolved
            # into the CGNAT range (ssh to a raw 100.64.x.y, deploy targets),
            # the suffix rule catches names resolved inside sing-box before an
            # address exists to match on.
            ++ lib.optionals ts.enable [
              {
                ip_cidr = [ cfg.tailnetCidr ];
                outbound = ts.tag;
              }
              {
                domain_suffix = cfg.homelabDomainSuffixes;
                outbound = ts.tag;
              }
            ]

            # After the tailnet rules, before the work config's: `ssh 201-mono`
            # still goes to the tailnet, while ssh to a bedag gateway goes
            # straight out rather than into the tunnels it is trying to build.
            # See `bootstrapProcessNames`.
            ++ lib.optional (cfg.transparent && cfg.bootstrapProcessNames != [ ]) {
              process_name = cfg.bootstrapProcessNames;
              outbound = "direct";
            }

            # Bypass form, when there is no endpoint: keep tailnet traffic out
            # of the work tunnels if it reaches the mixed inbound anyway, and
            # let tailscaled have it.
            ++ lib.optional (cfg.transparent && !ts.enable) {
              ip_cidr = [ cfg.tailnetCidr ];
              outbound = "direct";
            };

          final = "direct";
        };
      };

      configFile = (pkgs.formats.json { }).generate "sing-box-config.json" singBoxConfig;
    in
    {
      options.noughty.proxy = {
        enable = lib.mkEnableOption "the sing-box HTTP/SOCKS proxy (bedag work tunnels)";

        additionalConfigFile = lib.mkOption {
          type = lib.types.str;
          default = "/home/${config.noughty.user.name}/git/bedag-setup/singbox.json";
          description = ''
            The private bedag config: SOCKS outbounds and the domain/ip rules
            picking between them. A path rather than content, deliberately --
            this repo is public.
          '';
        };

        listenPort = lib.mkOption {
          type = lib.types.port;
          default = 2080;
          description = ''
            Mixed (HTTP + SOCKS) inbound. Changing it means changing the work
            repo's ssh catch-all too, which hardcodes `socksport=2080`.
          '';
        };

        upstreamDns = lib.mkOption {
          type = lib.types.str;
          default = "1.1.1.1";
          description = ''
            Resolver sing-box uses for its own lookups.

            Explicitly NOT `type = "local"`, which reads /etc/resolv.conf --
            here that is tailscaled's, pointing at MagicDNS on 100.100.100.100,
            which is both inside `tailnetCidr` and not a resolver worth
            trusting for everything sing-box sends `direct`.
          '';
        };

        logLevel = lib.mkOption {
          type = lib.types.enum [
            "trace"
            "debug"
            "info"
            "warn"
            "error"
          ];
          default = "warn";
          description = ''
            "warn" is the resting value. Raise to "debug" to diagnose routing:
            the `router: match[N] => ...` lines name the winning rule and are
            the only external view of how the merged rule set was assembled.
          '';
        };

        transparent = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = ''
            Capture every socket via a tun inbound, rather than only what
            honours `$http_proxy`. This is the difference between a system-wide
            proxy and an opt-in one.

            **Off by request.** It was on and working -- four traps deep, see
            the README -- and was turned back off because an opt-in HTTP/SOCKS
            proxy is what is actually wanted here. The tun is a great deal of
            machinery, and a great many ways to take the laptop off the
            network, in exchange for catching the handful of things that ignore
            `$http_proxy`. Nothing is deleted, so it is one line to try again.

            Everything gated on this goes with it: the tun inbound, the `sniff`
            rule the work config's domain rules need underneath it, the
            `bootstrapProcessNames` carve-out, the tailnet bypass rule, and
            `CAP_NET_ADMIN` on the unit.

            `auto_route` rewrites the default route, so a bad change here takes
            the machine off the network; rollback is the previous generation
            from the boot menu. Test with `curl -4` against an IPv4-only host --
            a dual-stack host can succeed over IPv6 while all IPv4 is broken,
            which once hid exactly that for three rounds.
          '';
        };

        tunStack = lib.mkOption {
          type = lib.types.enum [
            "gvisor"
            "mixed"
            "system"
          ];
          default = "gvisor";
          description = ''
            TCP/IP stack for the tun. "gvisor" is sing-box's own userspace
            stack and the safe default; "system" black-holed all IPv4 here --
            packets arrived (tun0 RX climbing) and were silently dropped with
            no dial and no log. "mixed" is gvisor for TCP, system for UDP.
            Inert unless `transparent` is set.
          '';
        };

        tailnetCidr = lib.mkOption {
          type = lib.types.str;
          default = "100.64.0.0/10";
          description = ''
            The tailnet's CGNAT range. With `tailscaleOutbound.enable` it is
            the match for the rule sending homelab traffic to the endpoint;
            without it, what gets carved out of the tun so tailscaled keeps
            owning its own range.
          '';
        };

        homelabDomainSuffixes = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [
            ".ts.net"
            ".phonkd.net"
          ];
          description = ''
            Name-based half of the tailnet route, for homelab names resolved
            inside sing-box. Inert unless `tailscaleOutbound.enable`.
          '';
        };

        tailscaleBypassCidrs = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ "100.100.100.100/32" ];
          description = ''
            Addresses that stay `direct` despite falling inside `tailnetCidr`,
            matched ahead of the tailnet rule.

            The default is MagicDNS and it is not optional: it sits inside
            100.64.0.0/10, so without this every DNS query would be routed into
            the tailscale endpoint -- which cannot answer until it has
            bootstrapped, which needs DNS.
          '';
        };

        bootstrapProcessNames = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ "ssh" ];
          description = ''
            Processes whose direct connections always go `direct`, matched
            ahead of the work config's rules.

            The bedag SOCKS outbounds are `ssh -fN` DynamicForward tunnels, so
            creating them means first ssh-ing to a gateway. Those gateway
            blocks carry `ProxyCommand None` precisely to skip the proxy, which
            was enough before the tun; with it, ssh's packets are captured at
            the IP layer regardless and sent into the very tunnels the
            connection exists to create.

            Matching the process rather than gateway addresses is deliberate:
            those addresses are work-internal and this repo is public, and it
            is the truer rule anyway -- it is ssh's own dialling that must stay
            direct, because that is what bootstraps the proxy. Narrow in
            practice, since ordinary ssh goes through `socat` (a different
            process, over loopback, never captured).
          '';
        };

        tailscaleOutbound = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = ''
              Give sing-box its own userspace tailscale node and route homelab
              traffic to it, instead of carving the tailnet out of the tun and
              leaving it to tailscaled.

              Off, and **requires `transparent`** to be worth anything: it can
              only carry traffic the tun captures, because `no_proxy` keeps the
              tailnet out of the `$http_proxy` path. Switched on by itself it
              would register a *second* node on the mesh -- tsnet is a separate
              identity from the host's tailscaled, so headscale would gain an
              entry beside `z14` -- and then route nothing to it. Whether it
              registers at all is still unobserved.

              Headscale is therefore not "part of sing-box" here: the homelab
              rides tailscaled directly, which is one fewer thing that can take
              it down. The alternative that avoids the second node, if this is
              ever revisited, is a `direct` outbound with
              `bind_interface = "tailscale0"`: no key needed, but sing-box then
              depends on tailscaled being up.
            '';
          };

          tag = lib.mkOption {
            type = lib.types.str;
            default = "ts-out";
            description = "Endpoint tag; the route and DNS rules refer to it.";
          };

          controlUrl = lib.mkOption {
            type = lib.types.str;
            default = "https://hs.phonkd.net";
            description = ''
              The headscale control plane -- self-hosted, so emphatically not
              the Tailscale SaaS default. Same value modules/tailnet.nix passes
              tailscaled as `--login-server`.
            '';
          };

          hostname = lib.mkOption {
            type = lib.types.str;
            default = "${config.networking.hostName}-singbox";
            description = "Name the tsnet node registers under, distinct from the host's own.";
          };

          authKeySecret = lib.mkOption {
            type = lib.types.str;
            default = "headscale_authkey";
            description = ''
              sops secret holding the headscale pre-auth key. Defaults to the
              one modules/tailnet.nix already uses: it is *reusable*, so a
              second node registers with it and no new secret material has to
              be minted, encrypted or committed.
            '';
          };
        };
      };

      config = lib.mkIf cfg.enable {
        environment.systemPackages = [
          pkgs.sing-box
          # the work ssh catch-all's SOCKS ProxyCommand
          pkgs.socat
        ];

        # The single least guessable thing in this module: sing-box merges
        # repeated `--config` files in order of their PATH, not the order given
        # on the command line. Measured by moving one byte-identical file:
        #
        #   /home/phonkd/.claude/…/x.json -> its rules land at match[0]
        #   /home/phonkd/zz-x.json        -> the same rules land at match[18]
        #
        # 18 being the number of rules in the work config. From /nix/store this
        # file always sorted AFTER /home/phonkd/git/bedag-setup/singbox.json, so
        # its `sniff` rule ran only once every domain rule had been evaluated
        # against a bare address and skipped -- the name was recovered far too
        # late to matter. /etc sorts first (/etc < /home < /nix < /run), which
        # is the whole reason this is not just handed to sing-box from the
        # store. sing-box sorts by the path it is GIVEN, so the symlink here is
        # fine.
        environment.etc."sing-box/config.json".source = configFile;

        # Already declared by modules/tailnet.nix for tailscaled; the module
        # system merges the two, and saying it here keeps this module honest
        # about what it depends on.
        sops.secrets.${ts.authKeySecret} = lib.mkIf ts.enable { };

        # The only part of the config that cannot live in the store, because
        # it is the part holding the key.
        sops.templates."singbox-tailscale.json" = lib.mkIf ts.enable {
          content = builtins.toJSON {
            endpoints = [
              {
                type = "tailscale";
                tag = ts.tag;
                auth_key = config.sops.placeholder.${ts.authKeySecret};
                control_url = ts.controlUrl;
                hostname = ts.hostname;
                # Under StateDirectory below, so the node keeps its identity
                # across restarts instead of re-registering (and littering
                # headscale) every boot.
                state_directory = "/var/lib/sing-box/tailscale";
                # Do not inherit subnet routes other nodes advertise: 201
                # advertises an exit node, and taking that silently would
                # change what "direct" means for the whole host.
                accept_routes = false;
                ephemeral = false;
              }
            ];
          };
        };

        systemd.services.sing-box = {
          description = "sing-box (HTTP/SOCKS proxy on 2080: bedag work tunnels)";
          after = [ "network.target" ];
          wantedBy = [ "multi-user.target" ];

          # Keeps a host without the private checkout cleanly inactive rather
          # than crash-looping. Deliberately the only condition: if the sops
          # template were missing the unit should fail and be restarted, and a
          # host with no work checkout falling back to plain tailscaled is the
          # safe failure mode.
          unitConfig.ConditionPathExists = cfg.additionalConfigFile;

          serviceConfig = {
            ExecStart = lib.concatStringsSep " " (
              [
                "${pkgs.sing-box}/bin/sing-box"
                "run"
                "--config"
                "/etc/sing-box/config.json"
              ]
              ++ lib.concatMap (f: [
                "--config"
                f
              ]) ([ cfg.additionalConfigFile ] ++ lib.optional ts.enable tailscaleConfigFile)
            );
            Restart = "on-failure";
            RestartSec = 30;
            # Root: the tun needs NET_ADMIN, and the config files live under
            # /home and /run/secrets. Hardened where that costs nothing -- this
            # process only opens sockets and reads its configs.
            AmbientCapabilities = lib.mkIf cfg.transparent [ "CAP_NET_ADMIN" ];
            ProtectSystem = "strict";
            ProtectHome = "read-only";
            PrivateTmp = true;
            NoNewPrivileges = true;
            # /var/lib/sing-box for the tsnet identity; required *because* of
            # ProtectSystem = "strict".
            StateDirectory = "sing-box";
            # Blast-radius limiter, after a routing loop here pinned ~4.6 cores
            # until it was stopped by hand. A correctly routing sing-box is
            # nearly idle, so this only ever bites a runaway. It does not fix a
            # loop, it keeps one from making the machine unusable first.
            CPUQuota = "150%";
            LogRateLimitIntervalSec = 10;
            LogRateLimitBurst = 500;
            # NB deliberately no PrivateNetwork: the SOCKS outbounds are the
            # user's loopback ssh tunnels.
          };
        };

        # With `transparent` off these are no longer a convenience, they ARE
        # the proxy: nothing is captured, so anything that does not read them
        # (or dial 2080 itself, as the work ssh catch-all does through socat)
        # simply goes direct. Which is the point -- opt-in was the ask.
        #
        # Still system-wide rather than home-manager's: they reach every login
        # session and every graphical app greetd starts, where
        # `home.sessionVariables` reaches only hm's own shells. Uppercase
        # spellings because plenty of tooling reads only those.
        #
        # NB systemd *system* units do not source /etc/set-environment, so
        # nix-daemon stays unproxied -- on purpose, so builds do not start
        # failing the moment the bedag tunnels are down.
        environment.sessionVariables =
          let
            url = "http://localhost:${toString cfg.listenPort}";
            # Keeps homelab traffic out of the HTTP proxy path, so it goes to
            # tailscaled over the mesh rather than through sing-box. This is
            # what makes the homelab independent of the proxy's health. (Under
            # the tun those packets were captured and routed regardless, and
            # this only saved a pointless extra hop.)
            bypass = "localhost,127.0.0.1,.phonkd.net,100.64.0.0/10";
          in
          {
            http_proxy = url;
            https_proxy = url;
            no_proxy = bypass;
            HTTP_PROXY = url;
            HTTPS_PROXY = url;
            NO_PROXY = bypass;
          };
      };
    };
}
