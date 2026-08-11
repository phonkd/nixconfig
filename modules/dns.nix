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
          "int.phonkd.net" = "100.64.0.5";
          "w.int.phonkd.net" = "100.64.0.5";
          "w.phonkd.net" = "100.64.0.5";
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
