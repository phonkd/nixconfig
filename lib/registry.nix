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
#       Opts a NixOS host into `deploy <host>` (deploy-rs, modules/deploy.nix).
#       Only entries setting this become deploy-rs nodes; hostname is the
#       host's tailnet IP (100.64.0.x), the address the Mac reaches it at.
#       Per-host ssh quirks (e.g. the hetzner VMs' :5432 sshd + id_rsa key)
#       live in programs.ssh.matchBlocks, not here — deploy-rs honors
#       ~/.ssh/config.
#
#   extraModules : { self, inputs }: [ modules ]
#       Escape hatch. Should shrink to per-host hardware paths over time.
{
  blac = {
    kind = "computer";
    platform = "x86_64-linux";
    formFactor = "desktop";
    desktop = "hyprland";
    tags = [
      "gaming"
      "gigaplayer-client"
      # The only session on this host now (KDE dropped). See modules/hyprland/
      # and plans/hyprland.md.
      "hyprland"
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
        # blac runs `deploy` (shared desktop baseline, modules/desktop.nix);
        # without it the desktop compiles every homelab closure itself
        # instead of offloading x86_64-linux to 205-builder. Supplies the
        # nixremote key via sops and pins 205's host key.
        self.nixosModules.builder-client
        # Hyprland -- the session (gated on "hyprland"). Placed here rather
        # than builder.nix's alwaysImport to avoid touching a file
        # mid-refactor; it self-gates and would fit there equally well.
        self.nixosModules.hyprland
      ];
  };

  g14 = {
    kind = "computer";
    platform = "x86_64-linux";
    formFactor = "laptop";
    desktop = "hyprland";
    tags = [
      "gigaplayer-client"
      # The only session -- see the note on blac's tag.
      "hyprland"
    ];
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
        # (via oldblac-vm); without it the laptop compiles every host's
        # closure itself. Supplies the nixremote key via sops, pins 205's
        # host key, and targets 205 over the tailnet (100.64.0.2) so offload
        # works from anywhere -- the old LAN address let an off-LAN `deploy`
        # silently fall back to compiling locally when the builder didn't
        # answer.
        self.nixosModules.builder-client
        # Hyprland -- see the note on blac's entry.
        self.nixosModules.hyprland
      ];
  };

  # The ASUS Zenbook 14 UM3406GA. Same *role* as g14 -- gigaplayer/build-offload
  # client, no deploy.hostname (laptops are deploy clients, not targets) --
  # different hardware: Radeon 840M iGPU, no dGPU, no ROG firmware, no
  # fingerprint reader. See plans/z14-zenbook.md.
  #
  # Hyprland is the only session, as on blac/g14. `desktop` must stay
  # non-null: it drives noughty.host.is.nixosDesktop (desktop baseline +
  # modules/hyprland/) and selects the greetd/tuigreet login screen in
  # modules/desktop.nix.
  z14 = {
    kind = "computer";
    platform = "x86_64-linux";
    formFactor = "laptop";
    desktop = "hyprland";
    # work setup on this host (plans/work-setup-on-nixos.md): sing-box as an
    # HTTP/SOCKS proxy on 127.0.0.1:2080 (opt-in). Everything it reaches
    # self-gates on this tag; removing it is the rollback.
    #
    # What it re-arms: the bedag ssh config's `Host *` catch-all dials SOCKS
    # via ProxyCommand for *every* destination -- `ssh ext-mail` used to fail
    # as "Connection closed by UNKNOWN port 65535" (matched no block, fell
    # through to the proxy). The tag brings homeModules.work-ssh-bypass,
    # punching the tailnet, LAN and github.com back out; verify with
    # `ssh 201-mono` after deploy.
    tags = [
      "gigaplayer-client"
      "hyprland"
      "work"
      # fosi-mc331 lived here during the DSP noise-gate fix (solved; see
      # plans/fosi-mc331-noise-gate.md) -- removed since the amp shouldn't
      # depend on a laptop being awake. modules/fosi-mc331.nix stays dormant;
      # adding this tag to the box cabled to the amp is the entire deployment.
    ];
    username = "phonkd";

    # AMD only -- load-bearing: keeps nvidia-desktop's config block off
    # (gates on gpu.hasNvidia) while the desktop baseline still arrives via
    # that module's unconditional `imports`.
    #
    # No `compute` set, though ollama runs against the 840M via Vulkan
    # (modules/hosts/z14.nix): compute.vendor = "amd" would imply hasROCm,
    # which doesn't work on gfx1153, and builder.nix drops `acceleration`
    # from the registry anyway so "vulkan" can't be spelled here. Nothing
    # reads hasROCm/hasCuda today -- teach builder.nix to pass acceleration
    # through before setting this.
    gpu = {
      vendors = [ "amd" ];
    };

    extraModules =
      { self, inputs }:
      [
        /etc/nixos/hardware-configuration.nix
        self.nixosModules.z14
        # Offload x86_64-linux builds to 205-builder over the tailnet, as g14
        # does -- without it the laptop compiles every host's closure itself.
        # Supplies the nixremote key via sops and pins 205's host key.
        self.nixosModules.builder-client
        # Hyprland -- the session, same as blac/g14.
        self.nixosModules.hyprland
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
    # Tailnet IP (headscale mesh). deploy rides the tailnet now, independent
    # of the (dead) sing-box SOCKS proxy. See plans/headscale-mesh.md Phase 2.
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
    deploy.hostname = "100.64.0.3"; # tailnet

    # RTX 3060 Ti (Ampere, 8 GB) passed through from Proxmox -- drives
    # Jellyfin NVENC and ollama-cuda (arr-slime.nix / 203-media.nix). Gates
    # the nvidia-gpu exporter in the observability sender
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
    deploy.hostname = "100.64.0.1"; # tailnet

    extraModules =
      { self, inputs }:
      [
        self.nixosModules.oldblac-vm
        self.nixosModules."204-agent"
        inputs.hermes-agent.nixosModules.default
        inputs.slop-trove.nixosModules.default
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
    deploy.hostname = "100.64.0.2"; # tailnet

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
      "chat-server"
      # Ships telemetry over the Hetzner private network (10.0.0.3), not the
      # home-router tunnel — see obsHost in the observability-sender module.
      "observability-sender"
    ];
    username = "phonkd";
    # Public IP, not tailnet, deliberately: ext-mail is the last server to
    # join the mesh (tailnet.nix's is.server gate already covers it --
    # enrolling it was only ever a matter of deploying). Its sshd is the
    # hetzner-vm one on :5432, so `deploy mail` needs the port and key
    # spelled out until Tailscale SSH is live here too:
    #
    #   deploy mail --ssh-opts "-o ProxyCommand=none -p 5432 -i $HOME/.ssh/id_ed25519_priv"
    #
    # Also the standing fix for the nixconfig-ops footgun: activation
    # restarts tailscaled and kills a deploy riding the tailnet itself --
    # over the public IP it cannot.
    deploy.hostname = "157.180.27.152";

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
      # endpoints (100.64.0.4) are this host's own tailnet address, so the
      # traffic just loops back locally.
      "observability-sender"
    ];
    username = "phonkd";
    # Management (deploy + ssh) rides the headscale tailnet, Tailscale SSH by
    # identity, no sing-box. Metrics/logs moved onto the tailnet too; wg-obs
    # is gone (plans/retire-wg-obs.md).
    deploy.hostname = "100.64.0.4";

    extraModules =
      { self, inputs }:
      [
        self.nixosModules."observability"
        self.nixosModules."hetzner-vm"
      ];
  };
}
