# Headscale — self-hosted Tailscale control plane for the homelab mesh.
#
# Runs on observability (public Hetzner box, tag "observability-server"). Every
# server enrols as a Tailscale client (modules/tailnet.nix) and reaches every
# other by MagicDNS name over WireGuard, regardless of physical network — this
# is what retires the hub-and-spoke wg-obs + sing-box + per-host ssh
# proxyCommand/port/key sprawl. See plans/headscale-mesh.md.
#
# Fully self-hosted: embedded DERP relay (no tailscale.com DERP map), so nothing
# but the clients themselves touches Tailscale's infra.
#
# Coordinator is internet-facing (unlike the rest of obs, which is wg-only):
#   - tcp/443  HTTPS control API + embedded DERP-over-HTTPS
#   - tcp/80   Let's Encrypt HTTP-01 challenge
#   - udp/3478 STUN (embedded DERP NAT traversal)
# A public DNS A record hs.phonkd.net -> obs public IP must exist BEFORE first
# deploy, or the ACME cert fails and headscale won't serve HTTPS. If obs sits
# behind a Hetzner cloud firewall, open these there too.
#
# ACL / Tailscale-SSH policy is managed at runtime (`policy.mode = "database"`,
# `headscale policy set`), NOT baked here: the coordinator must start cleanly
# before any user exists, and a malformed file policy would block startup. The
# canonical policy is version-controlled next door in headscale-policy.hujson
# and applied out of band after enrolment (see plans/headscale-mesh.md step 6).
{ ... }:
{
  flake.nixosModules.headscale-server =
    {
      lib,
      noughtyLib,
      ...
    }:
    lib.mkIf (noughtyLib.hostHasTag "observability-server") {
      services.headscale = {
        enable = true;
        address = "0.0.0.0";
        port = 443;
        settings = {
          server_url = "https://hs.phonkd.net";

          dns = {
            base_domain = "ts.phonkd.net"; # MagicDNS suffix; != server_url host
            magic_dns = true;
            override_local_dns = false; # don't hijack clients' resolvers

            # Split DNS: send ONLY home.phonkd.net (the internal, ipfilter =
            # true services) to 201's dnsmasq over the tailnet. Everything else
            # keeps using whatever resolver the client already had —
            # override_local_dns = false above stays honoured, because a split
            # route is a per-domain addition, not a global resolver swap.
            #
            # This is what makes `ipfilter = true` usable away from home. 201's
            # dnsmasq answers 100.64.0.5 for this domain (modules/dns.nix), so
            # the client connects over the tailnet and traefik sees a
            # 100.64.0.x source, which `ip-filter` already allows. Without this
            # a remote client resolves the name through public DNS and gets an
            # RFC1918 address it cannot route to.
            #
            # A wildcard is why this is a split route rather than
            # dns.extra_records: extra_records is per-name, and internal
            # services are added often.
            nameservers.split = {
              "home.phonkd.net" = [ "100.64.0.5" ];
            };
          };

          tls_letsencrypt_hostname = "hs.phonkd.net";
          tls_letsencrypt_challenge_type = "HTTP-01";

          # Embedded DERP — no dependency on tailscale.com relays.
          derp = {
            urls = [ ];
            auto_update_enabled = false;
            server = {
              enabled = true;
              region_id = 999;
              region_code = "headscale";
              region_name = "Headscale Embedded DERP";
              stun_listen_addr = "0.0.0.0:3478";
              automatically_add_embedded_derp_region = true;
            };
          };

          policy.mode = "database";
        };
      };

      networking.firewall.allowedTCPPorts = [
        80
        443
      ];
      networking.firewall.allowedUDPPorts = [ 3478 ];
    };
}
