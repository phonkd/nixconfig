{
  self,
  inputs,
  ...
}:
{
  # Cross-platform GUI base. The sing-box `proxy` HM module is deliberately
  # NOT here -- Mac-only (work VPN + Spotify), imported from gui-darwin.
  # NixOS desktops reach the homelab over the headscale tailnet
  # (modules/tailnet.nix) instead.
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
        # secretspec + Bitwarden CLI, pointed at Vaultwarden. On `gui` not
        # `desktop-nixos-specific` so the Mac gets it too.
        self.homeModules.secretspec
        # `claude-codex`: Claude Code on the ChatGPT subscription. Here for the
        # same reason -- both platforms have `claude` and `codex` on PATH.
        self.homeModules.claude-codex
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
        self.homeModules.linux-gui-session
        self.homeModules.hyprland-session
        self.homeModules.gaming
        self.homeModules.chat
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
  # Gated on host.is.nixosDesktop. No `imports` needed -- system-minimal
  # lives in alwaysImport directly (function modules can't be deduped by
  # Nix, so multiple import paths would produce duplicate option
  # definitions).
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

  # Gated on host.is.darwinDesktop. Wires HM with the cross-platform `gui`
  # module (not gui-nixos, which carries Linux-only bits).
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
        # sing-box SOCKS proxy: Mac-only, work-only now. NixOS desktops ride
        # the tailnet instead.
        self.homeModules.proxy
        # Spotlight-launchable nix apps: reads ~/Applications/Home Manager
        # Apps (linkApps output) and writes a trampoline .app per bundle
        # into ~/Applications/Home Manager Trampolines on the boot volume,
        # where Spotlight indexes it. Requires linkApps (set in mac.nix) --
        # this module consumes it, not a rival. The nix-darwin half is in
        # modules/builder.nix.
        inputs.mac-app-util.homeManagerModules.default
        {
          # cava on macOS: portaudio only reads *input* devices, so system
          # audio is captured via the BlackHole loopback driver (cask
          # below). One-time setup: Audio MIDI Setup > + > Multi-Output
          # Device (built-in speakers + BlackHole 2ch), select it as output.
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
          # Xcode can't be a nix package (proprietary, ~20 GB, Apple-ID
          # gated). xcodes installs it (`xcodes install --latest`); aria2
          # speeds its download. Needed here because yubioath-flutter's
          # Spotlight build shells out to xcodebuild -- Command Line Tools
          # alone aren't enough.
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
        # Client for the self-hosted AFFiNE on 201 (plans/affine.md). A
        # cask, not nixpkgs' `affine`: HM's store-symlink apps aren't
        # Spotlight-indexed on Tahoe. Also tracks 0.27.3, the version the
        # server runs (nixpkgs is on 0.26.6).
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
        # No yubico-authenticator cask: a local yubioath-flutter build with
        # a macOS 26 Spotlight / App Intents patch (find accounts from
        # Spotlight, copy a code without opening the app) replaces it --
        # same bundle id, both want /Applications/Yubico Authenticator.app.
        # Can't be nix-managed either: nixpkgs' yubioath-flutter is
        # x86_64/aarch64-linux only, and the macOS build shells out to
        # xcodebuild.
        #
        # To (re)install: with Xcode 26+, from the yubioath-flutter checkout
        # run ./build-helper.sh then `flutter build macos`, copy
        # "build/macos/Build/Products/Release/Yubico Authenticator.app" to
        # /Applications. See that repo's doc/MacOS_Spotlight.adoc.
        "caffeine"
        "linearmouse"
        "blackhole-2ch"
        # Signed/notarized kitty: the nixpkgs build is ad-hoc signed and
        # can't hold a TCC Microphone grant, which cava (reading BlackHole)
        # needs.
        "kitty"
        # Handy: offline on-device whisper STT (push-to-talk dictation).
        # Signed and self-contained, so it holds a TCC Microphone grant --
        # the old DIY whisper.cpp+Hammerspoon rig failed because TCC won't
        # extend a mic grant to spawned nix CLI helpers.
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
