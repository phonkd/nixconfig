{ self, ... }:

# sing-box on the Mac: an unprivileged launchd agent whose whole job is to put
# a mixed (HTTP + SOCKS) listener on 127.0.0.1:2080 and hand everything the
# work config does not claim straight out.
#
# Deliberately shares nothing with modules/proxy/nixos.nix but the package.
# The two were one file once and the resemblance was misleading -- there is no
# tun here, no root, no second traffic class, no secret, and the one piece of
# DNS cleverness below exists for a macOS-only reason that has no Linux
# analogue. Keeping them apart is cheaper than keeping the differences
# conditional.
#
# The SOCKS half of the listener is load-bearing: the work repo's `Host *` ssh
# catch-all reaches it via `socat - SOCKS:127.0.0.1:%h:%p,socksport=2080`,
# which is why this cannot simply be an HTTP proxy like privoxy.
#
# It is a launchd agent rather than `brew services`: brew's sing-box formula
# does ship a service, but its plist hardcodes a single
# `--config /opt/homebrew/etc/sing-box/config.json` with no way to add
# arguments, so it cannot express the two-file merge this needs. Nothing about
# the homebrew package is wanted here -- the nixpkgs build is the same version.

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
          # Restart on crash, but not on a clean exit. This is also what makes
          # `http_proxy` below honest: it is exported into every shell
          # unconditionally, so before this agent existed any shell opened
          # while sing-box wasn't hand-started pointed at a dead port.
          KeepAlive = {
            Crashed = true;
            SuccessfulExit = false;
          };
          # If ~/git/bedag-setup/singbox.json is missing sing-box exits at
          # startup; back off rather than spin.
          ThrottleInterval = 30;
          # Deliberately no `ProcessType = "Background"`, unlike the syncthing
          # agent next door: this sits in the interactive path (browsers, ssh)
          # and should not take launchd's background I/O throttling.
          StandardOutPath = "${config.home.homeDirectory}/Library/Logs/sing-box.log";
          StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/sing-box.log";
        };
      };

      home.sessionVariables = {
        http_proxy = "http://localhost:2080";
        https_proxy = "http://localhost:2080";
        # `.phonkd.net` (all homelab web) and the tailnet range bypass sing-box
        # so env-proxy clients reach them direct over the mesh. Work domains
        # are unaffected, not being under phonkd.net.
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
          # "info" logs a line per connection, which this was for a long time
          # and which is merely noisy here -- there is no tun to feed it. Left
          # at "warn" to match the Linux side; raise it by hand when debugging.
          log.level = "warn";

          # The macOS-only wrinkle, and the reason this file does not share its
          # DNS handling with the Linux one.
          #
          # sing-box does its own name resolution, and `type = "local"` reads
          # /etc/resolv.conf -- which on macOS is the legacy file holding the
          # work nameservers, NOT the scoped /etc/resolver/<domain> entries
          # modules/dns.nix installs. Only mDNSResponder clients (Safari, curl
          # without a proxy, anything using getaddrinfo) see those. So every
          # homelab name sent through this proxy resolved via public DNS to
          # 192.168.3.201 -- 201's LAN address, unroutable from anywhere but
          # home -- and the dial timed out, while the same URL in a proxy-less
          # browser resolved 100.64.0.5 and worked over the tailnet.
          #
          # Fix: hand `.phonkd.net` to the local dnsmasq, which answers
          # 100.64.0.5 for the internal zones and forwards the rest. Everything
          # else keeps the system resolver, so work DNS is untouched.
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
            # `domain_resolver` is the route that actually works.
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
            # The only rule here: the work config brings its own and nothing in
            # it touches phonkd.net. Anything neither set matches goes straight
            # out.
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
        # NB sing-box merges these by file PATH, not by the order given here --
        # see modules/proxy/nixos.nix, where that bites. It is harmless on
        # darwin: the single `.phonkd.net` rule below competes with nothing in
        # the work config, and there is no sniffing whose position would matter.
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
