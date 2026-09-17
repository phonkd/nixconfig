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
# On NixOS the same wrapper runs as a *system* unit instead, declared by
# `flake.nixosModules.proxy` at the bottom of this file. That is a deliberate
# split, not a symmetry break: see that module's own header. The two halves
# share the wrapper and nothing else, and each platform reaches exactly one of
# them — macOS `homeModules.proxy` via `darwinModules.gui-darwin`, NixOS
# `nixosModules.proxy` via `alwaysImport`.

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

      # NB: there is no Linux branch here any more. The systemd *user* unit
      # that used to sit at this spot moved to `nixosModules.proxy` below and
      # became a *system* unit -- see that module's header for why. This
      # module is now imported on darwin only (via `darwinModules.gui-darwin`),
      # and `isDarwin` survives purely so the wrapper keeps its macOS-shaped
      # `homelabDnsServer` value explicit rather than implicit.

      home.sessionVariables = {
        http_proxy = "http://localhost:2080";
        https_proxy = "http://localhost:2080";
        # `.phonkd.net` (all homelab web) + the tailnet range bypass sing-box so
        # env-proxy CLI clients reach them direct over the mesh. Work domains are
        # unaffected (not under phonkd.net).
        no_proxy = "localhost,127.0.0.1,.phonkd.net,100.64.0.0/10";
      };
    };

  # ---------------------------------------------------------------------------
  # NixOS half: the same wrapper, but a *system* service.
  #
  # This began life (plans/work-setup-on-nixos.md) as a systemd *user* unit
  # mirroring the launchd agent. It is a system unit now because the ask was a
  # system-wide proxy, and a user unit structurally cannot be one:
  #
  #   * `home.sessionVariables` reaches only what home-manager's session init
  #     touches. Units under `systemd --system`, anything greetd starts before
  #     the user session exists, and every non-login context never see it.
  #   * transparent capture (`noughty.proxy.transparent`, the tun inbound)
  #     needs NET_ADMIN, which an unprivileged user agent cannot hold.
  #
  # macOS keeps the launchd agent: it has no equivalent second traffic class
  # to route (no tailnet-vs-tunnel split -- see `homeModules.proxy` above), and
  # a system-wide LaunchDaemon there would buy nothing but root.
  #
  # What deliberately does NOT change: the listener is still the mixed inbound
  # on 127.0.0.1:2080, so the work ssh catch-all's
  # `socat - SOCKS:127.0.0.1:%h:%p,socksport=2080` is untouched; and the bedag
  # outbounds are still the *user's* own `ssh -fN` tunnels on 127.0.0.1:30001+
  # (opened interactively -- they want a yubikey and a PIN). Loopback is shared
  # between system and user, and this unit gets no PrivateNetwork, so root
  # dialling a tunnel phonkd opened is fine.
  #
  # The merged config file lives in the user's home and belongs to the private
  # work repo, not to this one. `ConditionPathExists` is what keeps a host
  # without that checkout cleanly inactive rather than crash-looping -- it
  # replaces the backoff the user unit needed for the same case.
  flake.nixosModules.proxy =
    {
      pkgs,
      lib,
      config,
      ...
    }:
    let
      cfg = config.noughty.proxy;
      sing-box-work = self.wrappers.sing-box-sel.wrap {
        inherit pkgs;
        inherit (cfg) additionalConfigFile listenPort transparent;
        # No local dnsmasq on a NixOS laptop -- tailscaled owns resolv.conf
        # here (modules/tailnet.nix) and answers MagicDNS itself, so the plain
        # `local` resolver is already correct. See the option's own docs.
        homelabDnsServer = null;
      };
    in
    {
      options.noughty.proxy = {
        enable = lib.mkEnableOption "the sing-box system proxy (bedag work tunnels)";

        additionalConfigFile = lib.mkOption {
          type = lib.types.str;
          default = "/home/${config.noughty.user.name}/git/bedag-setup/singbox.json";
          description = ''
            Second `--config`, merged by sing-box with the one this module
            generates. Supplies the SOCKS outbounds and the domain/ip rules
            that pick between them; private, hence a path rather than content.
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

        transparent = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = ''
            Capture every socket on the host via a tun inbound, instead of
            only the things that honour `$http_proxy`.

            Defaults off and is UNTESTED: `auto_route` rewrites the default
            route, and z14 already has tailscale0 with opinions about
            100.64.0.0/10. Turn it on at a console, not over ssh.
          '';
        };
      };

      config = lib.mkIf cfg.enable {
        environment.systemPackages = [
          sing-box-work
          # the work ssh catch-all's SOCKS ProxyCommand
          pkgs.socat
        ];

        systemd.services.sing-box = {
          description = "sing-box (bedag work proxy)";
          after = [ "network.target" ];
          wantedBy = [ "multi-user.target" ];

          unitConfig.ConditionPathExists = cfg.additionalConfigFile;

          serviceConfig = {
            # The wrapper already carries `run --config … --config …`.
            ExecStart = "${sing-box-work}/bin/sing-box";
            Restart = "on-failure";
            RestartSec = 30;
            # Root, because the tun inbound needs NET_ADMIN and because the
            # config file lives under /home. Hardened where that costs
            # nothing: this process only ever opens sockets and reads two
            # config files.
            AmbientCapabilities = lib.mkIf cfg.transparent [ "CAP_NET_ADMIN" ];
            ProtectSystem = "strict";
            ProtectHome = "read-only";
            PrivateTmp = true;
            NoNewPrivileges = true;
            # NB deliberately no PrivateNetwork: the SOCKS outbounds are the
            # user's loopback ssh tunnels.
          };
        };

        # The point of the exercise. `home.sessionVariables` set these for
        # home-manager's shells only; these reach every login session and
        # every graphical app greetd starts.
        #
        # Uppercase spellings are included because plenty of tooling reads
        # only those (curl takes either; go, java and most JVM tooling want
        # the upper forms).
        #
        # NB systemd *system* units do not source /etc/set-environment, so
        # nix-daemon and friends stay unproxied. That is on purpose: builds
        # must not start failing the moment the bedag tunnels are down.
        environment.sessionVariables =
          let
            url = "http://localhost:${toString cfg.listenPort}";
            # `.phonkd.net` (homelab web) and the tailnet range bypass the
            # proxy so env-proxy clients reach them direct over the mesh --
            # the "homelab goes through tailscale" half, as far as it goes
            # today. Work domains are unaffected (not under phonkd.net).
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
        transparent = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = ''
            Add a `tun` inbound with `auto_route`, turning this from an
            opt-in proxy (things that read `http_proxy`, plus the ssh
            catch-all's socat) into a genuinely system-wide one that captures
            every socket on the host.

            Requires running as root and `NET_ADMIN`, hence only
            `nixosModules.proxy` ever sets it — the launchd agent is an
            unprivileged user agent and cannot.

            UNTESTED on z14, which is why it defaults false. `auto_route`
            rewrites the default route, so getting it wrong takes the machine
            off the network; flip it on at a console, not over ssh. See the
            rollout note in plans/work-setup-on-nixos.md.
          '';
        };
        tailnetCidr = lib.mkOption {
          type = lib.types.str;
          default = "100.64.0.0/10";
          description = ''
            Carved out of the tun inbound with `route_exclude_address`, so
            tailscale keeps owning its own CGNAT range and the homelab stays
            reachable over the mesh while `transparent` is on. Inert unless
            `transparent` is set.
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
              # Kept unconditionally, transparent mode included. The work ssh
              # catch-all dials it by hand
              # (`socat - SOCKS:127.0.0.1:%h:%p,socksport=2080`) and would not
              # be served by the tun inbound: socat is asking for SOCKS, not
              # for a route.
              {
                type = "mixed";
                tag = "mixed-in";
                listen = "127.0.0.1";
                listen_port = config.listenPort;
              }
            ]
            ++ lib.optional config.transparent {
              type = "tun";
              tag = "tun-in";
              # Link-local-ish /30 nobody else here uses; the tun device only
              # ever carries traffic between the kernel and sing-box.
              address = [ "172.19.0.1/30" ];
              auto_route = true;
              # `strict_route` also hijacks other interfaces' traffic, which is
              # exactly the fight we do not want with tailscale0.
              strict_route = false;
              route_exclude_address = [ config.tailnetCidr ];
              stack = "system";
            };
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
              }
              # Belt and braces next to `route_exclude_address` above: that
              # keeps tailnet packets out of the tun device, this keeps them
              # out of the *tunnels* if they arrive at the mixed inbound
              # anyway (an env-proxy client that ignored `no_proxy`, say).
              # Our config is the first `--config`, and sing-box keeps merged
              # rules in file order, so this is evaluated before any of the
              # work config's own rules and wins.
              #
              # TODO(homelab-via-tailscale): today "homelab goes through
              # tailscale" is expressed only as this bypass — the packets
              # leave sing-box untouched and tailscaled picks them up. Making
              # it explicit (a tailscale endpoint outbound, so the homelab is
              # reachable through sing-box rather than around it) is the
              # deferred half of this work; see plans/work-setup-on-nixos.md.
              ++ lib.optional config.transparent {
                ip_cidr = [ config.tailnetCidr ];
                outbound = "direct";
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
