# Decouple the Linux GUI session

**Repo(s):** nixconfig   **Status:** done

## Goal

Make the desktop shell and common Wayland session facilities available to every
NixOS GUI session, including DriftWM, instead of making Hyprland the accidental
owner of Caelestia, wallpaper rotation/theming, the launcher, cursor, and common
desktop utilities.

## Approach

`homeModules.gui-nixos` owns the shared session module.  The shared services bind
to `graphical-session.target`, which both DriftWM and Hyprland sessions reach.
Hyprland keeps compositor configuration, plugins, rules/keybinds, lock/idle
integration, and Hyprland-specific generated colour files.

## Steps

1. [x] Move the wallpaper/theme options from `noughty.hyprland` to `noughty.gui`.
2. [x] Import the session Home Manager module from `gui-nixos`, not the Hyprland
   NixOS module.
3. [x] Gate compositor-only sections on the Hyprland tag and run shared services on
   `graphical-session.target`.
4. [x] Parse-check every changed Nix file and inspect the diff for dangling option
   references.

## Open decisions

The existing Hyprland colour outputs remain available when Hyprland is the
active compositor; shared Caelestia, Rofi, and GTK outputs are generated for all
NixOS GUI sessions.

## Risks / rollout

The main risk is starting two copies of a session service.  Ownership is moved,
not duplicated, and systemd units use the common graphical session lifecycle.
Laptop activation still requires the local rebuild path rather than deploy-rs.
