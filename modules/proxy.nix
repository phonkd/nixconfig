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
        additionalConfigFiles = [ "${config.home.homeDirectory}/git/bedag-setup/singbox.json" ];
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
  # sing-box merges THREE config files here, split by who may see them:
  #
  #   1. the generated one, in the store: inbounds, DNS, routing. Public.
  #   2. ~/git/bedag-setup/singbox.json: the bedag SOCKS outbounds and the
  #      rules picking between them. Private repo, referenced by path.
  #   3. /run/secrets/rendered/singbox-tailscale.json: the tailscale endpoint,
  #      rendered by sops at activation because it carries a pre-auth key.
  #
  # That split is what keeps this repo publishable. Nothing secret is ever a
  # store path, and the key itself is the *existing* reusable headscale
  # authkey `modules/tailnet.nix` already uses -- so enabling the tailscale
  # outbound minted, encrypted and committed exactly nothing new.
  #
  # `ConditionPathExists` on (2) keeps a host without the private checkout
  # cleanly inactive rather than crash-looping -- it replaces the backoff the
  # user unit needed for the same case. It is deliberately the *only*
  # condition: if the sops template were missing the unit should fail and be
  # restarted, not silently skip, and a host with no work checkout falling
  # back to plain tailscaled is the safe failure mode.
  #
  # Traffic classes, once `transparent` is on and the tun is capturing:
  #
  #   homelab (100.64.0.0/10, *.ts.net, *.phonkd.net) -> tailscale endpoint
  #   bedag (the work config's own domain/ip rules)   -> SOCKS ssh tunnels
  #   everything else                                 -> direct
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

      # Rendered at activation, NOT built into the store: it carries the
      # headscale pre-auth key. `sops.placeholder` is a marker string that
      # sops-nix substitutes when it writes the file under
      # /run/secrets/rendered, so the key exists only there (0400 root) and
      # never in /nix/store, which is world-readable, nor in this public repo.
      tailscaleConfigFile = config.sops.templates."singbox-tailscale.json".path;

      # Bare host out of `controlUrl` ("https://hs.phonkd.net" ->
      # "hs.phonkd.net"), so the routing rules can name the control plane. It
      # has to be excluded from the tailscale endpoint by both name and route;
      # see `tailscaleBypassDomains`.
      controlHost =
        let
          afterScheme = lib.last (lib.splitString "//" ts.controlUrl);
          hostPort = lib.head (lib.splitString "/" afterScheme);
        in
        lib.head (lib.splitString ":" hostPort);

      sing-box-work = self.wrappers.sing-box-sel.wrap {
        inherit pkgs;
        inherit (cfg) listenPort transparent tunStack;
        additionalConfigFiles = [
          cfg.additionalConfigFile
        ]
        ++ lib.optional ts.enable tailscaleConfigFile;
        # Only a tag here -- the endpoint it names is defined in the
        # sops-rendered file above, because it is the half with the secret in
        # it. Setting this is what turns the tailnet from a bypass into a real
        # outbound; see the wrapper option.
        tailscaleEndpointTag = if ts.enable then ts.tag else null;
        tailscaleBypassDomains = lib.optional ts.enable controlHost;
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
          default = true;
          description = ''
            Capture every socket on the host via a tun inbound, instead of
            only the things that honour `$http_proxy`. This is the difference
            between a system-wide proxy and an opt-in one, and it is what was
            actually asked for.

            ON again as attempt 3, with exactly one thing changed from the
            attempt that failed: `tunStack` is `"gvisor"` rather than
            `"system"`.

            History, because it is why this option carries so much comment.
            Attempt 1 melted the machine (routing loop, no
            `auto_detect_interface`). Attempt 2 black-holed all IPv4: with the
            tun up, IPv6 to example.com returned 200 while IPv4 to the same
            host timed out, and so did every IPv4-only destination including
            the bedag ssh gateways. The routing rules were never the problem
            -- replaying them through a tun-less sing-box picks `direct`
            correctly -- and the tun was receiving the packets (tun0 RX
            climbing) without dialling or logging anything. That points at the
            stack, hence this attempt.

            Still untried if gvisor is not enough: give the tun a v6 address
            as well (its absence is why the last breakage was invisible), and
            `strict_route = true`.

            **The acceptance test is `curl -4` against an IPv4-only host.**
            Testing against a dual-stack host proves nothing -- that is
            precisely what hid attempt 2 for three rounds.
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
            TCP/IP stack for the tun inbound. See the wrapper option of the
            same name — `"system"` is what swallowed all IPv4 on the first
            attempt. Inert unless `transparent` is set.
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

              Off for now, and deliberately coupled to `transparent`: without
              the tun the only traffic that could reach this endpoint is what
              comes in via `$http_proxy`, and `no_proxy` excludes the tailnet
              from that -- so with `transparent = false` the endpoint would
              register a second node on the mesh and then carry nothing. Turn
              the two back on together once the tun actually passes IPv4.
              Whether the endpoint registers at all is still unobserved.

              Consequence worth knowing: this is a *second* node on the mesh
              (tsnet is a separate identity from the host's tailscaled), so
              headscale gains a machine entry alongside `z14`. The alternative
              that avoids that -- a plain `direct` outbound with
              `bind_interface = "tailscale0"` -- is noted in
              plans/work-setup-on-nixos.md; it needs no key but makes sing-box
              depend on tailscaled being up.
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
              The headscale control plane -- this mesh is self-hosted, so this
              is emphatically not the Tailscale SaaS default. Same value
              `modules/tailnet.nix` passes tailscaled as `--login-server`.
            '';
          };

          hostname = lib.mkOption {
            type = lib.types.str;
            default = "${config.networking.hostName}-singbox";
            description = ''
              Name the tsnet node registers under. Deliberately distinct from
              the host's own tailscaled node, which shares the mesh with it.
            '';
          };

          authKeySecret = lib.mkOption {
            type = lib.types.str;
            default = "headscale_authkey";
            description = ''
              Name of the sops secret holding the headscale pre-auth key.

              Defaults to the key `modules/tailnet.nix` already uses: it is
              *reusable* (headscale user `phonkd`), so a second node can
              register with it and no new secret material has to be minted,
              encrypted or committed. That is the whole reason this feature
              adds nothing sensitive to this public repo.
            '';
          };
        };
      };

      config = lib.mkIf cfg.enable {
        environment.systemPackages = [
          sing-box-work
          # the work ssh catch-all's SOCKS ProxyCommand
          pkgs.socat
        ];

        # Already declared by modules/tailnet.nix for tailscaled itself; the
        # module system merges the two definitions, and saying it here keeps
        # this module honest about what it depends on rather than relying on
        # another module's gate happening to match.
        sops.secrets.${ts.authKeySecret} = lib.mkIf ts.enable { };

        # The only part of the sing-box config that cannot live in the store.
        # Everything else -- inbounds, routes, DNS -- is public and generated
        # by the wrapper; this file holds just the endpoint, because the
        # endpoint holds the key.
        sops.templates."singbox-tailscale.json" = lib.mkIf ts.enable {
          content = builtins.toJSON {
            endpoints = [
              {
                type = "tailscale";
                tag = ts.tag;
                auth_key = config.sops.placeholder.${ts.authKeySecret};
                control_url = ts.controlUrl;
                hostname = ts.hostname;
                # Persisted under StateDirectory below, so the node keeps its
                # identity across restarts instead of re-registering (and
                # littering headscale with machine entries) every boot.
                state_directory = "/var/lib/sing-box/tailscale";
                # Do not pull in subnet routes other nodes advertise: 201
                # advertises an exit node, and silently inheriting routes here
                # would change what "direct" means for the whole host.
                accept_routes = false;
                ephemeral = false;
              }
            ];
          };
        };

        systemd.services.sing-box = {
          description = "sing-box (system proxy: bedag tunnels + tailnet)";
          after = [ "network.target" ];
          wantedBy = [ "multi-user.target" ];

          unitConfig.ConditionPathExists = cfg.additionalConfigFile;

          serviceConfig = {
            # The wrapper already carries `run --config … --config …`.
            ExecStart = "${sing-box-work}/bin/sing-box";
            Restart = "on-failure";
            RestartSec = 30;
            # Root, because the tun inbound needs NET_ADMIN and because the
            # config files live under /home and /run/secrets. Hardened where
            # that costs nothing: this process only opens sockets and reads
            # its configs.
            AmbientCapabilities = lib.mkIf cfg.transparent [ "CAP_NET_ADMIN" ];
            ProtectSystem = "strict";
            ProtectHome = "read-only";
            PrivateTmp = true;
            NoNewPrivileges = true;
            # /var/lib/sing-box, for the tsnet node's identity. Required
            # *because* of ProtectSystem = "strict", which would otherwise
            # leave /var/lib read-only; systemd creates and owns it.
            StateDirectory = "sing-box";
            # Blast radius limiter, added after a routing loop in this very
            # config pinned ~4.6 cores on a fanless-ish laptop until it was
            # stopped by hand. A correctly routing sing-box is nearly idle --
            # it shuffles packets -- so this ceiling is far above anything
            # legitimate and only ever bites a runaway. It does not fix a
            # loop; it keeps one from making the machine unusable while you
            # notice and roll back.
            CPUQuota = "150%";
            # Same idea for the log spew a loop produces.
            LogRateLimitIntervalSec = 10;
            LogRateLimitBurst = 500;
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
            # Keeps homelab traffic out of the *HTTP* proxy path. With
            # `transparent` on these packets are still captured by the tun and
            # still routed to the tailscale endpoint, so this is no longer the
            # thing that makes the homelab work -- it just avoids a pointless
            # extra hop through the mixed inbound for clients that read the
            # variable. Work domains are unaffected (not under phonkd.net).
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
        additionalConfigFiles = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = ''
            Further sing-box config files, each appended as another `--config`.
            sing-box merges them key by key and keeps arrays in file order, so
            the generated config (always first) wins any rule conflict.

            A list rather than a single path because the NixOS side now has two
            of them: the private bedag config, and a sops-rendered file holding
            the tailscale endpoint. That second one is the whole reason the
            auth key never reaches the Nix store.
          '';
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

            `auto_route` rewrites the default route. Rollback is the previous
            generation from the boot menu.
          '';
        };
        tailscaleEndpointTag = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = ''
            Tag of a sing-box `tailscale` endpoint (declared in one of
            `additionalConfigFiles`, because it carries an auth key) to route
            homelab traffic to.

            Setting this flips the tailnet from a *bypass* into a real
            outbound. The difference matters: as a bypass the tailnet was
            carved out of the tun with `route_exclude_address` and left to
            tailscaled; as an outbound those packets are captured and handed
            to sing-box's own userspace tailscale node instead. So the
            exclusion is dropped exactly when this is set — keeping both would
            mean the rules below could never match.

            null keeps the old bypass behaviour.
          '';
        };
        tailnetCidr = lib.mkOption {
          type = lib.types.str;
          default = "100.64.0.0/10";
          description = ''
            The tailnet's CGNAT range. With `tailscaleEndpointTag` set it is
            the match for the route rule sending homelab traffic to that
            endpoint; without it, it is what gets carved out of the tun via
            `route_exclude_address` so tailscaled keeps owning its own range.
            Inert unless `transparent` is set.
          '';
        };
        homelabDomainSuffixes = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [
            ".ts.net"
            ".phonkd.net"
          ];
          description = ''
            Name-based half of the tailnet route. The `ip_cidr` rule alone
            catches anything already resolved into the CGNAT range; these
            catch homelab names whose resolution happens inside sing-box.
            Inert unless `tailscaleEndpointTag` is set.
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
            Which TCP/IP stack the tun inbound uses.

            This started as `"system"`, which was the wrong default to reach
            for: the system stack hands packets to the host stack and is the
            most environment-sensitive of the three. With it, the tun received
            IPv4 packets (tun0 RX climbed) and silently swallowed them -- no
            dial, no error in the log, just a timeout -- while IPv6, which
            never entered the tun for want of a v6 address on it, kept
            working and made the box look healthy.

            `"gvisor"` is sing-box's own userspace stack and the one its
            documentation treats as the safe default. `"mixed"` is gvisor for
            TCP and system for UDP, worth trying if UDP specifically misbehaves.
          '';
        };
        tailscaleBypassCidrs = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ "100.100.100.100/32" ];
          description = ''
            Addresses that must stay `direct` even though they fall inside
            `tailnetCidr`, matched ahead of the tailnet rule.

            The default is MagicDNS, and it is not optional: tailscaled writes
            100.100.100.100 into /etc/resolv.conf, so it is what sing-box's own
            `local` DNS server talks to — and it sits inside 100.64.0.0/10.
            Without this carve-out every system DNS query is routed into the
            tailscale endpoint, which cannot answer until it has bootstrapped,
            which needs DNS. That deadlock, together with a missing
            `auto_detect_interface`, is what pinned four cores the first time
            this shipped.
          '';
        };
        tailscaleBypassDomains = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = ''
            Exact domains that must resolve and route *outside* the tailscale
            endpoint, matched ahead of both the DNS and the route rules.

            This is for the control plane. `hs.phonkd.net` ends in
            `.phonkd.net`, so it would otherwise match `homelabDomainSuffixes`
            and be sent to the very endpoint that cannot come up until it has
            reached the control plane. It is also a public address, unlike the
            homelab names those suffixes are meant for.
          '';
        };
        bootstrapProcessNames = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ "ssh" ];
          description = ''
            Processes whose *direct* connections always go `direct`, matched
            ahead of the work config's own rules.

            This breaks the third and last circular dependency of the
            transparent build, and it is the same shape as the other two: the
            thing that builds the path was being routed down the path.

            The bedag SOCKS outbounds (127.0.0.1:30001+) are `ssh -fN`
            DynamicForward tunnels. Establishing them means first ssh-ing to a
            gateway, and those gateway blocks say `ProxyCommand None`
            precisely so they do NOT go through the proxy. That was enough
            before the tun existed. With `transparent` on, ssh's own packets
            are captured at the IP layer regardless of what ssh_config says,
            matched against the work config's bedag rules, and sent into the
            very tunnels the connection is trying to create. Nothing comes up,
            and the symptom is the downstream one:
            `connect to host localhost port 2222: Connection refused`.

            Matching on the process rather than on gateway addresses is
            deliberate — the addresses are work-internal and this repo is
            public. It is also the more honest rule: it is not those
            particular hosts that must stay direct, it is ssh's own dialling,
            because that is what bootstraps the proxy.

            Safe because it is narrow in practice: the work `Host *` catch-all
            sends ordinary ssh through `socat` (a different process, over
            loopback, never captured by the tun), so the only ssh reaching
            this rule is what already carried `ProxyCommand None` -- gateways,
            LAN, github. Tailnet ssh is matched by the rules above this one
            and still goes to the tailscale endpoint.
          '';
        };
      };

      config =
        let
          useHomelabDns = config.homelabDnsServer != null;
          # The tailnet is either an outbound or a bypass, never both -- see
          # `tailscaleEndpointTag`.
          useTailscale = config.tailscaleEndpointTag != null;
        in
        {
          constructFiles.singBoxConfig.content = builtins.toJSON {
            # "info" logs a line per connection AND per packet connection. That
            # is merely noisy normally, but during the routing loop that this
            # config first shipped with it was itself a large part of the load:
            # a feedback loop logging three lines per iteration at millions of
            # iterations. "warn" still reports the things worth waking up for.
            log.level = "warn";

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
              }
              # MagicDNS, answered by sing-box's own tailscale node rather than
              # by tailscaled's resolv.conf. Needed because with the tun
              # capturing the tailnet we can no longer assume the host resolver
              # is the one that knows these names.
              ++ lib.optional useTailscale {
                type = "tailscale";
                tag = "ts-dns";
                endpoint = config.tailscaleEndpointTag;
              };
              # Again, order matters: the control plane resolves via the
              # system resolver, NOT via the endpoint's own MagicDNS. It ends
              # in .phonkd.net so it would otherwise match the suffix rule
              # below and ask the endpoint to resolve the address it needs in
              # order to exist.
              rules = lib.optional (useTailscale && config.tailscaleBypassDomains != [ ]) {
                domain = config.tailscaleBypassDomains;
                server = "local";
              }
              ++ lib.optional useTailscale {
                domain_suffix = config.homelabDomainSuffixes;
                server = "ts-dns";
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
              # Only while the tailnet is a *bypass*. Once it is a real
              # outbound (`tailscaleEndpointTag`) we need those packets to
              # reach sing-box, so excluding them here would defeat the route
              # rule that sends them to the endpoint.
              route_exclude_address = lib.optional (!useTailscale) config.tailnetCidr;
              stack = config.tunStack;
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

              # NOT optional with a tun inbound, and its absence is what made
              # the first transparent-mode config melt down.
              #
              # `auto_route` points the kernel's default route at the tun. An
              # outbound with no bound interface then follows that default
              # route -- so every "direct" dial left via the tun, was picked
              # straight back up by `tun-in` (source 172.19.0.1, the tun's own
              # address), routed to `direct` again, and round it went. A
              # self-feeding loop that pinned ~4.6 cores.
              #
              # This makes sing-box bind outbounds to the real default
              # interface (wlp98s0 here) instead, which is what breaks the
              # cycle. It is harmless without the tun, so it is set
              # unconditionally rather than guarded on `transparent`: the
              # failure it prevents is far worse than the nothing it costs.
              auto_detect_interface = true;
              # The only rule here — the work config brings its own and nothing in
              # it touches phonkd.net. Anything neither set matches goes straight
              # out. With `homelabDnsServer = null` this list is empty and the
              # work config's own rules are the whole routing table.
              # MUST be first, and is what makes the work config's rules work
              # at all under the tun.
              #
              # Those rules are almost entirely `domain_suffix` (".bedag.ch"
              # and friends). Through the mixed inbound that is fine: an
              # `$http_proxy` client sends `CONNECT wiki.bedag.ch:443`, so
              # sing-box is handed the name. The tun gets no such courtesy --
              # the client resolves the name itself and sing-box sees only
              # 159.144.24.33, matches no domain rule, falls through to
              # `direct`, and times out because that host only exists down a
              # tunnel.
              #
              # Sniffing recovers the name from the TLS ClientHello's SNI (or
              # an HTTP Host header) before the rules are evaluated, so the
              # domain rules match again. It is ordered ahead of everything,
              # including the work config's own rules, because our config is
              # the first `--config`.
              #
              # Only under `transparent`: with the tun absent the name is
              # already known and this would be a no-op, and the Mac's
              # behaviour should not change.
              rules = lib.optional config.transparent { action = "sniff"; }
              ++ lib.optional useHomelabDns {
                domain_suffix = [ ".phonkd.net" ];
                outbound = "direct-homelab";
              }
              # The homelab half of the routing table. Both forms are needed:
              # `ip_cidr` catches anything already resolved into the CGNAT
              # range (ssh to a raw 100.64.x.y, deploy targets), while the
              # suffix rule catches homelab names resolved inside sing-box,
              # before an address exists to match on.
              #
              # Our config is the first `--config` and sing-box keeps merged
              # rules in file order, so these are evaluated before any of the
              # work config's own rules and win. That ordering is what stops a
              # homelab address ever being handed to a bedag tunnel.
              # ORDER IS LOAD-BEARING: these two carve-outs must precede the
              # tailnet rules below, because both describe traffic that falls
              # inside the tailnet by address or by name but must not go to
              # the endpoint -- MagicDNS, and the control plane the endpoint
              # dials to come up at all. Put them after, and the endpoint can
              # never bootstrap. See the option docs for the deadlock.
              ++ lib.optional (useTailscale && config.tailscaleBypassCidrs != [ ]) {
                ip_cidr = config.tailscaleBypassCidrs;
                outbound = "direct";
              }
              ++ lib.optional (useTailscale && config.tailscaleBypassDomains != [ ]) {
                domain = config.tailscaleBypassDomains;
                outbound = "direct";
              }
              ++ lib.optionals useTailscale [
                {
                  ip_cidr = [ config.tailnetCidr ];
                  outbound = config.tailscaleEndpointTag;
                }
                {
                  domain_suffix = config.homelabDomainSuffixes;
                  outbound = config.tailscaleEndpointTag;
                }
              ]
              # Deliberately AFTER the tailnet rules and BEFORE the work
              # config's: `ssh 201-mono` keeps going to the tailscale endpoint,
              # while ssh to a bedag gateway goes straight out instead of into
              # the tunnels it is trying to build. See the option docs.
              ++ lib.optional (config.transparent && config.bootstrapProcessNames != [ ]) {
                process_name = config.bootstrapProcessNames;
                outbound = "direct";
              }
              # Bypass form, for when there is no tailscale endpoint: keep
              # tailnet traffic out of the work tunnels if it arrives at the
              # mixed inbound anyway (an env-proxy client that ignored
              # `no_proxy`, say) and let tailscaled have it.
              ++ lib.optional (config.transparent && !useTailscale) {
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
          ]
          ++ lib.concatMap (f: [ "--config" f ]) config.additionalConfigFiles;
        };
    };
}
