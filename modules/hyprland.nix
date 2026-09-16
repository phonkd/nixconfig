# Hyprland: the fully declarative session on every NixOS desktop here -- blac,
# g14 and z14, all three `desktop = "hyprland"` in lib/registry.nix. It is the
# *only* session on each; modules/desktop.nix's greetd/tuigreet branch is what
# gives it a login screen. Back it out by dropping the "hyprland" host tag in
# lib/registry.nix, which leaves the host with no session at all.
#
# It was not always the only one. blac and g14 ran KDE -- Plasma 6 under
# AeroThemePlasma, from a modules/kde.nix that no longer exists -- and this was
# the second entry in SDDM's session menu next to it. Every systemd user unit
# in this tree is still bound to `hyprland-session.target`, which is why that
# arrangement worked and why nothing here leaks into a session it did not
# start. Two things below are inherited from that era on purpose:
#
#   * Keybindings, which came from modules/kde.nix -- which in turn mirrored
#     AeroSpace on the Mac. Alt is Option. See the table further down.
#   * A rotating wallpaper, which was Plasma's slideshow first.
#   * ...and the part that was new here: the colour scheme is re-derived from
#     each wallpaper as it changes, and pushed into the shell, the compositor,
#     the launcher, the lock screen and GTK.
#
# The shell is Caelestia (programs.caelestia, in _shell.nix), adopted in place
# of a hand-written Quickshell bar -- see plans/caelestia-shell.md. It is a
# whole desktop rather than a bar, so it also owns notifications now; mako is
# off, and the note at services.mako in _session.nix explains why that is a
# choice rather than an oversight.
#
# Why every consumer repaints itself without a reload hack
# --------------------------------------------------------
# The usual way to repaint a shell from a wallpaper is to signal it, or kill
# and respawn it, after rewriting its colours. None of that happens here.
# Caelestia reads its scheme through a FileView that watches the file and
# rebinds, so QML property bindings do the repainting and there is nothing to
# restart -- which is exactly why matugen can keep owning colour generation
# instead of handing it to `caelestia scheme set`. See `caelestiaTemplate`.
#
# Hyprland has a documented reload command (`hyprctl reload`); rofi and
# hyprlock read their config at launch. Every consumer is repainted through a
# first-class feature of that consumer.
#
# Colour generation is matugen (Material You extraction + templating). Two of
# its behaviours are not obvious and were found by running it, not by reading:
#
#   * matugen 4 PROMPTS. Given an image it offers several candidate source
#     colours and waits for an arrow-key pick, so in a systemd unit it dies
#     with "Failed to get source color / IO error: not a terminal".
#     `--source-color-index 0` takes the top candidate and makes it silent.
#   * matugen 4 no longer sets wallpapers. The `wallpaper_tool` key older
#     guides mention is gone from the binary, hence the awww (swww) call in
#     _matugen.nix's rotation script.
#
# Home Manager's files vs. matugen's files
# ----------------------------------------
# These must not overlap: an HM-managed path is a read-only symlink into the
# store, and matugen writing one would fail every rotation. So matugen only
# ever owns a separate `colors.*` file, which an HM-owned file pulls in by
# absolute path (relative imports would resolve against /nix/store).
#
# GTK is where that would otherwise bite: HM generates gtk-{3,4}.0/gtk.css
# itself as soon as `gtk.gtk3.extraCss` / `gtk.gtk4.theme` are set, so those are
# paths it may claim. (As things stand `gtk.gtk4.theme` is null on these hosts
# -- `gtk.theme` in modules/desktop.nix is a different option -- so today HM
# would not fight us for it. Routing the colours through
# `gtk.gtk{3,4}.extraCss` anyway means the file stays HM's and only the colours
# are ours, which stops being luck the moment someone sets a GTK4 theme.)
#
# The second GTK problem is scope: gtk.css is *user-wide*, while everything
# else here is per-session. That mattered when these hosts also ran Plasma
# under a deliberate Windows 7 GTK theme -- wallpaper colours bleeding into
# that session were a visible regression. Hyprland is the only session now, so
# the machinery in `clearGtkColors` (_matugen.nix) has nothing left to protect;
# it stays because it is also what restores the declared theme between
# sessions, which is still the right resting state.
#
# Where things are
# ----------------
# This module used to be one 2200-line file. It is now a thin entry point over
# modules/hyprland/, and the split is by *what you would be changing*:
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
# import-tree, which ignores any path containing `/_`. Without it every one of
# those files would be auto-imported as a flake-parts module and fail. The two
# files in there *without* an underscore -- ee-volume.nix, rofi-sink-switcher.nix
# -- are genuine flake-parts modules defining perSystem packages, and are picked
# up exactly that way.
{
  self,
  inputs,
  ...
}:
{
  flake.nixosModules.hyprland = import ./hyprland/_nixos.nix { inherit self; };
  flake.homeModules.hyprland = import ./hyprland/_home.nix { inherit self inputs; };
}
