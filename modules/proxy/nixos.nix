{ ... }:

# sing-box on NixOS: an HTTP + SOCKS proxy on 127.0.0.1:2080, run as a root
# systemd service. Gated on `noughty.proxy.enable`, which `nixosModules.work`
# sets from the "work" host tag -- today that means z14 and nothing else. See
# plans/work-setup-on-nixos.md for how the work setup reached Linux at all.
#
# App-layer, and only app-layer. What comes through here is what opts in:
# anything honouring $http_proxy (set system-wide at the bottom of this file),
# and the work ssh catch-all, which asks for SOCKS by hand with
# `socat - SOCKS:127.0.0.1:%h:%p,socksport=2080`. That SOCKS half is
# load-bearing for exactly that reason -- this cannot just be an HTTP proxy.
# Everything else on the machine goes straight out, unaware this exists.
#
# TWO traffic classes:
#
#   bedag (the work config's own domain/ip rules) -> SOCKS ssh tunnels
#   everything else                               -> direct
#
# The homelab is a third class that deliberately never reaches sing-box:
# `no_proxy` carries `.phonkd.net` and 100.64.0.0/10, so it goes to tailscaled
# over the headscale mesh instead. That is what keeps homelab reachability
# independent of this service's health, and it is why headscale is not wired
# into sing-box in any form.
#
# THE TUN IS GONE, and so is the tailscale endpoint. There was a transparent
# mode here: a tun inbound with `auto_route` capturing every socket, a `sniff`
# rule to recover the domain names the tun stripped, a `process_name` carve-out
# so ssh could still bootstrap the very tunnels it proxies through, and
# sing-box's own userspace tailscale node so the tailnet could be routed back
# in. It was made to work, four traps deep, and then removed -- a great deal of
# machinery, and a great many ways to take the laptop off the network, in
# exchange for catching the handful of things that ignore $http_proxy.
# modules/proxy/README.md records what it cost to get right;
# `git log -- modules/proxy/` has the code, should it ever be wanted back.
#
# TWO config files, merged by sing-box, split by who may read them:
#
#   1. /etc/sing-box/config.json -- generated here. Public: the inbound, DNS,
#      the direct outbound. Note the path; see `environment.etc` below, it is
#      load-bearing.
#   2. ~/git/bedag-setup/singbox.json -- the bedag SOCKS outbounds and the
#      rules picking between them. Private repo, referenced by path, never
#      restated here. That split is what keeps this repo publishable.
#
# Shares nothing with the macOS half (modules/proxy/darwin.nix) but the
# package. They are close in shape again now that the tun is gone, but not
# close enough to merge: that one needs a DNS split for a macOS-only reason
# (scoped resolvers are invisible to sing-box), this one needs an explicit
# upstream resolver for a Linux-only reason (see `upstreamDns`).

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

      singBoxConfig = {
        log.level = cfg.logLevel;

        dns = {
          servers = [
            {
              type = "udp";
              tag = "upstream";
              server = cfg.upstreamDns;
            }
          ];
          final = "upstream";
        };

        inbounds = [
          {
            type = "mixed";
            tag = "mixed-in";
            listen = "127.0.0.1";
            listen_port = cfg.listenPort;
          }
        ];

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

          # No `rules` of our own, deliberately. Every routing decision on this
          # host belongs to the work config, which brings its own; anything it
          # does not claim lands on `final`. The rules that used to be here --
          # sniff, the tailnet, the ssh carve-out -- existed only to make the
          # tun behave.
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
            which is not a resolver worth trusting for everything sing-box
            sends `direct`. Homelab names do not need it: they never reach this
            proxy at all.
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
      };

      config = lib.mkIf cfg.enable {
        environment.systemPackages = [
          pkgs.sing-box
          # the work ssh catch-all's SOCKS ProxyCommand
          pkgs.socat
        ];

        # The single least guessable thing left in this module: sing-box merges
        # repeated `--config` files in order of their PATH, not the order given
        # on the command line. Measured by moving one byte-identical file:
        #
        #   /home/phonkd/.claude/…/x.json -> its rules land at match[0]
        #   /home/phonkd/zz-x.json        -> the same rules land at match[18]
        #
        # 18 being the number of rules in the work config. /etc sorts first
        # (/etc < /home < /nix < /run), which is the whole reason this is
        # installed here rather than handed to sing-box from the store. sing-box
        # sorts by the path it is GIVEN, so the symlink into the store is fine.
        environment.etc."sing-box/config.json".source = configFile;

        systemd.services.sing-box = {
          description = "sing-box (HTTP/SOCKS proxy on 2080: bedag work tunnels)";
          after = [ "network.target" ];
          wantedBy = [ "multi-user.target" ];

          # Keeps a host without the private checkout cleanly inactive rather
          # than crash-looping: sing-box exits at startup if a --config file is
          # missing.
          unitConfig.ConditionPathExists = cfg.additionalConfigFile;

          serviceConfig = {
            ExecStart = lib.concatStringsSep " " [
              "${pkgs.sing-box}/bin/sing-box"
              "run"
              "--config"
              "/etc/sing-box/config.json"
              "--config"
              cfg.additionalConfigFile
            ];
            Restart = "on-failure";
            RestartSec = 30;
            # Root only because the config files live under /home -- the
            # process itself opens sockets and reads two files. No
            # AmbientCapabilities: CAP_NET_ADMIN was the tun's, and there is no
            # tun. No StateDirectory either; that held the tsnet node identity.
            ProtectSystem = "strict";
            ProtectHome = "read-only";
            PrivateTmp = true;
            NoNewPrivileges = true;
            LogRateLimitIntervalSec = 10;
            LogRateLimitBurst = 500;
            # NB deliberately no PrivateNetwork: the SOCKS outbounds are the
            # user's own loopback ssh tunnels.
          };
        };

        # With no tun these are not a convenience, they ARE the proxy: nothing
        # is captured, so anything that does not read them (or dial 2080
        # itself, as the work ssh catch-all does through socat) simply goes
        # direct. Which is the point -- opt-in is the whole design.
        #
        # System-wide rather than home-manager's: they reach every login
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
            # Keeps homelab traffic out of the proxy path entirely, so it goes
            # to tailscaled over the mesh. This is what decouples homelab
            # reachability from sing-box being healthy.
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
