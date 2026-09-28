# The shared shell: Caelestia, a whole desktop rather than a bar.
# file hands its extra halves back to things the rest of the session already
# runs. plans/caelestia-shell.md records what it insists on owning; the one
# thing it won't give up is notifications (see _session.nix, mako off).
#
# Imported unconditionally from _home.nix; everything below hangs off
# `programs.caelestia.enable`.
{
  config,
  lib,
  pkgs,
  scope,
}:
{
  programs.caelestia = {
    enable = true;

    systemd = {
      enable = true;
      # Shared by every NixOS GUI compositor. DriftWM and Home Manager's
      # Hyprland integration both drive this standard session target.
      target = "graphical-session.target";
    };

    settings = {
      bar = {
        # `persistent` defaults TRUE; this is what keeps an OLED panel dark.
        persistent = false;
        showOnHover = true;
      };

      appearance.transparency = {
        # Off by default upstream. Blur comes from the layerrules on the
        # caelestia-* namespaces in modules/hyprland.nix.
        enabled = true;
        base = 0.6;
        layers = 0.2;
      };

      # background.wallpaperEnabled defaults true, which would sit on top of
      # the one swww is rotating -- false drops Caelestia's own layer.
      background.wallpaperEnabled = false;

      general.idle = {
        # hypridle owns idle and hyprlock owns locking here. Caelestia's own
        # defaults (lock 180s, dpms 300s, suspend 600s) would otherwise race
        # them to blank the screen.
        timeouts = [ ];
        lockBeforeSleep = false;
      };
    };
  };
}
