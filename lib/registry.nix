# Single source of truth for hosts. Adding a host = adding a stanza here.
# Routed by platform suffix: *-linux -> nixosConfigurations,
# *-darwin -> darwinConfigurations (see modules/builder.nix).
#
# Fields:
#   kind        : "computer" | "server" | "vm" | "container"  (default "computer")
#   platform    : nixpkgs system string (default "x86_64-linux")
#   formFactor  : "desktop" | "laptop" | "handheld" | "tablet" | "phone" | null
#   desktop     : string or null (e.g. "gnome", "aqua"); null = headless
#   tags        : freeform host tags (e.g. "gigaplayer-client")
#   username    : primary user (default "phonkd")
#   userTags    : freeform user tags
#   gpu         : { vendors = [...]; compute = { vendor; vram; unified; }; }
#
#   deploy      : { hostname = "<ip>"; }  (optional)
#       Opt a NixOS host into `deploy <host>` (deploy-rs, modules/deploy.nix).
#       Only entries that set this become deploy-rs nodes. hostname is the
#       address the Mac reaches it at (LAN .3.x go through the sing-box SOCKS
#       proxy via ~/.ssh/config; 10.9.0.1 over WireGuard). Per-host ssh quirks
#       (e.g. the hetzner VMs' :5432 sshd + id_rsa key) live in that host's
#       programs.ssh.matchBlocks, not here — deploy-rs honors ~/.ssh/config.
#
#   extraModules : { self, inputs }: [ modules ]
#       Escape hatch. Should shrink to per-host hardware paths over time.
{
  blac = {
    kind = "computer";
    platform = "x86_64-linux";
    formFactor = "desktop";
    desktop = "kde";
    tags = [
      "gaming"
      "gigaplayer-client"
    ];
    username = "phonkd";

    gpu = {
      vendors = [ "nvidia" ];
      compute = {
        vendor = "nvidia";
        vram = 16;
      };
    };

    extraModules =
      { self, inputs }:
      [
        /etc/nixos/hardware-configuration.nix
        self.nixosModules.blac
        # blac runs `deploy` (the CLI comes from the shared desktop baseline in
        # modules/desktop.nix). Same reason g14 has this: without it the desktop
        # compiles every homelab closure itself instead of handing x86_64-linux
        # off to 205-builder. Supplies the nixremote key via sops and pins 205's
        # host key.
        self.nixosModules.builder-client
      ];
  };

  g14 = {
    kind = "computer";
    platform = "x86_64-linux";
    formFactor = "laptop";
    desktop = "kde";
    tags = [ "gigaplayer-client" ];
    username = "phonkd";

    gpu = {
      vendors = [ "nvidia" ];
    };

    extraModules =
      { self, inputs }:
      [
        /etc/nixos/hardware-configuration.nix
        self.nixosModules.g14
        # Offload x86_64-linux builds to 205-builder, same as every homelab VM
        # (they get it transitively via oldblac-vm). g14 runs `deploy` too, and
        # without this the laptop compiles every host's closure itself.
        # Supplies the nixremote key via sops and pins 205's host key.
        #
        # It targets 205 over the tailnet (100.64.0.2), so offload works from
        # wherever the laptop is, not just on the home network. It used to point
        # at the LAN address 192.168.3.205, which meant every off-LAN `deploy`
        # silently fell back to compiling the closure on the laptop after the
        # builder failed to answer.
        self.nixosModules.builder-client
      ];
  };

  "201-mono" = {
    kind = "server";
    platform = "x86_64-linux";
    formFactor = null;
    desktop = null;
    tags = [
      "reverse-proxy"
      "homelab-server"
      "observability-sender"
      "vm"
    ];
    username = "phonkd";
    # Tailnet IP (headscale mesh) — was 192.168.3.201 over sing-box. deploy now
    # rides the tailnet, independent of the sing-box SOCKS proxy (whose Mac->201
    # hairpin is dead anyway). See plans/headscale-mesh.md Phase 2.
    deploy.hostname = "100.64.0.5";

    extraModules =
      { self, inputs }:
      [
        self.nixosModules.oldblac-vm
        self.nixosModules."201-mono"
        self.nixosModules."201-wireguard"
        self.nixosModules."homelab-dns"
      ];
  };

  "203-media" = {
    kind = "server";
    platform = "x86_64-linux";
    formFactor = null;
    desktop = null;
    tags = [
      "gigaplayer-server"
      "vm"
      "media-server"
      "observability-sender"
    ];
    username = "phonkd";
    deploy.hostname = "100.64.0.3"; # tailnet (was 192.168.3.203 via sing-box)

    # RTX 3060 Ti (Ampere, 8 GB) passed through from Proxmox — drives Jellyfin
    # NVENC and ollama-cuda (see arr-slime.nix / 203-media.nix). Declaring it
    # here is what gates the nvidia-gpu exporter in the observability sender
    # (noughty.host.gpu.hasNvidia).
    gpu = {
      vendors = [ "nvidia" ];
      compute = {
        vendor = "nvidia";
        vram = 8;
      };
    };

    extraModules =
      { self, inputs }:
      [
        self.nixosModules.oldblac-vm
        self.nixosModules."203-media"
        self.nixosModules."203-shares"
        self.nixosModules."203-vpn"
      ];
  };

  "204-agent" = {
    kind = "server";
    platform = "x86_64-linux";
    formFactor = null;
    desktop = null;
    tags = [
      "vm"
      "observability-sender"
    ];
    username = "phonkd";
    deploy.hostname = "100.64.0.1"; # tailnet (was 192.168.3.204 via sing-box)

    extraModules =
      { self, inputs }:
      [
        self.nixosModules.oldblac-vm
        self.nixosModules."204-agent"
        inputs.hermes-agent.nixosModules.default
        inputs.slop-trove.nixosModules.default
        inputs.llm-noobservability.nixosModules.default
      ];
  };

  "205-builder" = {
    kind = "server";
    platform = "x86_64-linux";
    formFactor = null;
    desktop = null;
    tags = [
      "vm"
      "observability-sender"
    ];
    username = "phonkd";
    deploy.hostname = "100.64.0.2"; # tailnet (was 192.168.3.205 via sing-box)

    extraModules =
      { self, inputs }:
      [
        self.nixosModules.oldblac-vm
        self.nixosModules."205-builder"
      ];
  };

  "Eliss-MacBook-Pro" = {
    kind = "computer";
    platform = "aarch64-darwin";
    formFactor = "laptop";
    desktop = "aqua";
    username = "phonkd";

    extraModules =
      { self, inputs }:
      [
        self.darwinModules.macm4
      ];
  };
  "ext-mail" = {
    kind = "server";
    platform = "x86_64-linux";
    formFactor = null;
    desktop = null;
    tags = [
      "vm"
      "hetzner-vm"
      "mailserver"
      # Ships telemetry over the Hetzner private network (10.0.0.3), not the
      # home-router tunnel — see obsHost in the observability-sender module.
      "observability-sender"
    ];
    username = "phonkd";

    extraModules =
      { self, inputs }:
      [
        self.nixosModules."ext-mail"
        self.nixosModules."hetzner-vm"
      ];
  };
  "observability" = {
    kind = "server";
    platform = "x86_64-linux";
    formFactor = null;
    desktop = null;
    tags = [
      "vm"
      "hetzner-vm"
      "observability-server"
      # Monitor the monitoring host itself: the sender module's push
      # endpoints (10.9.0.1) are this host's own wg-obs address, so the
      # traffic just loops back locally.
      "observability-sender"
    ];
    username = "phonkd";
    # Management (deploy + ssh) now rides the headscale tailnet like every other
    # host — Tailscale SSH by identity, no wg-obs, no sing-box. wg-obs still
    # exists purely as the metrics/log DATA plane (senders push to this host's
    # own 10.9.0.1) until Phase 3 retires it. Was 10.9.0.1 via WireGuard.
    deploy.hostname = "100.64.0.4";

    extraModules =
      { self, inputs }:
      [
        self.nixosModules."observability"
        self.nixosModules."hetzner-vm"
      ];
  };
}
