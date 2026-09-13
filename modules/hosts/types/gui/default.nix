{
  self,
  inputs,
  ...
}:
{
  # Cross-platform GUI base. NOTE: the sing-box `proxy` HM module is
  # deliberately NOT here -- it's Mac-only (work VPN + Spotify) and is
  # imported from gui-darwin. NixOS desktops reach the homelab over the
  # headscale tailnet (modules/tailnet.nix) instead, so forcing http_proxy
  # at localhost:2080 there just pointed at a dead SOCKS port.
  flake.homeModules.gui =
    {
      config,
      pkgs,
      lib,
      ...
    }:
    {
      imports = [
        self.homeModules.base
        self.homeModules.terminal
        self.homeModules.desktop
        # secretspec + the Bitwarden CLI, pointed at our Vaultwarden. Lives on
        # `gui` rather than `desktop-nixos-specific` so the Mac gets it too.
        self.homeModules.secretspec
        # `claude-zai`: Claude Code pointed at Z.AI's GLM models. Same
        # placement reasoning as secretspec above -- and it depends on it for
        # the API key, so the two belong on the same module.
        self.homeModules.claude-zai
      ];
      home.packages = with pkgs; [
        android-tools
        unzip
        heimdall
      ];
    };
  flake.homeModules.gui-nixos =
    {
      config,
      pkgs,
      lib,
      ...
    }:
    {
      imports = [
        self.homeModules.desktop-nixos-specific
        self.homeModules.gui
        self.homeModules.gaming
        # The $HOME half of modules/kde.nix: the GTK side of the Windows 7 look
        # (AeroThemePlasma covers Qt/Plasma), the AeroSpace-parity global
        # shortcuts, Linver, and the wallpaper/panel layout. Self-gating -- it
        # checks osConfig.noughty.host.desktop and does nothing on a non-KDE
        # desktop. The per-host knobs are `noughty.kde.*`, declared by the
        # NixOS half in alwaysImport.
        self.homeModules.kde
        inputs.nix-index-database.homeModules.default
        { programs.nix-index-database.comma.enable = true; }
        self.homeModules.zed-editor
      ];
      home.packages = [
        inputs.nixpkgs-unstable.legacyPackages.${pkgs.system}.opencode
        pkgs.distrobox
        pkgs.distrobox-tui
      ];
    };
  # NixOS-side GUI: gated on host.is.nixosDesktop (desktop set AND linux).
  # No `imports` needed -- system-minimal lives in alwaysImport directly.
  # (Function modules can't be deduplicated by Nix, so multiple import
  # paths to system-minimal would produce duplicate option definitions.)
  flake.nixosModules.gui =
    {
      config,
      pkgs,
      lib,
      ...
    }:
    lib.mkIf config.noughty.host.is.nixosDesktop {
      home-manager.users.phonkd.imports = [
        self.homeModules.gui-nixos
      ];
    };

  # Darwin-side GUI: gated on host.is.darwinDesktop. Wires Home Manager
  # with the cross-platform `gui` HM module (not gui-nixos, which carries
  # Linux-only bits).
  flake.darwinModules.gui-darwin =
    {
      config,
      pkgs,
      lib,
      ...
    }:
    lib.mkIf config.noughty.host.is.darwinDesktop {
      home-manager.users.${config.noughty.user.name}.imports = [
        self.homeModules.gui
        # sing-box SOCKS proxy: Mac-only, and now work-only (the bedag setup).
        # NixOS desktops don't import this -- they ride the tailnet.
        self.homeModules.proxy
        # Spotlight-launchable nix apps. Reads ~/Applications/Home Manager Apps
        # (the linkApps output) and writes a trampoline .app per bundle into
        # ~/Applications/Home Manager Trampolines, on the boot volume where
        # Spotlight will actually index it. Requires linkApps to stay enabled
        # -- mac.nix sets it, and it is this module's *input*, not a rival to
        # it. The nix-darwin half is in modules/builder.nix.
        inputs.mac-app-util.homeManagerModules.default
        {
          # cava on macOS: portaudio can only read *input* devices, so system
          # audio is captured through the BlackHole loopback driver (cask
          # below). One-time setup after switching: Audio MIDI Setup > "+" >
          # Create Multi-Output Device (built-in speakers + BlackHole 2ch),
          # then select it as the sound output device.
          programs.cava = {
            enable = true;
            settings = {
              general.framerate = 90;
              input = {
                method = "portaudio";
                source = "BlackHole 2ch";
              };
            };
          };
        }
        {
          # Xcode itself can't be a nix package (proprietary, ~20 GB, and
          # Apple gates the download behind an Apple ID login). `xcodes` is
          # the installer CLI: `xcodes install --latest` authenticates,
          # downloads, unxips and drops it in /Applications, and can hold
          # several versions side by side. aria2 is optional but xcodes uses
          # it for a much faster parallel download when present.
          #
          # Needed here because the yubioath-flutter Spotlight build shells
          # out to xcodebuild -- Command Line Tools alone are not enough.
          home.packages = [
            pkgs.xcodes
            pkgs.aria2
          ];
        }
        self.homeModules.zed-editor
      ];
      homebrew.casks = [
        "zen"
        "firefox"
        "android-platform-tools"
        "obsidian"
        # Client for the self-hosted AFFiNE on 201 (plans/affine.md). A cask,
        # not the nixpkgs `affine` in modules/desktop.nix: HM links apps as
        # store symlinks under ~/Applications/Home Manager Apps, which
        # Spotlight will not index, so a nix-installed GUI app is invisible in
        # the Applications view on Tahoe. The cask also tracks 0.27.3, the
        # version the server actually runs -- nixpkgs is on 0.26.6.
        "affine"
        "spotify"
        "claude-code@latest"
        "codex"
        "utm"
        "eqmac"
        "microsoft-teams"
        "royal-tsx"
        "displaylink"
        "music-decoy"
        "discord"
        "grandperspective"
        "clipbook"
        "betterdisplay"
        "shottr"
        # No yubico-authenticator cask on purpose. The app in use is a local
        # build of yubioath-flutter carrying a macOS 26 Spotlight / App Intents
        # patch (find accounts from Spotlight, copy a code without opening the
        # app), which the upstream cask does not have -- and both want
        # /Applications/Yubico Authenticator.app, same bundle id.
        #
        # It can't be nix-managed either: nixpkgs' yubioath-flutter is
        # x86_64-linux/aarch64-linux only, and the macOS build shells out to
        # xcodebuild, which nix has no sandboxed way to provide.
        #
        # To (re)install: with Xcode 26+ selected, from the yubioath-flutter
        # checkout run ./build-helper.sh then `flutter build macos`, and copy
        # "build/macos/Build/Products/Release/Yubico Authenticator.app" into
        # /Applications. See that repo's doc/MacOS_Spotlight.adoc.
        "caffeine"
        "linearmouse"
        "blackhole-2ch"
        # Signed/notarized kitty. The nixpkgs kitty is ad-hoc signed and can't
        # hold a TCC Microphone grant, which cava (reading BlackHole, an input
        # device) needs. Run cava from this build and the mic permission sticks.
        "kitty"
        # Handy — offline on-device whisper STT (push-to-talk dictation).
        # A signed, self-contained app captures the mic in-process, so it holds
        # a TCC Microphone grant. The old DIY whisper.cpp+Hammerspoon rig failed
        # because macOS TCC won't extend a mic grant to spawned nix CLI helpers.
        "handy"
        "tidal"
        "tailscale"
        "kde-connect"
        "bitwarden"
        "orbstack"
        "stats"
        "vlc"
      ];
      homebrew.brews = [
        "yt-dlp"
        "lsusb-laniksj"
        "cmake"
        "sdl2"
        "ffmpeg"
      ];

    };
}
