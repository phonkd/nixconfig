{ ... }:

# sing-box on NixOS: an HTTP + SOCKS proxy on 127.0.0.1:2080, run as a root
# systemd service. Gated on `noughty.proxy.enable`, set by `nixosModules.work`
# from the "work" host tag (today: z14 only). See plans/work-setup-on-nixos.md.
#
# App-layer only: anything honouring $http_proxy (set system-wide below),
# plus the work ssh catch-all's `socat - SOCKS:127.0.0.1:%h:%p,socksport=2080`
# -- that SOCKS half is load-bearing, this can't just be an HTTP proxy.
# Everything else goes straight out, unaware this exists.
#
# Three traffic classes: Reddit -> Proton WireGuard; bedag (the work config's
# domain/ip rules) -> SOCKS ssh tunnels; everything else -> direct. The homelab
# never reaches sing-box: `no_proxy` carries `.phonkd.net` and 100.64.0.0/10,
# routing to tailscaled over the headscale mesh -- keeping homelab
# reachability independent of this service's health.
#
# THE TUN IS GONE: a transparent mode (tun inbound, sniff, ssh carve-out,
# sing-box's own tailscale node) worked but cost a great deal of machinery
# and ways to take the laptop off the network, for catching only what
# ignores $http_proxy. modules/proxy/README.md and
# `git log -- modules/proxy/` have the details.
#
# Three config files on z14, merged by sing-box: /etc/sing-box/config.json
# (public routes/inbound/DNS/direct outbound), the private work config under
# ~/git/bedag-setup, and a runtime SOPS template holding Proton's WireGuard
# key. The /etc path sorts first so Reddit's rule precedes work rules.
#
# Shares only the package with the macOS half (modules/proxy/darwin.nix):
# that one needs a DNS split for a macOS-only reason (scoped resolvers
# invisible to sing-box), this one needs an explicit upstream resolver for a
# Linux-only reason (see `upstreamDns`).

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
      redditVpn = cfg.protonReddit.enable;

      redditDomains = [
        "reddit.com"
        "redd.it"
        "redditstatic.com"
        "redditmedia.com"
      ];

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

          # /etc sorts before the private config under /home, so these rules
          # run before the work rules. Other destinations keep their existing
          # work routing and direct fallback.
          rules = lib.optionals redditVpn [
            {
              domain_suffix = redditDomains;
              outbound = "proton-reddit";
            }
          ];
          final = "direct";
        };
      };

      configFile = (pkgs.formats.json { }).generate "sing-box-config.json" singBoxConfig;
    in
    {
      options.noughty.proxy = {
        enable = lib.mkEnableOption "the sing-box HTTP/SOCKS proxy (bedag work tunnels)";

        protonReddit.enable = lib.mkEnableOption "ProtonVPN egress for Reddit through sing-box";

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
        sops.secrets.proton_z14_wg_privatekey = lib.mkIf redditVpn { };
        sops.templates."sing-box-proton-reddit.json" = lib.mkIf redditVpn {
          content = builtins.toJSON {
            endpoints = [
              {
                type = "wireguard";
                tag = "proton-reddit";
                address = [
                  "10.2.0.2/32"
                  "2a07:b944::2:2/128"
                ];
                private_key = config.sops.placeholder.proton_z14_wg_privatekey;
                peers = [
                  {
                    address = "79.127.184.1";
                    port = 51820;
                    public_key = "snSASVcKZegpITPNw2scm44NBC6NPUropoTkfEGtq18=";
                    allowed_ips = [
                      "0.0.0.0/0"
                      "::/0"
                    ];
                    persistent_keepalive_interval = 25;
                  }
                ];
              }
            ];
          };
        };

        environment.systemPackages = [
          pkgs.sing-box
          # the work ssh catch-all's SOCKS ProxyCommand
          pkgs.socat
        ];

        # The single least guessable thing here: sing-box merges repeated
        # `--config` files in order of their PATH, not the order given on the
        # command line. Measured by moving one byte-identical file:
        #
        #   /home/phonkd/.claude/…/x.json -> its rules land at match[0]
        #   /home/phonkd/zz-x.json        -> the same rules land at match[18]
        #
        # (18 = the rule count in the work config.) /etc sorts first (/etc <
        # /home < /nix < /run), which is why this is installed here rather
        # than handed to sing-box from the store -- sing-box sorts by the
        # path it's GIVEN, so the symlink into the store is fine.
        environment.etc."sing-box/config.json".source = configFile;

        systemd.services.sing-box = {
          description = "sing-box (HTTP/SOCKS proxy on 2080: bedag work tunnels)";
          after = [ "network.target" ];
          wantedBy = [ "multi-user.target" ];

          # Keeps a host without the private checkout cleanly inactive rather
          # than crash-looping: sing-box exits at startup if a --config file
          # is missing.
          unitConfig.ConditionPathExists = cfg.additionalConfigFile;

          serviceConfig = {
            ExecStart = lib.concatStringsSep " " ([
              "${pkgs.sing-box}/bin/sing-box"
              "run"
              "--config"
              "/etc/sing-box/config.json"
              "--config"
              cfg.additionalConfigFile
            ] ++ lib.optionals redditVpn [
              "--config"
              config.sops.templates."sing-box-proton-reddit.json".path
            ]);
            Restart = "on-failure";
            RestartSec = 30;
            # Root only because the config files live under /home; the
            # process itself just opens sockets and reads the configs. No
            # AmbientCapabilities: CAP_NET_ADMIN was the tun's, now gone. No
            # StateDirectory either; that held the tsnet node identity.
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

        # With no tun these ARE the proxy: anything that doesn't read them
        # (or dial 2080 directly, as the ssh catch-all does via socat) goes
        # direct -- opt-in is the whole design.
        #
        # System-wide, not home-manager's: they reach every login session and
        # graphical app greetd starts, where `home.sessionVariables` reaches
        # only hm's shells. Uppercase too, since plenty of tooling reads only
        # those.
        #
        # systemd *system* units don't source /etc/set-environment, so
        # nix-daemon stays unproxied on purpose -- builds shouldn't fail just
        # because the bedag tunnels are down.
        environment.sessionVariables =
          let
            url = "http://localhost:${toString cfg.listenPort}";
            # Keeps homelab traffic out of the proxy path so it goes to
            # tailscaled over the mesh -- decoupling homelab reachability
            # from sing-box's health.
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
