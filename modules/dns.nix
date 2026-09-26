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
  # (127.0.0.1) — everything else keeps its normal resolver (accept-dns=false /
  # work-isolation stays intact). Answers point at 201's tailnet IP (100.64.0.5),
  # not its LAN address, so *.w.phonkd.net reaches traefik over the mesh from
  # anywhere. Wired via builder.nix alwaysImportDarwin.
  flake.darwinModules.dns = { config, pkgs, lib, ... }:
    {
      services.dnsmasq = {
        enable = true;
        bind = "127.0.0.1";

        # Upstream (Cloudflare); never actually consulted, every scoped domain
        # below has an explicit `addresses` answer.
        servers = [
          "1.1.1.1"
          "1.0.0.1"
        ];

        # NO leading dot on these keys: nix-darwin names each scoped resolver file
        # after the key verbatim, and macOS reads the filename as the domain — a
        # leading dot produced /etc/resolver/.w.phonkd.net, a dotfile matching
        # nothing, so every *.w.phonkd.net name silently fell through to public
        # DNS. dnsmasq matches a bare domain and all its subdomains, so dropping
        # the dot still covers *.w.phonkd.net.
        addresses = {
          # Internal (ipfilter = true) services; apex is Home Assistant, see
          # modules/homelab/apps/orphans.nix.
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
      # 201 resolves EVERYTHING through the dnsmasq below (dnsmasq + tailscaled's
      # MagicDNS upstream at 100.100.100.100), so an activation that restarts
      # either leaves the host with no DNS for a bit. network-online.target does
      # not cover that gap — it is reached while the resolver is still down, which
      # is how crowdsec's `cscli hub update` ExecStartPre died mid-activation on
      # 2026-08-14 and took the whole deploy with it (switch-to-configuration
      # exits 4 on a failed start job, deploy-rs discards the generation). See
      # plans/201-activation-dns-race.md.
      #
      # This oneshot is the missing barrier — order a unit after it and it starts
      # once lookups actually resolve. NOT RemainAfterExit, so it re-runs on every
      # activation rather than staying `active` from the last boot. It never
      # fails: a timeout just stops the wait, the real consumer still reports the
      # real error, so the barrier itself can't abort the deploy.
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

          # Do NOT serve this host's /etc/hosts as DNS answers to the network —
          # a resolver leaking its own /etc/hosts pins to clients is a bad
          # default (bit us once with the old wg-obs tunnel pin poisoning every
          # client's STUN, see plans/headscale-mesh.md, plans/retire-wg-obs.md).
          no-hosts = true;

          # wildcard DNS
          address = [
            # Internal (ipfilter = true) services answer 201's TAILNET address,
            # not LAN like every other entry here: a client connects to
            # 100.64.0.5, so traefik sees a 100.64.0.x source and the
            # `ip-filter` middleware (already allows 100.64.0.0/10) lets it
            # through from anywhere. Consequence: internal services are
            # tailnet-only, unreachable with tailscaled down even on the LAN.
            # Apex included, so Home Assistant rides the tailnet too.
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
            # Serve the coordinator's PUBLIC IP authoritatively (not forwarded
            # upstream, so it works even while 201's uplink is flapping) — lets
            # clients STUN over their real uplink for direct P2P instead of
            # relay. 201 resolves the same IP for itself via the /etc/hosts pin
            # in tailnet.nix.
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
