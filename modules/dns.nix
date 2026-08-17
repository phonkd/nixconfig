{
  self,
  inputs,
  ...
}:
{
  # Homelab web (201's traefik) resolved over the headscale tailnet.
  #
  # nix-darwin's services.dnsmasq writes an /etc/resolver/<domain> file per
  # `addresses` entry, so macOS sends ONLY these domains to the local dnsmasq
  # (127.0.0.1) — work DNS and everything else keep their normal resolvers, so
  # this is compatible with the Mac's accept-dns=false / work-isolation stance.
  # The answers point at 201's tailnet IP (100.64.0.5), not its LAN address, so
  # *.w.phonkd.net reaches traefik over the mesh from anywhere (201 opens :443
  # on all interfaces incl. tailscale0). This is what lets homelab web ride the
  # tailnet instead of sing-box — `.w.phonkd.net` is no longer in the sing-box
  # `domains` list (see modules/proxy.nix). Wired via builder.nix
  # alwaysImportDarwin.
  flake.darwinModules.dns = { config, pkgs, lib, ... }:
    {
      services.dnsmasq = {
        enable = true;
        bind = "127.0.0.1";

        # Upstream (Cloudflare) — only ever consulted for scoped domains that
        # lack an explicit `addresses` answer, which never happens here.
        servers = [
          "1.1.1.1"
          "1.0.0.1"
        ];

        # 201-mono tailnet IP (was 192.168.3.201 over the LAN/sing-box).
        #
        # NO leading dot on these keys. nix-darwin names each scoped resolver
        # file after the key verbatim, and macOS reads the *filename* as the
        # domain — so ".w.phonkd.net" produced /etc/resolver/.w.phonkd.net,
        # a dotfile matching nothing, and every *.w.phonkd.net name silently
        # fell through to public DNS (which answers 192.168.3.201, unroutable
        # when away from home). Only "grafana.phonkd.net" worked, because it
        # was the one key without a dot. Verified live: dnsmasq itself
        # answered 100.64.0.5 for notes.int.w.phonkd.net while the system
        # resolver still handed apps 192.168.3.201.
        #
        # dnsmasq matches a bare domain and all its subdomains, so dropping
        # the dot keeps `address=/w.phonkd.net/…` covering *.w.phonkd.net.
        addresses = {
          # Internal (ipfilter = true) services. Covers the apex too, which is
          # Home Assistant — see modules/homelab/apps/orphans.nix.
          "home.phonkd.net" = "100.64.0.5";
          "int.phonkd.net" = "100.64.0.5";
          "w.int.phonkd.net" = "100.64.0.5";
          "w.phonkd.net" = "100.64.0.5";
          "grafana.phonkd.net" = "100.64.0.5";
          "s3.phonkd.net" = "100.64.0.5";
        };
      };
    };
  flake.nixosModules."homelab-dns" = { config, pkgs, lib, ... }:
    {
      # 201 resolves EVERYTHING through the dnsmasq below: /etc/resolv.conf is
      # `nameserver 127.0.0.1`, and /etc/dnsmasq-resolv.conf (written by
      # resolvconf from tailscaled) lists exactly one upstream —
      # 100.100.100.100, Tailscale MagicDNS. So a name lookup on this host
      # needs dnsmasq AND tailscaled, and an activation that restarts either
      # (a nixpkgs bump restarts both) leaves the host with no DNS for
      # anywhere from a second to a couple of minutes.
      #
      # `network-online.target` does not cover that. With scripted networking
      # it pulls in only dhcpcd.service and network-addresses-ens18.service,
      # so it is reached while the resolver is still down — every unit that
      # (correctly) declares `Wants=network-online.target` is told the network
      # is up while lookups still return "Temporary failure in name
      # resolution". That is precisely how crowdsec's `cscli hub update`
      # ExecStartPre died mid-activation on 2026-08-14 and took the whole
      # deploy with it: switch-to-configuration exits 4 on any failed start
      # job and deploy-rs discards the generation. See
      # plans/201-activation-dns-race.md.
      #
      # This oneshot is the missing barrier — order a unit after it and it
      # starts once lookups actually resolve. Two deliberate choices:
      #
      #   * NOT RemainAfterExit, so it re-runs (and re-gates) on every
      #     activation instead of staying `active` from the last boot, which
      #     would make it a no-op exactly when it is needed.
      #   * It never fails. A timeout only means we stop waiting; the real
      #     consumer still reports the real error. A barrier that failed would
      #     itself be the `failed` unit that aborts the deploy.
      #
      # Fixing network-online.target itself would be more honest, but on this
      # host traefik and authelia also wait on it, so it would delay the
      # reverse proxy on every activation. Not worth it for three units.
      systemd.services.dns-online = {
        description = "Wait until DNS resolution actually works";
        after = [
          "network-online.target"
          "dnsmasq.service"
          "tailscaled.service"
        ];
        wants = [ "network-online.target" ];
        serviceConfig = {
          Type = "oneshot";
          TimeoutStartSec = "180s";
          ExecStart = lib.getExe (pkgs.writeShellApplication {
            name = "wait-for-dns";
            runtimeInputs = [
              pkgs.getent
              pkgs.coreutils
            ];
            text = ''
              # A public name, so this exercises the whole chain
              # (dnsmasq -> MagicDNS -> upstream) rather than one of the
              # `address=` entries dnsmasq answers authoritatively by itself.
              probe=one.one.one.one
              i=0
              while [ "$i" -lt 75 ]; do
                if getent hosts "$probe" > /dev/null 2>&1; then
                  exit 0
                fi
                sleep 2
                i=$((i + 1))
              done
              echo "dns-online: '$probe' still does not resolve after 150s;" \
                   "continuing without the barrier" >&2
            '';
          });
        };
      };

      services.dnsmasq = {
        enable = true;
        settings = {
          # Don't grab port 53 on podman bridges — aardvark-dns needs it
          # for container name resolution (--network-alias).
          bind-dynamic = true;
          except-interface = "podman*";

          # Do NOT serve this host's /etc/hosts as DNS answers. This mattered
          # acutely when 201 pinned `10.9.0.1 hs.phonkd.net` (the wg-obs
          # tunnel): without no-hosts, dnsmasq re-served that private pin to
          # every homelab client. Both the pin and the tunnel are gone now —
          # tailnet.nix pins the PUBLIC IP on every host, the same answer the
          # `address=` line below serves — so the hazard is historical. Kept
          # because serving a resolver's own /etc/hosts to the network is a bad
          # default regardless. The original failure, for the record: clients
          # inherited the private pin, so their Tailscale STUN went through the
          # tunnel and was reflected as 10.3.0.0 instead of the home's real
          # public IP — no direct P2P, permanent DERP relaying for every VM.
          # See plans/headscale-mesh.md and plans/retire-wg-obs.md.
          no-hosts = true;

          # wildcard DNS
          address = [
            # Internal (ipfilter = true) services live under home.phonkd.net,
            # and answer 201's TAILNET address — not its LAN one like every
            # other entry here. That is the whole point of the scheme: a client
            # connects to 100.64.0.5, so traefik sees a 100.64.0.x source and
            # the `ip-filter` middleware (which already allows 100.64.0.0/10)
            # lets it through from anywhere, not just from home. The old
            # *.int.w.phonkd.net names answered 192.168.3.201, which is
            # unroutable off the LAN — that is what made every internal service
            # unreachable when away. Headscale pushes the same domain as a
            # split-DNS route to every tailnet client (headscale.nix), so this
            # entry is really only for LAN clients that resolve via 201.
            #
            # Consequence: internal services are tailnet-only. A device with
            # tailscaled down cannot reach them even on the LAN. The apex is
            # included, so Home Assistant rides the tailnet too.
            "/.home.phonkd.net/100.64.0.5"
            "/.home.phonkd.net/::"
            "/.int.phonkd.net/192.168.3.201"
            "/.int.phonkd.net/::"
            "/.segglaecloud.phonkd.net/192.168.3.123"
            "/.segglaecloud.phonkd.net/::"
            "/.w.phonkd.net/192.168.3.201"
            "/.w.phonkd.net/::"
            "/s3.phonkd.net/192.168.3.201"
            "/s3.phonkd.net/::"
            # Serve the coordinator's PUBLIC IP authoritatively to homelab
            # clients (89.167.83.90 = hs.phonkd.net's real A record). This is
            # what un-poisons STUN: VMs now resolve the public IP and STUN over
            # their real uplink, reflecting a usable public endpoint → direct
            # P2P instead of relay. Authoritative (not forwarded upstream) so it
            # keeps working even while 201's own uplink is flapping. 201 now
            # resolves the same public IP for itself, via the /etc/hosts pin in
            # tailnet.nix (files before dns) — which is what finally let 201
            # advertise a real endpoint instead of the tunnel address.
            "/hs.phonkd.net/89.167.83.90"
          ];
          #filter-aaaa = true;
          # optional: refuse invalid domains (like domain-needed)
          domain-needed = true;

          # optional: ignore private reverse lookups (like bogus-priv)
          bogus-priv = true;
        };

      };
      networking.firewall = {
        allowedTCPPorts = [ 53 ];
        allowedUDPPorts = [ 53 ];
      };
      networking.networkmanager.dns = "none";
    };
}
