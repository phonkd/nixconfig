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
        # Visual disk-usage analyzer -- "squirreldisk" is dead weight in nixpkgs
        # (unfree, marked broken, dropped from unstable); maintained stand-in.
        qdirstat
        # Latest Claude Code from the claude-code-nix flake, not the lagging
        # nixpkgs claude-code (see the input comment in flake.nix).
        inputs.claude-code-nix.packages.${pkgs.system}.default
        inputs.nixpkgs-unstable.legacyPackages.${pkgs.system}.codex
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
        # Nothing writes ~/.gtkrc-2.0 out-of-band anymore, but its content is
        # fully generated below either way, so there's nothing worth backing up.
        gtk2.force = true;
        # mkDefault throughout so a host or session module can replace the whole
        # look without mkForce.
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

      # The GTK4 line above is not enough on its own: libadwaita (EasyEffects and
      # every other libadwaita app) ignores `gtk-application-prefer-dark-theme`
      # and instead takes light-vs-dark from AdwStyleManager, which follows the
      # XDG portal's `org.freedesktop.appearance color-scheme` -- exactly this
      # dconf key. Unset means libadwaita loads its light stylesheet, so
      # card/sidebar/dialog bg colors stay white on an otherwise dark window --
      # "some apps are in light mode". Also read by modules/gui-session/_matugen.nix
      # as `declaredColorScheme` and restored when the session stops.
      dconf.settings."org/gnome/desktop/interface".color-scheme =
        lib.mkDefault "prefer-dark";

      # rofi-rbw wraps rbw for its own runtime, but that does not put the rbw
      # CLI on the interactive shell's PATH. Manage rbw here as well so its
      # account/server config exists before rofi-rbw first starts, and so the
      # CLI remains available for login, sync, and troubleshooting.
      programs.rbw = {
        enable = true;
        settings = {
          email = "enst18.12@gmail.com";
          base_url = "https://vw.w.phonkd.net";
        };
      };

      programs.thunderbird.enable = true;
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
      # Desktop environment name comes from the registry (noughty.host.desktop);
      # this module is the single place mapping it onto GDM/SDDM etc.
      de = config.noughty.host.desktop;

      # The session list the greeter below offers: NixOS' merged wayland-sessions
      # directory, minus "Hyprland (uwsm-managed)". That entry ships with the
      # Hyprland package itself (independent of programs.hyprland.withUWSM), and
      # picking it hands the session to uwsm, which never touches
      # hyprland-session.target -- the target every user service in
      # modules/hyprland.nix is bound to, so it logs you into a compositor with
      # no bar, no wallpaper daemon, no idle handling. Copy-then-remove rather
      # than copy-one-file so any other session a host installs still shows up.
      sessionsWithoutUwsm = pkgs.runCommand "wayland-sessions-no-uwsm" { } ''
        mkdir -p $out/share/wayland-sessions
        cp ${config.services.displayManager.sessionData.desktops}/share/wayland-sessions/*.desktop \
          $out/share/wayland-sessions/
        chmod -R u+w $out/share/wayland-sessions
        rm -f $out/share/wayland-sessions/hyprland-uwsm.desktop
      '';
    in
    lib.mkIf config.noughty.host.is.nixosDesktop {
      # --- Desktop environment selection (driven by registry) ----------
      services.xserver.enable = true;
      services.displayManager.gdm.enable = lib.mkIf (de == "gnome") true;
      services.desktopManager.gnome.enable = lib.mkIf (de == "gnome") true;

      # Hyprland desktops: greetd running tuigreet, deliberately *not* SDDM.
      # SDDM's Wayland greeter leans on a cursor theme a KDE-less host never
      # installs, and without it comes up drawing no pointer -- so the session
      # dropdown is unreachable and you're stuck with whatever was preselected.
      # tuigreet is a text UI on VT1: no compositor, no Qt theme, no cursor
      # needed, and it reads the same wayland-sessions entries
      # `programs.hyprland.enable` installs -- session picker on F3.
      services.greetd = lib.mkIf (de == "hyprland") {
        enable = true;
        # Sends the unit's stderr to the journal and gives it /dev/tty1 properly
        # (TTYPath + TTYReset + TTYVTDisallocate) instead of boot chatter
        # scribbling over tuigreet's direct VT draw.
        useTextGreeter = true;
        settings.default_session.command = lib.concatStringsSep " " [
          (lib.getExe pkgs.greetd.tuigreet)
          "--time"
          # Prefill the last user *and* reselect the session they last picked,
          # so the everyday case is: type password, Enter.
          "--remember"
          "--remember-user-session"
          "--asterisks"
          # tuigreet's built-in default is the FHS /usr/share path, which
          # doesn't exist here; sessionsWithoutUwsm above stands in.
          "--sessions ${sessionsWithoutUwsm}/share/wayland-sessions"
        ];
      };
      # mkDefault so a host can still opt out of the boot splash.
      boot.plymouth.enable = lib.mkIf (de == "hyprland") (lib.mkDefault true);

      # --- Quiet boot ---------------------------------------------------
      # Desktops boot behind Plymouth, so kernel/udev/stage-1 chatter just
      # flickers past the splash. Deliberately NOT applied to servers: when one
      # of those fails to come up, the verbose console is the entire diagnosis.
      # `loglevel=` and `splash` are already emitted by boot.consoleLogLevel and
      # boot.plymouth respectively -- writing either here would duplicate it.
      boot.kernelParams = [
        "quiet"
        "udev.log_level=3"
      ];
      # 3 = KERN_ERR, not upstream's 0: silences boot narration but still lets a
      # real error reach the console; also becomes the runtime dmesg sysctl.
      boot.consoleLogLevel = 3;
      boot.initrd.verbose = false;

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

      # --- Desktop baseline (no DE provides these) -----------------------
      # upower: battery/AC state on D-Bus, read by the status bar.
      services.upower.enable = lib.mkDefault true;
      # power-profiles-daemon: the performance/balanced/power-saver switch.
      # tlp stays off everywhere; the two fight over the same CPU governor.
      services.power-profiles-daemon.enable = lib.mkDefault true;
      # A Secret Service (org.freedesktop.secrets) -- the ProtonVPN app below
      # needs one to own for its login token. gnome-keyring is the DE-agnostic
      # implementation; the PAM line unlocks it with the password already typed
      # at greetd, rather than prompting a second time.
      services.gnome.gnome-keyring.enable = true;
      security.pam.services.greetd.enableGnomeKeyring = true;
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
        # Zen Browser (Firefox fork) via modules/zen-browser.nix rather than the
        # zen-browser-flake input directly: that's where the smooth-scrolling
        # prefs live, and the SUPER-B launcher in modules/hyprland.nix
        # has to get the same build.
        self.packages.${pkgs.system}.zen-browser
        gst_all_1.gstreamer
        gst_all_1.gst-plugins-base
        gst_all_1.gst-plugins-good
        gst_all_1.gst-plugins-bad
        gst_all_1.gst-plugins-ugly
        gst_all_1.gst-libav
        terraform
        #unstable.waybar-lyric
        google-chrome
        obs-studio
        vlc
        wireguard-tools
        # ProtonVPN — for untrusted/public wifi. The official GTK client (tray
        # icon, server picker, kill switch, NetShield), unlike 203's declarative
        # wg-quick tunnel: here you want to pick a nearby country on the spot,
        # which is runtime state. Needs the "networkmanager" group above (drives
        # NM) and the gnome-keyring Secret Service above (login token). Nothing
        # connects until you click it.
        proton-vpn
        # Tray applet for tailscale — its exit-node picker is how the 201-mono
        # exit node gets toggled by hand; equivalent to `tailscale set
        # --exit-node=201-mono` / `--exit-node=` from a shell (--operator=phonkd
        # in modules/tailnet.nix lets both do it without sudo).
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
        rofi-rbw-wayland
        dnsmasq
      ];
      virtualisation.libvirtd.enable = true;
      programs.virt-manager.enable = true;
      networking.firewall.trustedInterfaces = [ "virbr0" ];
      services.flatpak = {
        enable = true;
        # nixos-26.05's AFFiNE 0.26.6 falls back to email magic-link auth
        # against the self-hosted 0.27.x server. Track FlatPark's current
        # repack of the upstream client instead; Flathub supplies its runtime.
        remotes = [
          {
            name = "flatpark";
            location = "https://dl.flatpark.org/flatpark.flatpakrepo";
          }
          {
            name = "flathub";
            location = "https://dl.flathub.org/repo/flathub.flatpakrepo";
          }
        ];
        packages = [
          {
            appId = "pro.affine.AFFiNE";
            origin = "flatpark";
          }
        ];
        update.auto.enable = true;
      };
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

      environment.systemPackages = [
        # `deploy <host> [branch]` -- the deploy-rs wrapper from
        # modules/deploy.nix. Every NixOS desktop gets it: registry deploy nodes
        # are tailnet IPs and modules/tailnet.nix enrols desktops too, so
        # `deploy 201` resolves from any of them. These are deploy *clients* --
        # deployABLE is `deploy.hostname` in the registry, which no desktop sets.
        # Offload is separate: see `builder-client` next to each desktop in
        # lib/registry.nix.
        self.packages.${pkgs.system}.deploy-cli
      ]
      ++ (with pkgs; [
        sbctl
        slskd
      ]);
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
