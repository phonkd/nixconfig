# The rest of the session: notifications (off -- see below), the launcher, the
# lock screen, idle handling, the packages a bare compositor needs on PATH, and
# the cursor.
#
# These are grouped because they are all "the desktop around the compositor":
# each is a handful of lines, none of them is worth a file, and every one of
# them would otherwise have to be hunted for in a 2000-line module.
{
  config,
  lib,
  pkgs,
  scope,
}:
let
  inherit (scope)
    cursorName
    cursorSize
    generated
    workspaceMonitors
    ;
in
{
  # ---------------------------------------------------------------
  # Workspaces -> screens
  # ---------------------------------------------------------------
  # 1-3 on the built-in panel, 4-6 on the leftmost external, 7-9 on
  # the rightmost, and whatever is missing folds back onto the panel.
  # The whole argument for why this is a daemon and not a `workspace
  # = ...` rule is in modules/hyprland/workspace-monitors.nix.
  #
  # `Restart = "always"`, not "on-failure": the process is a reader on
  # Hyprland's event socket, and losing that socket is a *clean* exit
  # for it. PartOf the session target is what stops it for good when
  # the session itself ends, so "always" cannot turn into a respawn
  # loop against a compositor that is gone.
  systemd.user.services.hypr-workspace-monitors = {
    Unit = {
      Description = "Pin Hyprland workspace groups to screens by arrangement";
      PartOf = [ "hyprland-session.target" ];
      After = [ "hyprland-session.target" ];
    };
    Service = {
      ExecStart = workspaceMonitors;
      Restart = "always";
      RestartSec = 2;
    };
    Install.WantedBy = [ "hyprland-session.target" ];
  };

  # ---------------------------------------------------------------
  # Notifications, launcher, lock screen, idle
  # ---------------------------------------------------------------
  # mako is OFF, and this is the one thing adopting Caelestia
  # genuinely costs.
  #
  # Caelestia force-loads its notification service on shell init --
  # modules/ServiceLoader.qml names `Notifs;` unconditionally, unlike
  # `VPN` right below it, which is gated on a config key -- and
  # services/Notifs.qml stands up a NotificationServer. So it claims
  # org.freedesktop.Notifications, and there is no setting that stops
  # it. Two daemons cannot both hold that bus name.
  #
  # Leaving both enabled would not error, which is exactly why it is
  # the wrong answer: whichever unit registers first silently wins
  # and the other's notifications vanish. A start-order race that
  # works until it doesn't is worse than a deliberate choice, so this
  # is the deliberate choice -- Caelestia draws notifications now.
  #
  # The matugen `mako` template and its `makoctl reload` post-hook
  # went with it. `git revert` of this commit brings back mako, the
  # template and the hand-written bar together.
  services.mako.enable = false;

  programs.rofi = {
    enable = true;
    package = pkgs.rofi;
    # Kept in step with the `font` in the matugen theme below, which
    # is what actually renders. 13 rather than 12 because the panel
    # runs at scale 1 (noughty.hyprland.scale) on ~162 DPI, so every
    # px is literal.
    font = "Inter 13";
    extraConfig = {
      # `modes` is rofi 2.0's spelling; `modi` is the pre-2.0 alias
      # and still parses, but `rofi -dump-config` writes `modes`, so
      # use the name the binary itself prints.
      modes = "combi,drun,run,window";
      # What Super+D actually shows (see the bind below). Order is
      # load-bearing: combi concatenates each sub-mode's matches in
      # *this* order rather than interleaving them, so an already
      # running window always sorts above the .desktop entry that
      # would start a second copy. Type "spotify", hit Enter, and you
      # land on the running Spotify -- rofi activates the window
      # through wlr-foreign-toplevel and Hyprland follows it to
      # whatever workspace it lives on. With nothing running, the
      # same keystrokes fall through to `drun` and launch it.
      #
      # `window` mode works here only because nixpkgs merged
      # rofi-wayland into `rofi` (2025-09-06) and 2.0 speaks
      # foreign-toplevel natively; the old X11 build saw XWayland
      # windows only, which on this desktop is none of them.
      combi-modes = "window,drun,run";
      show-icons = true;
      drun-display-format = "{name}";
      # Class then title, e.g. `spotify   Spotify Premium`. rofi's
      # default also has a `{w}` desktop-number field, which is
      # always empty on Wayland -- foreign-toplevel carries no
      # workspace -- and leaves a ragged gap at the start of the row.
      window-format = "{c}   {t}";
    };
    # A theme *name*, not a path: HM turns this into `@theme
    # "matugen"` in config.rasi, which rofi resolves through its
    # normal theme search path -- and that includes
    # $XDG_DATA_HOME/rofi/themes, where the file below lands. Passing
    # a string also stops HM from trying to generate a theme file of
    # its own, so there is exactly one writer.
    theme = "matugen";
  };

  programs.hyprlock = {
    enable = true;
    settings = {
      source = [ generated.hyprlock ];
      general = {
        hide_cursor = true;
      };
      background = [
        {
          # The live wallpaper, so the lock screen matches the
          # desktop it locked.
          path = "screenshot";
          blur_passes = 3;
          blur_size = 8;
        }
      ];
      input-field = [
        {
          size = "300, 50";
          outline_thickness = 2;
          dots_center = true;
          outer_color = "$lockAccent";
          inner_color = "$lockInner";
          font_color = "$lockForeground";
          fail_color = "$lockError";
          placeholder_text = "";
          position = "0, -40";
          halign = "center";
          valign = "center";
        }
      ];
      label = [
        {
          text = "$TIME";
          font_size = 64;
          font_family = "Inter";
          color = "$lockForeground";
          position = "0, 120";
          halign = "center";
          valign = "center";
        }
      ];
    };
  };

  services.hypridle = {
    enable = true;
    settings = {
      general = {
        lock_cmd = "${pkgs.procps}/bin/pidof hyprlock || ${pkgs.hyprlock}/bin/hyprlock";
        before_sleep_cmd = "${pkgs.systemd}/bin/loginctl lock-session";
        after_sleep_cmd = "${pkgs.hyprland}/bin/hyprctl dispatch dpms on";
      };
      listener = [
        {
          timeout = 300;
          on-timeout = "${pkgs.brightnessctl}/bin/brightnessctl -s set 10%";
          on-resume = "${pkgs.brightnessctl}/bin/brightnessctl -r";
        }
        {
          timeout = 600;
          on-timeout = "${pkgs.systemd}/bin/loginctl lock-session";
        }
        {
          timeout = 900;
          on-timeout = "${pkgs.hyprland}/bin/hyprctl dispatch dpms off";
          on-resume = "${pkgs.hyprland}/bin/hyprctl dispatch dpms on";
        }
      ];
    };
  };

  home.packages = with pkgs; [
    # Tools the bindings above reach for, plus the ones you want in
    # $PATH when you are poking at a Wayland session by hand.
    rofi
    grimblast
    slurp
    # satty is the annotation editor the screenshot binds hand their
    # capture to; swappy stays as the incumbent it replaces there,
    # since it is still a perfectly good `grimblast edit` target and
    # costs nothing to keep. satty wins the bind because swappy has
    # no highlighter and no numbered-marker tool, and exposes
    # copy-then-save only through its global config file rather than
    # per-invocation flags.
    satty
    swappy
    # The display arrangement GUI on Super+P. In $PATH as well as in
    # the bind so `nwg-displays --help` and its one-shot companions
    # (nwg-displays-apply) are reachable from a terminal.
    nwg-displays
    hyprpicker
    cliphist
    wl-clipboard
    brightnessctl
    pavucontrol
    playerctl
    awww
    matugen
    nwg-look
    wlogout
    hyprpolkitagent
  ];

  # Cursor theme. This module is the only thing that sets one now:
  # modules/kde.nix used to own it on blac/g14 (AeroThemePlasma's
  # "aero-drop"), which is why this was once gated to stay off those
  # hosts. With no cursor set at all, no theme is installed for the
  # user and XCURSOR_THEME goes unset; clients then ask for a
  # "default" theme that is not on disk and simply draw no pointer --
  # which is how the gap was found in the first place, staring at a
  # login screen with an invisible mouse.
  home.pointerCursor = {
    enable = true;
    package = pkgs.bibata-cursors;
    name = cursorName;
    size = cursorSize;
    gtk.enable = true;
    # Writes ~/.icons/default/index.theme and the Xcursor.* Xresources
    # -- where XWayland clients look, which GTK/Qt-on-Wayland do not.
    x11.enable = true;
  };
}
