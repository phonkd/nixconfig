# Tailscale client for the headscale mesh (control plane:
# modules/homelab/apps/headscale.nix). Enrols every server and NixOS desktop, with
# Tailscale SSH replacing per-host sshd/known_hosts management (real sshd stays as
# off-tailnet break-glass). Headless enrolment via a sops pre-auth key. Also wires the
# exit-node opt-in: 201-mono advertises an exit node; g14/z14 may use one at runtime.
# See plans/g14-vpn.md, plans/headscale-mesh.md.
#
# Wired into modules/builder.nix alwaysImport; `deploy` a host to enrol it.
{ ... }:
{
  flake.nixosModules.tailnet =
    { config, lib, ... }:
    let
      # Hosts allowed to use an exit node and drive tailscale without sudo.
      laptops = [
        "g14"
        "z14"
      ];
    in
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

        # Exit-node capability (plans/g14-vpn.md). Nothing here routes traffic: 201 only
        # advertises itself as an exit node; g14/z14 are only allowed to select one.
        # Selection is a runtime act (`tailscale set --exit-node=201-mono`, `--exit-node=`
        # to stop, or the trayscale applet in modules/desktop.nix) and persists across
        # reboots (ExitNodeID) until turned off — nix never sets it. Enrolment is
        # unaffected: hosts still come up headless via the sops authkey.
        #
        # "server" enables IP forwarding (already on via networking.nat's sysctl at
        # mkOverride 99 vs tailscale's 97, so it resolves rather than conflicts).
        # "client" only relaxes reverse-path filtering to "loose", needed to receive
        # exit-node replies. Keyed on `laptops`, not is.nixosDesktop: blac stays "none".
        useRoutingFeatures =
          if config.noughty.host.name == "201-mono" then
            "server"
          else if lib.elem config.noughty.host.name laptops then
            "client"
          else
            "none";

        # extraSetFlags, NOT extraUpFlags — load-bearing. tailscaled-autoconnect only
        # runs `tailscale up ... ${extraUpFlags}` while backend state is
        # NeedsLogin/NeedsMachineAuth/Stopped, so on an already-enrolled node an
        # extraUpFlags addition is silently a no-op forever. extraSetFlags instead
        # drives tailscaled-set, which runs `tailscale set` on every activation.
        # --operator lets phonkd run `tailscale set --exit-node=...` without sudo
        # (no real privilege granted: phonkd is already in wheel).
        extraSetFlags =
          if config.noughty.host.name == "201-mono" then
            [ "--advertise-exit-node" ]
          else if lib.elem config.noughty.host.name laptops then
            [ "--operator=phonkd" ]
          else
            [ ];
      };

      # Pin the coordinator to obs's PUBLIC address on EVERY host (not the tunnel IP:
      # that sends DERP/STUN into the tunnel and gets reflected back, so the host
      # never advertises a real endpoint and stays pinned to DERP forever).
      #
      # This is a bootstrap fix, not routing: tailscaled takes over resolv.conf and
      # leaves MagicDNS (100.100.100.100) as the ONLY nameserver, so once a host loses
      # its tailnet session it can no longer resolve hs.phonkd.net to reconnect — a
      # deadlock that stranded 203 on 2026-08-11. No hand-edit escape hatch on NixOS
      # (/etc/hosts is a store symlink): recovery is `systemctl restart tailscaled`,
      # overwriting /etc/resolv.conf while stopped, or a rebuild carrying this pin.
      # /etc/hosts is consulted before DNS, so this works regardless of whether
      # tailscaled is currently healthy. Hardcoded IP matches modules/dns.nix, which
      # serves the same answer authoritatively to homelab clients.
      networking.hosts = {
        "89.167.83.90" = [ "hs.phonkd.net" ];
      };
    };
}
