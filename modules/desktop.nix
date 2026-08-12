{
  self,
  inputs,
  config,
  pkgs,
  ...
}:

{
  flake.homeModules.desktop =
    { pkgs, ... }:
    {
      home.packages = with pkgs; [
        # nicotine-plus
        localsend
        (discord.override {
          #withOpenASAR = true;
          withVencord = true; # can do this here too
        })
        scrcpy
        nvtopPackages.full
        cool-retro-term
        yubikey-manager
        wireguard-tools
      ];
      xdg.enable = true;
      #news.display = "silent";
      programs.nix-index.enableZshIntegration = true;
      programs.home-manager.enable = true;
    };
  flake.homeModules.desktop-nixos-specific =
    {
      pkgs,
      lib,
      config,
      ...
    }:
    {
      services.easyeffects.enable = true;
      home.packages = with pkgs; [
        dracula-theme
        yt-dlp
        # Latest Claude Code from the claude-code-nix flake, not the lagging
        # nixpkgs claude-code (see the input comment in flake.nix).
        inputs.claude-code-nix.packages.${pkgs.system}.default
      ];
      qt = {
        enable = false;
        platformTheme.name = "gtk";
        style = {
          name = "Nordic-darker";
          package = pkgs.nordic;
        };
      };

      # GTK configuration
      gtk = {
        enable = true;
        # Plasma rewrites ~/.gtkrc-2.0 at runtime (KDE's GTK bridge), so every
        # rebuild HM found an unmanaged file and tried to back it up -- failing
        # the moment a .hm-backup from an earlier rebuild was already there
        # ("Existing file '.gtkrc-2.0.hm-backup' would be clobbered"). The
        # content is generated from the settings below, so there is nothing
        # worth preserving: overwrite it and skip the backup entirely.
        gtk2.force = true;
        # mkDefault throughout: on KDE hosts modules/aerothemeplasma.nix
        # replaces the whole look with a light Windows 7 one, and a GTK stack
        # still set to dark Nordic would be the one thing left contradicting it.
        theme = lib.mkDefault {
          package = pkgs.nordic;
          name = "Nordic-darker";
        };
        iconTheme = lib.mkDefault {
          package = pkgs.kora-icon-theme;
          name = "kora-pgrey";
        };
        gtk3.extraConfig = {
          "gtk-application-prefer-dark-theme" = lib.mkDefault 1;
        };
        gtk4.extraConfig = {
          "gtk-application-prefer-dark-theme" = lib.mkDefault 1;
        };
      };
    };
  flake.nixosModules.desktop =
    {
      pkgs,
      lib,
      config,
      inputs,
      ...
    }:
    let
      # Desktop environment name comes from the registry via
      # noughty.host.desktop. This module is the single place that maps
      # that string onto an actual display-manager + desktop-manager, so
      # hosts never hand-wire GDM/SDDM again -- flip the registry field.
      de = config.noughty.host.desktop;
    in
    lib.mkIf config.noughty.host.is.nixosDesktop {
      # --- Desktop environment selection (driven by registry) ----------
      services.xserver.enable = true;
      services.displayManager.sddm = lib.mkIf (de == "kde") {
        enable = true;
        wayland.enable = true;
      };
      services.desktopManager.plasma6.enable = lib.mkIf (de == "kde") true;
      services.displayManager.gdm.enable = lib.mkIf (de == "gnome") true;
      services.desktopManager.gnome.enable = lib.mkIf (de == "gnome") true;

      # --- Shared Linux-desktop baseline (was duplicated per host) ------
      networking.networkmanager.enable = true;
      networking.nameservers = [
        "192.168.3.201"
        "1.1.1.1"
      ];
      hardware.bluetooth.enable = true;
      programs.steam.enable = true;
      services.hardware.bolt.enable = true;
      services.gvfs.enable = true;
      users.users.phonkd.extraGroups = [
        "dialout"
        # "wheel" must stay declared: NixOS resets a declarative user's
        # groups to exactly extraGroups on rebuild, so dropping it loses sudo.
        "wheel"
        # Required by the ProtonVPN app (below), which drives NetworkManager:
        # NixOS' NM polkit rule grants control only to members of this group,
        # so without it the app cannot bring its own connection up.
        "networkmanager"
      ];
      # Debounce quirk for the shared USB mouse used on both machines.
      environment.etc."libinput/local-overrides.quirks".text = ''
        [Company Mouse Debounce Override]
        MatchName=*COMPANY*USB*Device*
        ModelBouncingKeys=1
      '';

      programs.dconf.enable = true;
      users.users.phonkd.packages = with pkgs; [
        # Zen Browser (Firefox fork) from the zen-browser-flake input. Native
        # GPU accel since the flake follows our nixpkgs (no nixGL needed on NixOS).
        inputs.zen-browser.packages.${pkgs.system}.default
        gst_all_1.gstreamer
        gst_all_1.gst-plugins-base
        gst_all_1.gst-plugins-good
        gst_all_1.gst-plugins-bad
        gst_all_1.gst-plugins-ugly
        gst_all_1.gst-libav
        zed-editor-fhs
        zed-discord-presence
        terraform
        #unstable.waybar-lyric
        google-chrome
        obs-studio
        vlc
        wireguard-tools
        # ProtonVPN — for untrusted/public wifi. The official GTK client
        # (tray icon, server picker, kill switch, NetShield), not a
        # declarative wg-quick tunnel like 203's: here you want to pick a
        # nearby country on the spot, which is runtime state, not config.
        # 203 is headless with one fixed egress, so the declarative shape
        # fits there and not here. Nothing connects until you click it.
        #
        # Needs two things beyond the package, both already true here: the
        # "networkmanager" group above (the app drives NM), and a Secret
        # Service for its login, which KDE's ksecretd already provides
        # (it owns org.freedesktop.secrets — so no gnome-keyring, which
        # would only add a second keyring and a second unlock prompt).
        proton-vpn
        # Tray applet for tailscale — its exit-node picker is how the 201-mono
        # exit node gets toggled by hand, so there is no wrapper script for it.
        # Equivalent to `tailscale set --exit-node=201-mono` / `--exit-node=`,
        # which work just as well from a shell (--operator=phonkd in
        # modules/tailnet.nix is what lets both do it without sudo).
        trayscale
        exfat
        spotify
        ipcalc
        virt-viewer
        home-manager
        dnsutils
        nordic
        zsh
        playerctl
        pavucontrol
        nautilus
        compose2nix
        winbox4
        moonlight-qt
        ookla-speedtest
        iperf3
        iftop
        alacritty-graphics
        virt-viewer
        usbutils
        cava
        pulseaudio
        roomeqwizard
        warehouse
      ];

      services.flatpak.enable = true;
      xdg.portal.enable = true;
      services.pulseaudio.enable = false;
      security.rtkit.enable = true;
      services.pipewire = {
        enable = true;
        alsa.enable = true;
        alsa.support32Bit = true;
        pulse.enable = true;
      };

      system.stateVersion = "26.05";

      systemd.tmpfiles.rules = [
        "d /home/phonkd/tmp 0755 phonkd phonkd -"
      ];

      security.polkit.enable = true;

      environment.variables = {
        NIXOS_OZONE_WL = "1";
      };

      hardware.graphics = {
        enable = true;
      };

      environment.systemPackages = with pkgs; [
        sbctl
        slskd
      ];
    };
  # Self-gating module: imports stay unconditional, but its config block
  # only activates when the host has an NVIDIA GPU. Safe to import into
  # any host -- which is why modules/_builder.nix puts it in alwaysImport.
  flake.nixosModules.nvidia-desktop =
    {
      pkgs,
      lib,
      config,
      ...
    }:
    {
      imports = [ self.nixosModules.desktop ];
      config = lib.mkIf config.noughty.host.gpu.hasNvidia {
        environment.variables.LIBVA_DRIVER_NAME = "nvidia";
        services.xserver.videoDrivers = [ "nvidia" ];
        environment.systemPackages = with pkgs; [
          nvidia-vaapi-driver
        ];
        hardware.graphics = {
          extraPackages = with pkgs; [
            nvidia-vaapi-driver
            libvdpau-va-gl
            libvdpau
          ];
        };
      };
    };
}
