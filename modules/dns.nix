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
        addresses = {
          ".int.phonkd.net" = "100.64.0.5";
          ".w.int.phonkd.net" = "100.64.0.5";
          ".w.phonkd.net" = "100.64.0.5";
          "grafana.phonkd.net" = "100.64.0.5";
        };
      };
    };
  flake.nixosModules."homelab-dns" = { config, pkgs, lib, ... }:
    {
      services.dnsmasq = {
        enable = true;
        settings = {
          # Don't grab port 53 on podman bridges — aardvark-dns needs it
          # for container name resolution (--network-alias).
          bind-dynamic = true;
          except-interface = "podman*";

          # Do NOT serve this host's /etc/hosts as DNS answers. 201 pins
          # `10.9.0.1 hs.phonkd.net` in /etc/hosts (modules/tailnet.nix) because
          # its own uplink to Hetzner is broken, so it must reach the headscale
          # coordinator over the wg-obs tunnel (10.9.0.1). Without no-hosts,
          # dnsmasq re-served that private pin to EVERY homelab client, so their
          # Tailscale STUN went through the tunnel and got reflected as a private
          # address (10.3.0.0) instead of the home's real public IP — which meant
          # no direct P2P and permanent DERP relaying for all VMs. 201 itself
          # still resolves the pin via nsswitch `files` (checked before dns), so
          # its own coordinator path over the tunnel is unaffected; only what
          # dnsmasq hands to the network changes. See plans/headscale-mesh.md.
          no-hosts = true;

          # wildcard DNS
          address = [
            "/.int.phonkd.net/192.168.3.201"
            "/.int.phonkd.net/::"
            "/.segglaecloud.phonkd.net/192.168.3.123"
            "/.segglaecloud.phonkd.net/::"
            "/.w.phonkd.net/192.168.3.201"
            "/.w.phonkd.net/::"
            # Serve the coordinator's PUBLIC IP authoritatively to homelab
            # clients (89.167.83.90 = hs.phonkd.net's real A record). This is
            # what un-poisons STUN: VMs now resolve the public IP and STUN over
            # their real uplink, reflecting a usable public endpoint → direct
            # P2P instead of relay. Authoritative (not forwarded upstream) so it
            # keeps working even while 201's own uplink is flapping. 201 does not
            # use this answer for itself (files-first → 10.9.0.1 tunnel pin).
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
