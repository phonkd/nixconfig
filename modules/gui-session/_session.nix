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
    rbwMode
    sinkSwitcher
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
      modes = "combi,bitwarden:${rbwMode},audio:${sinkSwitcher},drun,run,window";
      # Ctrl+<n> jumps to mode <n> from anywhere in the launcher: drun, run,
      # window and script modes all treat kb-custom-<k> as "switch to mode
      # index k-1", so kb-custom-2 opens `bitwarden` (index 1), kb-custom-3
      # `audio`, and Ctrl+0 returns to combi. Alt+<k> stays as rofi's default.
      kb-custom-1 = "Alt+1,Control+0";
      kb-custom-2 = "Alt+2,Control+1";
      kb-custom-3 = "Alt+3,Control+2";
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
    grim
    slurp
    satty
    wl-clipboard
    brightnessctl
    pavucontrol
    playerctl
    awww
    matugen
    nwg-look
    wlogout
  ]) ++ lib.optionals scope.hyprlandEnabled (with pkgs; [
    # These integrate directly with Hyprland IPC/configuration.
    grimblast
    monique
    hyprpicker
  ]);

  xdg.configFile."satty/config.toml".text = ''
    [general]
    output-filename = "~/Pictures/Screenshots/%Y%m%d_%H%M%S.png"
    actions-on-enter = ["save-to-clipboard", "save-to-file", "exit"]
    actions-on-escape = ["save-to-clipboard", "exit"]
    copy-command = "${pkgs.wl-clipboard}/bin/wl-copy"
  '';
  # satty does not create the output directory.
  systemd.user.tmpfiles.rules = [ "d %h/Pictures/Screenshots - - - -" ];

  services.cliphist = {
    enable = true;
    allowImages = true;
  };
  services.hyprpolkitagent.enable = true;

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
