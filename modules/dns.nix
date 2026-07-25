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

          # wildcard DNS
          address = [
            "/.int.phonkd.net/192.168.3.201"
            "/.int.phonkd.net/::"
            "/.segglaecloud.phonkd.net/192.168.3.123"
            "/.segglaecloud.phonkd.net/::"
            "/.w.phonkd.net/192.168.3.201"
            "/.w.phonkd.net/::"
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
