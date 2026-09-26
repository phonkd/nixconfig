# Host-specific NixOS config for 203-media (gigaplayer-server VM), generated
# by modules/builder.nix from lib/registry.nix. Cross-host modules
# (gigaplayer-server, server baseline) live in alwaysImport and self-gate on
# tags / is.server.
#
# 203-shares below holds the Samba file-sharing stack moved here from
# 201-mono (together with its data disk, in Proxmox).
{ ... }:
{
  flake.nixosModules."203-media" =
    {
      config,
      pkgs,
      lib,
      ...
    }:
    lib.mkIf (config.noughty.host.name == "203-media") {
      label.labels = [ "vm" ];
      # Passwordless sudo so `deploy 203-media` (deploy-rs) can activate the
      # system profile as root over ssh non-interactively — matches 201/204/205
      # and the Hetzner VMs.
      security.sudo.wheelNeedsPassword = false;
      networking.hostName = "203-media";
      networking.useDHCP = lib.mkForce false;
      networking.interfaces = {
        ens18.ipv4.addresses = [
          {
            address = "192.168.1.203";
            prefixLength = 24;
          }
        ];
        ens19.ipv4.addresses = [
          {
            address = "192.168.3.203";
            prefixLength = 24;
          }
        ];
      };

      # Default route via ens18; a second table sends replies to traffic
      # arriving on ens19 back out ens19, so both addresses stay reachable
      # from remote subnets.
      networking.defaultGateway = {
        address = lib.mkForce "192.168.1.1";
        interface = "ens18";
      };

      # Static networking (useDHCP=false) means DHCP never supplies a
      # resolver, so without this resolvconf writes an empty /etc/resolv.conf
      # and the host can't resolve anything external. That broke
      # `deploy 203` specifically: deploy-rs pulls closures via
      # `nix copy --substitute-on-destination`, which needs a working
      # resolver on THIS host -- with none, deploys fell back to
      # source-building (e.g. ollama-cuda, ~3h) or crashed the substituter
      # workers under failed lookups. homelab-dns runs on 201; the router is
      # the fallback.
      networking.nameservers = [
        "192.168.3.201"
        "192.168.3.1"
      ];
      networking.iproute2.enable = true;
      # `onlink` is required: this can run before ens19 has its
      # 192.168.3.203/24 address, and without it `ip route add ... via
      # 192.168.3.1` fails with "Nexthop has invalid gateway", aborting the
      # script before the ip rule is installed. onlink forces the kernel to
      # treat the gateway as reachable on ens19 regardless of
      # address-assignment timing.
      #
      # The rule MUST carry an explicit priority: `ip rule add` with none
      # gets "lowest existing pref - 1" (the same trap as the 203-vpn postUp
      # rules below). If this runs while tailscaled is already up, that lands
      # at 5209 -- ABOVE Tailscale's 5210 fwmark rules -- diverting
      # Tailscale's own marked underlay out ens19 to the homelab gateway
      # instead of the real WAN. Observed live 2026-08-11: 203 at pref 5209,
      # netcheck `UDP: false / IPv4: (no addr found)`, no direct paths, off
      # the tailnet entirely. 32765 keeps it below Tailscale (5210..5270) and
      # above the wg-quick pair (32763/32764). The while-loop delete clears
      # duplicates from any priority-less run.
      networking.localCommands = ''
        ip route flush table 203 2>/dev/null || true
        ip route add default via 192.168.3.1 dev ens19 table 203 onlink
        while ip rule del from 192.168.3.203 lookup 203 2>/dev/null; do :; done
        ip rule add from 192.168.3.203 lookup 203 pref 32765
      '';

      networking.firewall.allowedTCPPorts = [
        22
        11434 # ollama — 204-agent (slop-trove) reaches this over ens19/192.168.3.0
      ];

      # Embeddings for slop-trove (bge-m3) on the RTX 3060 Ti passed through
      # for Jellyfin transcoding (arr-slime.nix) -- idle GPU cycles, and
      # unlike blac this host is always on. Same 192.168.3.0/24 as 204-agent
      # via ens19, no inter-VLAN routing needed.
      services.ollama = {
        enable = true;
        package = pkgs.ollama-cuda;
        host = "0.0.0.0";
        port = 11434;
        loadModels = [ "bge-m3" ];
      };
      swapDevices = [
        {
          device = "/var/lib/swapfile";
          size = 4 * 1024;
        }
      ];
      nix.gc = lib.mkForce {
        automatic = true;
        dates = "daily";
        options = "--delete-older-than 3d";
      };
      nix.settings.require-sigs = false;
    };

  # Samba file shares, moved from 201-mono together with the data disk.
  # The disk was reassigned to the 203 VM in Proxmox with the serial
  # "shares", so it appears at /dev/disk/by-id/virtio-shares.
  flake.nixosModules."203-shares" =
    {
      config,
      pkgs,
      lib,
      ...
    }:
    lib.mkIf (config.noughty.host.name == "203-media") {
      systemd.tmpfiles.rules = [
        "d /mnt/Shares 0755 root root -"
        "d /mnt/solo-sata 0755 root root -"
        "d /mnt/Shares/Public 2775 smbpublic smbpublic -"
        "d /mnt/Shares/SemiPublic 2770 phonkd phonkd -"
        "d /mnt/Shares/this-is-my-own-private-property-and-you-are-not-welcome-here 0750 phonkd phonkd -"
        "d /mnt/Shares/this-is-my-own-private-property-and-you-are-not-welcome-here/clips 0750 phonkd phonkd -"
        # The private share's ACL is group::--- so being in the `phonkd`
        # group doesn't help. Jellyfin only needs clips: bare traverse (x, no
        # r) on the private root (can cd into a known path but not list it),
        # full read+execute on clips itself. A+ recurses existing content;
        # `d:` on clips covers anything written later.
        "A+ /mnt/Shares/this-is-my-own-private-property-and-you-are-not-welcome-here - - - - u:jellyfin:x"
        "A+ /mnt/Shares/this-is-my-own-private-property-and-you-are-not-welcome-here/clips - - - - u:jellyfin:rX,d:u:jellyfin:rX"
      ];

      users.users.smbpublic = {
        isSystemUser = true;
        description = "Samba guest share user";
        group = "smbpublic";
        home = "/var/empty";
      };

      users.groups.smbpublic = { };

      services.samba = {
        enable = true;
        securityType = "user";
        openFirewall = true;
        settings = {
          global = {
            "workgroup" = "WORKGROUP";
            "server string" = "baaaalright";
            "netbios name" = "smbnix";
            "security" = "user";
            # 100.64.0.0/10 = the headscale tailnet -- clients mount
            # smb://100.64.0.3 directly over the mesh (the Mac's old sing-box
            # 127.0.0.1:8445 forward is retired). Without this, samba's
            # `hosts deny 0.0.0.0/0` refuses the tailnet even though port 445
            # is reachable.
            "hosts allow" =
              "100.64.0.0/10 192.168.3.0/24 192.168.2.0/24 192.168.1.0/24 10.89.0.0/24 127.0.0.1 localhost 10.8.0.1/24";
            "hosts deny" = "0.0.0.0/0";
            "guest account" = "smbpublic";
            "map to guest" = "bad user";
            "host msdfs" = "no";
          };
          "public" = {
            "path" = "/mnt/Shares/Public";
            "browseable" = "yes";
            "read only" = "no";
            "guest ok" = "yes";
            "create mask" = "0664";
            "directory mask" = "2775";
            "force user" = "smbpublic";
            "force group" = "smbpublic";
          };
          "semipublic" = {
            "path" = "/mnt/Shares/SemiPublic";
            "browseable" = "yes";
            "read only" = "yes";
            "guest ok" = "yes";
            "create mask" = "0664";
            "directory mask" = "2775";
            "write list" = "@phonkd phonkd";
            "force create mode" = "0660";
            "force directory mode" = "2770";
            "guest account" = "smbpublic";
          };
          "private" = {
            "path" = "/mnt/Shares/this-is-my-own-private-property-and-you-are-not-welcome-here";
            "browseable" = "yes";
            "read only" = "no";
            "guest ok" = "no";
            "create mask" = "0644";
            "directory mask" = "0755";
            "force user" = "phonkd";
            "force group" = "phonkd";
          };
        };
      };

      services.samba-wsdd = {
        enable = true;
        openFirewall = true;
      };

      networking.firewall.enable = true;
      networking.firewall.allowPing = true;
      services.avahi = {
        enable = true;
        nssmdns = true;
        publish = {
          enable = true;
          addresses = true;
          domain = true;
          hinfo = true;
          userServices = true;
          workstation = true;
        };
      };
      fileSystems."/mnt/Shares" = {
        device = "/dev/disk/by-id/virtio-shares";
        fsType = "ext4";
        autoFormat = true;
        autoResize = true;
        options = [
          "users"
          "nofail"
        ];
      };
      fileSystems."/mnt/solo-sata" = {
        device = "/dev/disk/by-id/virtio-solo-sata";
        fsType = "ext4";
        autoFormat = true;
        autoResize = true;
        options = [
          "users"
          "nofail"
        ];
      };
    };

  # ProtonVPN WireGuard full-tunnel egress for 203, run on the HOST (not the
  # UniFi gateway) so Tailscale can coexist. wg-quick's full-tunnel routing
  # (AllowedIPs 0.0.0.0/0, no explicit `table` -> "auto") uses fwmark + `ip
  # rule ... suppress_prefixlength 0`, not a plain `default dev wg0` in the
  # main table. Tailscale independently installs its own higher-priority
  # ip-rules for its fwmark (0x80000, pref ~5210 << wg-quick's ~32764), so
  # Tailscale's underlay bypasses wg0 via the real WAN (direct P2P) while
  # everything else on 203 egresses via Proton.
  #
  # This replaces the old UniFi policy-based route that forced ALL of 203
  # through a gateway-level tunnel (and captured Tailscale's STUN, pinning it
  # to DERP). That UniFi `203` PBR MUST stay removed: since the fwmark split
  # is local to 203, a gateway-level PBR by MAC would re-capture everything
  # including Tailscale and defeat this.
  #
  # Only the client PrivateKey is secret (sops); server pubkey/endpoint/
  # tunnel address are public config. Proton's `DNS = 10.2.0.1` is
  # deliberately OMITTED -- rewriting resolv.conf would fight Tailscale
  # MagicDNS (100.100.100.100) + homelab-dns and break 203's internal
  # resolution; external names still resolve via homelab-dns (through 201),
  # not leaked from 203. IPv6 is dropped (203 has no native v6; Proton's
  # IPv4 endpoint is enough). No kill-switch yet -- a naive one would DROP
  # Tailscale (its traffic leaves via the real WAN, not wg0); a
  # Tailscale-aware one can be added later.
  flake.nixosModules."203-vpn" =
    {
      config,
      pkgs,
      lib,
      ...
    }:
    lib.mkIf (config.noughty.host.name == "203-media") {
      sops.secrets.proton_wg_privatekey = { };

      # REQUIRED for Tailscale to survive alongside the full tunnel. NixOS'
      # default checkReversePath = true emits a strict nftables rpfilter
      # keyed on **mark** (`fib saddr . mark . iif check exists accept`).
      # Tailscale's underlay is marked 0x80000 so ip-rule 5210 sends it out
      # ens18 (the fwmark split above) -- but replies arrive on ens18 with
      # mark 0, and the *unmarked* route to any internet address is wg0 (a
      # 0.0.0.0/0 tunnel). So the fib check asks "route to 8.8.8.8, mark 0,
      # via ens18?", finds wg0 instead, and drops every reply to Tailscale's
      # traffic.
      #
      # Proton itself is unaffected: wg-quick's own premangle chain restores
      # its 0xca6c ct mark on inbound UDP, so its reverse path resolves --
      # nothing does that for Tailscale.
      #
      # Symptoms, all at once: netcheck `UDP: false / IPv4: (no addr
      # found)`, no STUN, no direct paths, tailscaled stuck in `NoState` --
      # while `curl` from the same host worked fine (unmarked, goes via
      # Proton). Verified 2026-08-11: marked pings reached 192.168.1.1 (same
      # subnet, no rpfilter drop) but 100% loss to every internet address;
      # unmarked 0% loss.
      #
      # "loose" drops the `iif` term so a route via ANY interface is enough
      # -- the same setting services.tailscale's useRoutingFeatures =
      # "client"/"both" turns on, for the same reason.
      networking.firewall.checkReversePath = "loose";

      # IPv6 KILL-SWITCH. Proton's tunnel below is `allowedIPs =
      # [ "0.0.0.0/0" ]` only -- IPv4-only. The moment this LAN carries
      # IPv6, SLAAC would hand 203 a global v6 address and a v6 default
      # route out ens18, and every IPv6 flow would bypass Proton straight to
      # the internet -- a silent VPN leak (v4 still looks correct in every
      # test while AAAA-record traffic egresses from the home address).
      #
      # Can't be fixed at the router: 201 needs IPv6 (it's the exit node,
      # and an exit node advertises ::/0 regardless -- see
      # modules/homelab/apps/headscale-policy.hujson), and 201/203 share
      # 192.168.3.0/24, so any RA reaching one reaches the other.
      #
      # Refusing RAs is the surgical fix: no RA, no global address, no v6
      # default, nothing to leak. `autoconf = 0` is belt-and-braces against
      # an RA arriving some other way. Both are per-interface --
      # `conf.all.accept_ra` isn't consulted for this knob -- and
      # tailscale0 is deliberately left alone so Tailscale keeps its fd7a:
      # ULA and the tailnet stays dual-stack.
      #
      # Revisit only if Proton's peer gains ::/0; until then IPv6 on 203 is
      # a leak by construction, not a missing feature.
      boot.kernel.sysctl = {
        "net.ipv6.conf.ens18.accept_ra" = 0;
        "net.ipv6.conf.ens19.accept_ra" = 0;
        "net.ipv6.conf.ens18.autoconf" = 0;
        "net.ipv6.conf.ens19.autoconf" = 0;
      };

      networking.wg-quick.interfaces.wg0 = {
        address = [ "10.2.0.2/32" ];
        privateKeyFile = config.sops.secrets.proton_wg_privatekey.path;

        # The observability push no longer needs rescuing from this tunnel:
        # it goes to 100.64.0.4 over the tailnet, and Tailscale's own
        # ip-rules (pref 5270 -> table 52) sit above wg-quick's, so tailnet
        # traffic never enters wg0. The explicit `10.9.0.0/24 via
        # 192.168.1.1` route that used to keep the metrics push on the
        # router path went with wg-obs -- see plans/retire-wg-obs.md.
        #
        # Re-pin wg-quick's two policy rules BELOW Tailscale's -- REQUIRED,
        # not cosmetic. wg-quick adds them with no explicit priority, so
        # iproute2 assigns "lowest existing pref - 1"; with tailscaled
        # already up (fixed prefs 5210..5270) they'd land at 5209/5208 --
        # ABOVE Tailscale's -- and `not fwmark 0xca6c lookup 51820` would
        # swallow both Tailscale's own marked underlay (meant to bypass via
        # 5210) and tailnet-destined packets (meant for table 52 via 5270)
        # into the Proton tunnel. Observed: `ping 100.64.0.x` 100% loss
        # while `tailscale ping` still worked via 10.9.0.1, netcheck `UDP:
        # false / IPv4: (no addr found)`, no direct P2P. Fixed high prefs
        # restore the intended order (Tailscale first, Proton catch-all).
        # Verified live: ping obs 0% loss, netcheck shows the real WAN IP,
        # egress still Proton, metrics to 10.9.0.1 intact. 32765 is taken by
        # the ens19 rule above, so 32763/64 here. Add-then-delete + `while`
        # loops keep this idempotent.
        postUp = ''
          fwmark="$(${pkgs.wireguard-tools}/bin/wg show wg0 fwmark 2>/dev/null || true)"
          if [ -n "$fwmark" ] && [ "$fwmark" != "off" ]; then
            table=$(( fwmark ))
            while ${pkgs.iproute2}/bin/ip -4 rule del table main suppress_prefixlength 0 2>/dev/null; do :; done
            while ${pkgs.iproute2}/bin/ip -4 rule del not fwmark "$fwmark" table "$table" 2>/dev/null; do :; done
            ${pkgs.iproute2}/bin/ip -4 rule add table main suppress_prefixlength 0 pref 32763
            ${pkgs.iproute2}/bin/ip -4 rule add not fwmark "$fwmark" table "$table" pref 32764
          fi
        '';

        peers = [
          {
            publicKey = "/i7jCNpcqVBUkY07gVlILN4nFdvZHmxvreAOgLGoZGg=";
            allowedIPs = [ "0.0.0.0/0" ];
            endpoint = "146.70.86.114:51820";
            persistentKeepalive = 25;
          }
        ];
      };
    };
}
