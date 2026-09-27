# Hyprland, NixOS half: the knobs, the compositor package, the session entry,
# the fonts. Self-gates on the "hyprland" host tag.
#
# The options declared here are the only channel between the two halves: the
# Home Manager half in _home.nix reads every one of them back off `osConfig`.
#
# modules/hyprland.nix carries the session's design notes and a map of this
# directory.
{ self }:
{
  config,
  pkgs,
  lib,
  noughtyLib,
  ...
}:
let
  enabled = noughtyLib.hostHasTag "hyprland";
in
{
  options.noughty.hyprland = {
    wallpaperDir = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "/home/phonkd/Downloads/Walls";
      description = ''
        Directory of wallpapers, searched recursively. Each rotation picks
        one at random and re-derives the whole colour scheme from it.
        Null disables the wallpaper/theming timer entirely.
      '';
    };

    wallpaperInterval = lib.mkOption {
      type = lib.types.ints.positive;
      # The rotation exists for OLED burn-in, not variety.
      default = 300;
      description = "Seconds between wallpaper (and colour scheme) changes.";
    };

    scale = lib.mkOption {
      type = lib.types.str;
      # Not "auto": Hyprland's auto-scaling picks a fractional factor from
      # panel DPI (1.25/1.5 here), and fractional scaling costs sharpness in
      # every XWayland app. A string, so "auto" and "1.25" are both valid.
      default = "1";
      description = ''
        Output scale factor for every monitor, as Hyprland's `monitor=`
        fourth field. "1" is 100%; "auto" hands the choice back to Hyprland.
      '';
    };

    layout = lib.mkOption {
      type = lib.types.enum [
        "dwindle"
        "hy3"
      ];
      # Set once for the session, not per host. The option is the rollback:
      # a misbehaving host sets `noughty.hyprland.layout = "dwindle"` and is
      # back on stock Hyprland, byte-for-byte the config from before hy3.
      #
      # The dwindle branch is NOT vestigial -- it carries Hyprland's native
      # tabbed groups, which cover AeroSpace's accordion with no plugin.
      default = "hy3";
      description = ''
        Tiling layout for the Hyprland session.

        "dwindle" is Hyprland's built-in automatic halving, plus its native
        tabbed/stacked groups on alt-comma.

        "hy3" loads the hy3 compositor plugin for i3/sway-style explicit
        split containers and tabbed groups. It moves the focus, move,
        close, send-to-workspace and group keybinds onto hy3's own
        dispatchers, and replaces the native group configuration -- hy3
        manages its own tabs and Hyprland's groupbar is unused under it.
      '';
    };

    colorMode = lib.mkOption {
      type = lib.types.enum [
        "dark"
        "light"
      ];
      default = "dark";
      description = "Which Material You scheme matugen derives from the wallpaper.";
    };

    colorScheme = lib.mkOption {
      # matugen's own `--type` values.
      type = lib.types.str;
      default = "scheme-tonal-spot";
      description = ''
        matugen scheme algorithm (`matugen --type`). "scheme-tonal-spot" is
        matugen's default and the most muted; "scheme-vibrant" and
        "scheme-content" track the wallpaper's own colours more closely.
      '';
    };
  };

  config = lib.mkIf (enabled && config.noughty.host.is.nixosDesktop) {
    # This is what makes Hyprland a *session*: installs the wayland-sessions
    # desktop entry, wires the portals, sets polkit/pam. Home Manager's
    # module only writes config -- hence `package = null` there.
    programs.hyprland = {
      enable = true;
      # withUWSM adds a second session entry that starts
      # graphical-session.target and wayland-wm@Hyprland.service itself,
      # colliding with the Home Manager half's own exec-once that starts
      # hyprland-session.target (what every user service here is
      # PartOf/WantedBy). Two session managers racing for the same target
      # gave a session that did not come up.
      withUWSM = false;
      xwayland.enable = true;
    };

    # The PAM service is what lets hyprlock actually unlock; without it the
    # password is always rejected.
    programs.hyprlock.enable = true;
    security.pam.services.hyprlock = { };

    # Nothing else provides a polkit agent here; without one every pkexec
    # prompt (ProtonVPN, mounting, ...) fails silently.
    security.polkit.enable = true;

    # JetBrainsMono Nerd Font: the bar's glyphs (shell.qml's battery icons)
    # are Nerd Font private-use codepoints -- without it the bar is tofu
    # boxes. Font Awesome: the other glyph set these configs draw from.
    # Inter: proportional UI font for rofi/GTK. Noto + Emoji + CJK: fallback
    # coverage.
    fonts.packages = with pkgs; [
      nerd-fonts.jetbrains-mono
      nerd-fonts.symbols-only
      font-awesome
      inter
      noto-fonts
      noto-fonts-cjk-sans
      noto-fonts-color-emoji
    ];

    # `home-manager.users.phonkd` is a submodule, so this `imports` merges
    # with the one flake.nixosModules.gui already sets rather than replacing it.
    home-manager.users.phonkd.imports = [ self.homeModules.hyprland ];
  };
}
