# The shell: Caelestia, in place of the hand-written Quickshell bar this
# session used to carry.
#
# It is a whole desktop rather than a bar, which is why this file is mostly
# about handing its extra halves back to the things the rest of the session
# already runs. plans/caelestia-shell.md records what it insists on owning,
# what it gives up, and the one thing it will not give up -- notifications,
# which is why _session.nix turns mako off.
#
# The module itself is imported unconditionally from _home.nix; everything
# below hangs off `programs.caelestia.enable`.
{
  config,
  lib,
  pkgs,
  scope,
}:
{
  # ---------------------------------------------------------------
  # Bar / shell
  # ---------------------------------------------------------------
  # Caelestia, in place of the hand-written Quickshell bar this used
  # to carry (commit 1201b63, if it ever needs to come back).
  #
  # It is a whole desktop rather than a bar, so most of what follows
  # is handing its extra halves back to the things this module
  # already runs. plans/caelestia-shell.md records what it insists on
  # owning, what it gives up, and the one thing it will not give up
  # (notifications -- see services.mako below).
  programs.caelestia = {
    enable = true;

    systemd = {
      enable = true;
      # Only ever start under Hyprland. The module's default is
      # config.wayland.systemd.target, i.e. graphical-session.target,
      # which any graphical session reaches -- that is what used to
      # drop this shell on top of the Plasma panel, and it would do
      # the same to whatever session came next.
      target = "hyprland-session.target";
    };

    settings = {
      bar = {
        # The reason adopting this is worth anything at all: upstream
        # already implements the hide-until-approached behaviour the
        # hand-written bar existed to provide. `persistent` defaults
        # to TRUE, so this is the line that keeps an OLED panel dark.
        persistent = false;
        showOnHover = true;
      };

      appearance.transparency = {
        # Off by default upstream, which is precisely the complaint
        # that started this ("not really good looking, not
        # transparent"). Blur comes from the layerrules on the
        # caelestia-* namespaces in the compositor section above.
        enabled = true;
        base = 0.6;
        layers = 0.2;
      };

      # Caelestia draws its own wallpaper otherwise --
      # background.wallpaperEnabled defaults true -- which would sit
      # on top of the one swww is rotating. False drops its
      # background layer to WlrLayer.Bottom with a transparent
      # colour, so the wallpaper this module already manages shows
      # through untouched.
      background.wallpaperEnabled = false;

      general.idle = {
        # hypridle owns idle here and hyprlock owns locking. Left
        # alone Caelestia brings a SECOND idle stack -- its defaults
        # are lock at 180s, dpms off at 300s, suspend-then-hibernate
        # at 600s -- and the two would race to blank the screen. An
        # empty timeout list is how you tell it to stay out of that.
        timeouts = [ ];
        lockBeforeSleep = false;
      };
    };
  };
}
