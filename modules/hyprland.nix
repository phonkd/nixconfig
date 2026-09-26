# Hyprland: the *only* session on every NixOS desktop tagged "hyprland" in
# lib/registry.nix (blac, g14, z14). modules/desktop.nix's greetd/tuigreet
# branch gives it the login-screen entry; dropping the host tag leaves the
# host with no session at all.
#
# The shell is Caelestia (programs.caelestia, in _shell.nix) -- see
# plans/caelestia-shell.md. It owns notifications now; mako is off (see
# services.mako in _session.nix).
#
# Colour generation is matugen (Material You extraction + templating). Two
# of its behaviours are non-obvious and were found by running it:
#
#   * matugen 4 PROMPTS for a source colour and waits for an arrow-key pick
#     unless given `--source-color-index 0`, so a systemd unit without that
#     flag dies with "Failed to get source color / IO error: not a terminal".
#   * matugen 4 no longer sets wallpapers -- hence the separate awww (swww)
#     call in _matugen.nix's rotation script.
#
# Home Manager's files and matugen's files must never overlap: an HM-managed
# path is a read-only store symlink, and matugen writing one would fail every
# rotation. So matugen only ever owns a separate `colors.*` file, pulled in by
# absolute path (a relative import would resolve against /nix/store).
#
# GTK is where that would otherwise bite: HM generates gtk-{3,4}.0/gtk.css
# itself once `gtk.gtk3.extraCss` / `gtk.gtk4.theme` are set, so routing the
# colours through `gtk.gtk{3,4}.extraCss` keeps the file HM's and only the
# colours matugen's.
#
# Where things are -- a thin entry point over modules/hyprland/, split by
# *what you would be changing*:
#
#   _nixos.nix       the options, the session entry, PAM/polkit, fonts
#   _home.nix        the Home Manager half: builds the scope, merges the rest
#   _scope.nix       the shared `let` -- gating, the knobs read off osConfig,
#                    the layout switch, binary paths, generated-file paths
#   _matugen.nix     colour machinery: templates, the matugen config, the
#                    wallpaper rotation script, the GTK helpers
#   _compositor.nix  monitors, env, look, input, window/layer rules, exec-once
#   _keybinds.nix    the keymap, and only the keymap
#   _shell.nix       Caelestia
#   _session.nix     launcher, lock screen, idle, packages, cursor
#   _theming.nix     the wallpaper/colour config, gated on wallpaperDir
#
# The leading underscore is load-bearing: flake.nix imports modules/ with
# import-tree, which ignores any path containing `/_` -- without it every one
# of those files would be auto-imported as a flake-parts module and fail.
# ee-volume.nix and rofi-sink-switcher.nix have no underscore because they
# ARE flake-parts modules, defining perSystem packages.
{
  self,
  inputs,
  ...
}:
{
  flake.nixosModules.hyprland = import ./hyprland/_nixos.nix { inherit self; };
  flake.homeModules.hyprland = import ./hyprland/_home.nix { inherit self inputs; };
}
