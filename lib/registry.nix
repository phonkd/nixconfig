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
    desktop = "gnome";
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
      ];
  };

  g14 = {
    kind = "computer";
    platform = "x86_64-linux";
    formFactor = "laptop";
    desktop = "gnome";
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
    deploy.hostname = "192.168.3.201";

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
    deploy.hostname = "192.168.3.203";

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
    deploy.hostname = "192.168.3.204";

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
    deploy.hostname = "192.168.3.205";

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
    # Reachable only at 10.9.0.1 over WireGuard (direct, not via the SOCKS
    # proxy) — `deploy observability` needs the wg-obs tunnel up.
    deploy.hostname = "10.9.0.1";

    extraModules =
      { self, inputs }:
      [
        self.nixosModules."observability"
        self.nixosModules."hetzner-vm"
      ];
  };
}
