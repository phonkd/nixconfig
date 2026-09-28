# Hyprland as one compositor module

**Repo(s):** nixconfig   **Status:** in-progress

## Goal

Make Hyprland's compositor-specific implementation one readable module below
300 lines, while retaining the shared Linux GUI session and all current desktop
behaviour. Remove the misleading `modules/hyprland/` ownership of facilities
that DriftWM and other compositors also use.

## Approach

Move Caelestia, Rofi, clipboard/polkit services, cursor setup, wallpaper
rotation, Matugen templates, GTK integration, and common packages behind the
existing `linux-gui-session` Home Manager module. Keep only the NixOS Hyprland
session, compositor settings, keybindings, lock/idle configuration, and the
small Hyprland hooks in `modules/hyprland.nix`.

The shared module will expose the generated Hyprland colour paths and wallpaper
rotation hooks through ordinary Home Manager options, avoiding imports back into
Hyprland and keeping the dependency one-way.

## Steps

- [x] Establish the shared GUI-session module and move compositor-independent configuration.
- [x] Fold all compositor-specific configuration into `modules/hyprland.nix` and remove `modules/hyprland/`.
- [x] Check the line budget, parse every changed Nix file, and search for dangling references.
- [ ] Commit the completed refactor without deploying; desktop hosts use their local rebuild path.

## Open decisions

The 300-line ceiling applies to `modules/hyprland.nix`, not to the shared GUI
implementation. The standalone `hypr-sink-switcher` package remains separately
runnable and therefore stays a flake-parts package outside the compositor
module, under the shared GUI-session area.

## Risks / rollout

This is intended to be a structural move with no behaviour change. The main
risk is losing a Home Manager import or changing a systemd target while moving
ownership. Verification is limited to parse checks and reference searches per
repo policy. These laptop/desktop configurations are not deploy-rs targets, so
activation remains a local rebuild on the relevant machine.
