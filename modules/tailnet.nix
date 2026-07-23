# Tailscale client for the headscale mesh (control plane:
# modules/homelab/apps/headscale.nix on observability).
#
# Enrols every server into the tailnet and enables Tailscale SSH — over the
# tailnet, access is authorised by tailnet identity + the headscale ACL, so
# there is no sshd port/key/known_hosts to manage (the host's real sshd on :5432
# stays only as off-tailnet break-glass). Headless: registers with a headscale
# pre-auth key delivered by sops.
#
# Wired into modules/builder.nix `alwaysImport`. It references
# sops.secrets.headscale_authkey, a reusable pre-auth key (headscale user
# `phonkd`) minted once headscale was up and `sops set` into
# modules/homelab/global-secrets/secret.yaml. `deploy` a host to enrol it
# (plans/headscale-mesh.md step 4/5).
{ ... }:
{
  flake.nixosModules.tailnet =
    { config, lib, ... }:
    lib.mkIf config.noughty.host.is.server {
      sops.secrets.headscale_authkey = { };

      services.tailscale = {
        enable = true;
        openFirewall = true; # udp/41641 for direct peer-to-peer
        authKeyFile = config.sops.secrets.headscale_authkey.path;
        extraUpFlags = [
          "--login-server"
          "https://hs.phonkd.net"
          "--ssh"
        ];
      };

      # 201-mono can't reach obs's *public* IP: its default gateway
      # (192.168.3.1) diverts Hetzner-bound traffic into the wg-obs tunnel, so
      # hs.phonkd.net (89.167.83.90) is unreachable and enrolment hangs. It does
      # reach obs at the tunnel IP 10.9.0.1 (verified: HTTPS 200), so pin the
      # control-server name there for this host only. The cert is valid over
      # that path (SNI is unchanged) and headscale listens on 0.0.0.0. Every
      # other host reaches the public IP via its own uplink and is unaffected.
      # (201's inability to route to Hetzner is a separate, pre-existing uplink
      # fault — this just keeps mesh control/DERP on the tunnel it can use.)
      networking.hosts = lib.mkIf (config.noughty.host.name == "201-mono") {
        "10.9.0.1" = [ "hs.phonkd.net" ];
      };
    };
}
