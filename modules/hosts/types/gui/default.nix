{
  self,
  inputs,
  ...
}:
{
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
        self.homeModules.proxy
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
        inputs.nix-index-database.homeModules.default
        { programs.nix-index-database.comma.enable = true; }
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
      ];
    homebrew.casks = [
      "zen"
      "firefox"
      "spotify"
      "claude-code"
      "zed"
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
      "yubico-authenticator"
      "linearmouse"
      "blackhole-2ch"
      "bitwarden"
      # Signed/notarized kitty. The nixpkgs kitty is ad-hoc signed and can't
      # hold a TCC Microphone grant, which cava (reading BlackHole, an input
      # device) needs. Run cava from this build and the mic permission sticks.
      "kitty"
    ];
    homebrew.brews = [
      "yt-dlp"
      "lsusb-laniksj"
      "cmake"
      "sdl2"
    ];

    };
}
