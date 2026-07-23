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
    };
}
