# Shared launcher, packages, clipboard/polkit services, and cursor.
{
  config,
  lib,
  pkgs,
  scope,
  monique,
}:
let
  inherit (scope)
    cursorName
    cursorSize
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

  home.packages = (with pkgs; [
    # Compositor-independent Wayland desktop tools.
    rofi
    slurp
    satty
    swappy
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
  ]) ++ lib.optionals scope.hyprlandEnabled (with pkgs; [
    # These integrate directly with Hyprland IPC/configuration.
    grimblast
    monique
    hyprpicker
  ]);

  # Session plumbing belongs to the Linux GUI, not to a compositor's
  # exec-once list. graphical-session.target gives it the same lifecycle in
  # Hyprland and DriftWM and prevents duplicate watchers after a reload.
  systemd.user.services.gui-clipboard-text = {
    Unit = {
      Description = "Store text clipboard history";
      PartOf = [ "graphical-session.target" ];
    };
    Service = {
      ExecStart = "${pkgs.wl-clipboard}/bin/wl-paste --type text --watch ${pkgs.cliphist}/bin/cliphist store";
      Restart = "on-failure";
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };

  systemd.user.services.gui-clipboard-image = {
    Unit = {
      Description = "Store image clipboard history";
      PartOf = [ "graphical-session.target" ];
    };
    Service = {
      ExecStart = "${pkgs.wl-clipboard}/bin/wl-paste --type image --watch ${pkgs.cliphist}/bin/cliphist store";
      Restart = "on-failure";
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };

  systemd.user.services.moniqued = lib.mkIf scope.hyprlandEnabled {
    Unit = {
      Description = "Apply saved monitor profiles on hotplug";
      PartOf = [ "graphical-session.target" ];
      After = [ "graphical-session.target" ];
    };
    Service = {
      ExecStart = "${monique}/bin/moniqued";
      Restart = "on-failure";
      RestartSec = 2;
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };

  systemd.user.services.gui-polkit-agent = {
    Unit = {
      Description = "Graphical polkit authentication agent";
      PartOf = [ "graphical-session.target" ];
    };
    Service = {
      ExecStart = "${pkgs.hyprpolkitagent}/libexec/hyprpolkitagent";
      Restart = "on-failure";
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };

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
