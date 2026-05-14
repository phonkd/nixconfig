{
  self,
  inputs,
  ...
}:
{
  flake.darwinModules.dns = { config, pkgs, lib, ... }:
    {
      services.dnsmasq = {
        enable = true;
        bind = "127.0.0.1";

        # Upstream DNS servers (Cloudflare)
        servers = [
          "1.1.1.1"
          "1.0.0.1"
        ];

        # Local domain resolution
        addresses = {
          ".int.phonkd.net" = "192.168.1.201";
          ".w.int.phonkd.net" = "192.168.1.201";
          ".segglaecloud.phonkd.net" = "192.168.1.123";
          ".w.phonkd.net" = "192.168.1.201";
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
            "/.int.phonkd.net/192.168.1.201"
            "/.int.phonkd.net/::"
            "/.segglaecloud.phonkd.net/192.168.1.123"
            "/.segglaecloud.phonkd.net/::"
            "/.w.phonkd.net/192.168.1.201"
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
