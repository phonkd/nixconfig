# Tailscale client for the headscale mesh (control plane:
# modules/homelab/apps/headscale.nix on observability).
#
# Enrols every server AND NixOS desktop (g14/blac) into the tailnet and enables
# Tailscale SSH — over the tailnet, access is authorised by tailnet identity +
# the headscale ACL, so there is no sshd port/key/known_hosts to manage (a
# host's real sshd on :5432 stays only as off-tailnet break-glass). Headless:
# registers with a headscale pre-auth key delivered by sops. This is what lets
# the laptops reach the homelab directly over the mesh — replacing the old
# per-desktop sing-box SOCKS proxy (HM `proxy` module, now Mac-only).
#
# Also carries the tailnet's exit-node wiring: 201-mono advertises itself as an
# exit node and g14 is allowed to use one, both strictly opt-in at runtime. See
# plans/g14-vpn.md (and the rule it narrows in plans/headscale-mesh.md).
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
    lib.mkIf (config.noughty.host.is.server || config.noughty.host.is.nixosDesktop) {
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

        # Exit-node capability — see plans/g14-vpn.md. Nothing here ROUTES
        # anything: 201 offers itself as an exit, g14 is merely allowed to use
        # one. Selecting it stays a runtime act — `tailscale set
        # --exit-node=201-mono`, and `--exit-node=` to stop — never declared, so
        # it does not survive a reboot and no other device is affected. Every
        # host not named below keeps the default "none".
        #
        # "server" enables IP forwarding (already on via networking.nat for wg0
        # on 201 — nat sets the same sysctl at mkOverride 99 vs tailscale's 97,
        # so it resolves to true rather than conflicting). "client" only relaxes
        # reverse-path filtering to "loose", which is what tailscale wants of a
        # host receiving exit-node replies.
        useRoutingFeatures =
          if config.noughty.host.name == "201-mono" then
            "server"
          else if config.noughty.host.name == "g14" then
            "client"
          else
            "none";

        # extraSetFlags, NOT extraUpFlags — this is load-bearing. nixpkgs'
        # tailscaled-autoconnect only runs `tailscale up ... ${extraUpFlags}`
        # while the backend state is NeedsLogin/NeedsMachineAuth/Stopped, so on
        # an already-enrolled node (every host here) an extraUpFlags addition is
        # silently a no-op forever. extraSetFlags drives the separate
        # tailscaled-set unit, which runs `tailscale set` on every activation.
        #
        # --operator lets phonkd run `tailscale set --exit-node=...` without
        # sudo. No real privilege is granted: phonkd is in wheel and could
        # already do this via sudo.
        extraSetFlags =
          if config.noughty.host.name == "201-mono" then
            [ "--advertise-exit-node" ]
          else if config.noughty.host.name == "g14" then
            [ "--operator=phonkd" ]
          else
            [ ];
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
