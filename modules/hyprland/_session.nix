# The rest of the session: notifications (off -- see below), the launcher,
# the lock screen, idle handling, packages a bare compositor needs on PATH,
# and the cursor.
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
    ;
in
{
  # mako is OFF: Caelestia force-loads its own notification service on shell
  # init (modules/ServiceLoader.qml names `Notifs;` unconditionally) and
  # claims org.freedesktop.Notifications, which two daemons cannot both hold.
  # Leaving both enabled would not error, but whichever registers first
  # silently wins -- so this is the deliberate choice, not a race. The
  # matugen `mako` template and its `makoctl reload` post-hook went with it.
  services.mako.enable = false;

  programs.rofi = {
    enable = true;
    package = pkgs.rofi;
    # Kept in step with the matugen theme's own `font` below. 13 rather than
    # 12 because the panel runs at scale 1 on ~162 DPI, so every px is literal.
    font = "Inter 13";
    extraConfig = {
      # `modes` is rofi 2.0's spelling (`modi` is the pre-2.0 alias).
      modes = "combi,drun,run,window";
      # combi concatenates each sub-mode's matches in *this* order rather
      # than interleaving them, so an already-running window always sorts
      # above the .desktop entry that would start a second copy.
      #
      # `window` mode works only because nixpkgs merged rofi-wayland into
      # `rofi` (2025-09-06) and 2.0 speaks foreign-toplevel natively; the
      # old X11 build saw XWayland windows only.
      combi-modes = "window,drun,run";
      show-icons = true;
      drun-display-format = "{name}";
      # rofi's default `{w}` desktop-number field is always empty on
      # Wayland (foreign-toplevel carries no workspace).
      window-format = "{c}   {t}";
    };
    # A theme *name*, not a path: HM turns this into `@theme "matugen"`,
    # which rofi resolves through $XDG_DATA_HOME/rofi/themes (the file
    # below). A string also stops HM generating a theme file of its own.
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
          # The live wallpaper, so the lock screen matches the desktop it locked.
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
    # Tools the keybinds reach for, plus what you want on $PATH when poking
    # at a Wayland session by hand.
    rofi
    grimblast
    slurp
    # satty is the screenshot binds' annotation editor; swappy stays as a
    # perfectly good `grimblast edit` target that costs nothing to keep.
    satty
    swappy
    # The display arrangement GUI on Super+P; also in $PATH for
    # `nwg-displays --help` and nwg-displays-apply.
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

  # With no cursor theme set at all, XCURSOR_THEME goes unset and clients ask
  # for a "default" theme that isn't on disk, drawing no pointer at all.
  home.pointerCursor = {
    enable = true;
    package = pkgs.bibata-cursors;
    name = cursorName;
    size = cursorSize;
    gtk.enable = true;
    # Writes ~/.icons/default/index.theme and the Xcursor.* Xresources --
    # where XWayland clients look, which GTK/Qt-on-Wayland do not.
    x11.enable = true;
  };
}
