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
        # --exit-node=201-mono`, `--exit-node=` to stop, or the trayscale applet
        # (modules/desktop.nix). Note this is a *persisted* tailscaled pref
        # (ExitNodeID), so it survives reboots: it is never on until you turn it
        # on, and stays on until you turn it off. Nothing in nix ever sets it,
        # which is what keeps every other device unaffected. Every host not
        # named below keeps the default "none".
        #
        # Enrolment is untouched by all of this — hosts still come up headless
        # via the sops authkey, exactly as the servers do. `tailscale set` is
        # orthogonal to `tailscale up`.
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
      # Everywhere else, pin the same name to obs's PUBLIC address. This is a
      # bootstrap fix, not routing: tailscaled takes over resolv.conf and
      # leaves MagicDNS as the ONLY nameserver (verified on 203:
      # `nameserver 100.100.100.100` and nothing else, despite
      # networking.nameservers being set). 100.100.100.100 is answered by
      # tailscaled itself, so the moment a host loses its tailnet session it
      # can no longer resolve hs.phonkd.net -- which is exactly what it needs
      # to resolve in order to reconnect. That deadlock stranded 203 on
      # 2026-08-11.
      #
      # NB there is no hand-edit escape hatch on NixOS: /etc/hosts is a symlink
      # into the store. The only ways out are `systemctl restart tailscaled`
      # (stopping it releases its resolv.conf takeover, so the base resolvers
      # return and the control URL resolves on start), overwriting the writable
      # /etc/resolv.conf while it is stopped, or a rebuild carrying this pin --
      # which is the point of declaring it here.
      #
      # /etc/hosts is consulted before DNS (nsswitch files->dns), so this makes
      # reconnection independent of whether tailscaled is currently healthy.
      # Hardcoding the IP is acceptable here: it is already hardcoded in the
      # 201 pin above and in modules/dns.nix, and headscale's cert is valid on
      # this path (SNI unchanged).
      networking.hosts =
        if config.noughty.host.name == "201-mono" then
          { "10.9.0.1" = [ "hs.phonkd.net" ]; }
        else
          { "89.167.83.90" = [ "hs.phonkd.net" ]; };
    };
}
