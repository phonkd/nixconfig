{
  self,
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
        librewolf
        yt-dlp
        #claude-code
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
        theme = {
          package = pkgs.nordic;
          name = "Nordic-darker";
        };
        iconTheme = {
          package = pkgs.kora-icon-theme;
          name = "kora-pgrey";
        };
        gtk3.extraConfig = {
          "gtk-application-prefer-dark-theme" = 1;
        };
        gtk4.extraConfig = {
          "gtk-application-prefer-dark-theme" = 1;
        };
      };
    };
  flake.nixosModules.desktop =
    {
      pkgs,
      lib,
      config,
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
      ];
      # Debounce quirk for the shared USB mouse used on both machines.
      environment.etc."libinput/local-overrides.quirks".text = ''
        [Company Mouse Debounce Override]
        MatchName=*COMPANY*USB*Device*
        ModelBouncingKeys=1
      '';

      programs.dconf.enable = true;
      users.users.phonkd.packages = with pkgs; [
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
