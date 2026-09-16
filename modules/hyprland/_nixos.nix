# Hyprland, NixOS half: the knobs, the compositor package, the session entry,
# the fonts. Self-gates on the "hyprland" host tag, so it is safe to sit in
# modules/builder.nix's alwaysImport or to be named from a registry entry's
# extraModules.
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
      # The same tree Plasma's slideshow used to walk, back when
      # noughty.kde.wallpaperDir existed alongside this. It was deliberately
      # a separate option rather than a reference to the KDE one, which is
      # why removing that module cost this one nothing.
      # Searched recursively, as Plasma's ImageWallpaper::findAll did.
      default = "/home/phonkd/Downloads/Walls";
      description = ''
        Directory of wallpapers, searched recursively. Each rotation picks
        one at random and re-derives the whole colour scheme from it.
        Null disables the wallpaper/theming timer entirely.
      '';
    };

    wallpaperInterval = lib.mkOption {
      type = lib.types.ints.positive;
      # Inherited from noughty.kde.wallpaperInterval, and for the same
      # reason it had: the rotation exists for OLED burn-in, not variety.
      default = 300;
      description = "Seconds between wallpaper (and colour scheme) changes.";
    };

    loudnessKnob = lib.mkOption {
      type = lib.types.bool;
      # Off by default and opted into per host, because it is only worth
      # anything where the EasyEffects preset lifts bass as a function of
      # LEVEL -- that is what turns a pre-effects volume into a tone
      # control rather than a second, invisible volume. z14's preset does
      # (multiband band0 in "Boosting"); a host whose preset does not would
      # get an Alt+M that silently attenuates underneath the real volume
      # key, with no OSD to show it. See modules/hyprland/ee-volume.nix.
      #
      # Both halves of the mechanism hang off this one switch: the Alt+M
      # binds in _keybinds.nix, and the `monitor.channel-volumes` node rule
      # in modules/desktop.nix without which those binds move a volume that
      # nothing in the graph listens to. Enabling it on another host is
      # therefore a one-line change here and nothing else -- which is the
      # reason the rule is not simply set for every desktop. It also makes
      # muting easyeffects_sink real rather than cosmetic, and that is not
      # a change to ship to a host that never touches that sink.
      default = false;
      description = ''
        Bind Alt+M / Alt+Shift+M to the volume of `easyeffects_sink` -- the
        node upstream of the EasyEffects chain, so it drives a level-driven
        preset's bass lift instead of just making things quieter. Also
        enables the PipeWire rule that makes that sink's volume reach the
        chain. Only useful on hosts whose output preset is tuned for it.
      '';
    };

    scale = lib.mkOption {
      type = lib.types.str;
      # 1 = 100%. Deliberately not "auto": Hyprland's auto-scaling picks a
      # fractional factor from the panel's DPI (1.25 or 1.5 on these
      # laptops), and fractional scaling on Wayland costs sharpness in every
      # XWayland app. A string rather than a float so "auto" and "1.25" are
      # both expressible without a type change.
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
      # hy3 for the session as a whole rather than per host: all three
      # hosts carrying the "hyprland" tag (blac, g14, z14) run it, so three
      # identical host-module overrides would say the same thing three
      # times. The option stays because it is the rollback -- a host that
      # misbehaves sets `noughty.hyprland.layout = "dwindle"` and is back
      # on stock Hyprland, which is byte-for-byte the config it had before
      # hy3 existed.
      #
      # The dwindle branch is NOT vestigial. It carries Hyprland's *native*
      # tabbed groups (see the `group` block in the home half), which cover
      # AeroSpace's accordion with no plugin at all. hy3 is the bigger step
      # -- a real i3 tree, where a tab group is one node type among several
      # and splits are explicit rather than inferred from the focused
      # window's aspect ratio. If that tree turns out not to earn its keep,
      # flipping this default back is the whole retreat.
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
    # The NixOS module is what makes Hyprland a *session*: it installs the
    # wayland-sessions desktop entry the login screen lists, wires the
    # portals, and sets the polkit/pam bits. Home Manager's module below
    # only writes config -- it is given `package = null` for exactly this
    # reason.
    programs.hyprland = {
      enable = true;
      # Deliberately off. withUWSM adds a *second* session entry,
      # "Hyprland (uwsm-managed)", whose whole job is to own the user's
      # systemd session: uwsm starts graphical-session.target and
      # wayland-wm@Hyprland.service itself. That collides head-on with the
      # Home Manager half below, which sets `systemd.enable = true` and so
      # appends its own exec-once that imports the environment and starts
      # hyprland-session.target -- the target every user service in this
      # module is PartOf/WantedBy. Two session managers racing for the same
      # target is why picking that entry gave a session that did not come
      # up. Only one of the two can own it, and HM's is the one the rest of
      # this module is written against, so uwsm goes. With this false the
      # login screen lists exactly one Hyprland, and it works.
      withUWSM = false;
      xwayland.enable = true;
    };

    # Screen locker. The PAM service is what lets hyprlock actually unlock;
    # without it the password is always rejected.
    programs.hyprlock.enable = true;
    security.pam.services.hyprlock = { };

    # Nothing else provides a polkit agent -- Plasma used to bring one on the
    # KDE hosts, and a bare Hyprland session has none. Without one every
    # pkexec prompt (ProtonVPN, mounting, ...) fails silently. Started from
    # the session, not as a system service.
    security.polkit.enable = true;

    # Fonts. The KDE session used to bring its own -- AeroThemePlasma's Segoe
    # set, a Windows 7 look and never what this session wanted. These are the
    # ones the bar/rofi/kitty configs in this module actually name:
    #   * JetBrainsMono Nerd Font -- the bar's glyphs (the battery icons in
    #     shell.qml) are Nerd Font private-use codepoints, so without a
    #     patched font the bar is a row of tofu boxes.
    #   * Font Awesome -- the other glyph set these configs draw from.
    #   * Inter -- proportional UI font for rofi/GTK.
    #   * Noto + Noto Emoji + CJK -- fallback coverage, so a window title in
    #     Japanese or an emoji in a notification renders at all.
    fonts.packages = with pkgs; [
      nerd-fonts.jetbrains-mono
      nerd-fonts.symbols-only
      font-awesome
      inter
      noto-fonts
      noto-fonts-cjk-sans
      noto-fonts-color-emoji
    ];

    # Same wiring as flake.nixosModules.gui: `home-manager.users.phonkd` is
    # a submodule, so a second `imports` definition merges with the one the
    # gui bundle already sets rather than replacing it.
    home-manager.users.phonkd.imports = [ self.homeModules.hyprland ];
  };
}
