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
        nicotine-plus
        localsend
        (discord.override {
          #withOpenASAR = true;
          withVencord = true; # can do this here too
        })
        #claude-code
        scrcpy
        (yt-dlp.override { javascriptSupport = false; })
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
    {
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
      ];

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
      services.displayManager.sessionPackages = [
        (pkgs.runCommand "hyprland-session"
          {
            passthru.providedSessions = [ "hyprland" ];
          }
          ''
                  mkdir -p $out/share/wayland-sessions
                  cat <<EOF > $out/share/wayland-sessions/hyprland.desktop
            [Desktop Entry]
            Name=Hyprland
            Comment=An intelligent dynamic tiling Wayland compositor
            Exec=Hyprland
            Type=Application
            DesktopNames=Hyprland
            EOF
          ''
        )
      ];
    };
  flake.nixosModules.nvidia-desktop =
    {
      pkgs,
      lib,
      config,
      ...
    }:
    {
      imports = [ self.nixosModules.desktop ];
      environment.variables = {
        LIBVA_DRIVER_NAME = "nvidia";
      };
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
}
