# Windows 7 look for Plasma 6

**Repo(s):** nixconfig   **Status:** done

## Goal

Make the KDE desktops look like Windows 7 — Aero glass titlebars, the taskbar
with its glassy task buttons and start orb, the light `#f0f0f0` application
palette, the Segoe-ish UI font, the blue swoosh wallpaper — declaratively, so it
survives a rebuild and lands on any KDE host in the registry rather than being
hand-clicked into one machine's System Settings.

## Approach

### Draw the artwork rather than fetch it

No Windows 7 Plasma theme exists in nixpkgs, and store.kde.org downloads are not
something to pin a homelab on. The visually decisive pieces are few, and both
formats KDE uses are plain SVG with fixed element ids, so they are written by
hand in `modules/win7/`:

- **`aurorae/`** — the `Aero7` window decoration. `decoration.svg` is a 9-slice
  glass frame (translucent titlebar with the Aero reflection break, 8px side
  borders, a painted drop shadow in the Padding area), plus one SVG per button
  with the five states Aurorae asks for. `Aero7rc` carries the geometry, and its
  numbers must stay in sync with the SVG's slice rects.
- **`plasma/`** — the `Aero7` Plasma style, deliberately only two files:
  `panel-background.svg` (the taskbar) and `tasks.svg` (six 9-sliced task-button
  states). Everything else falls back to Breeze, which is fine and much less to
  maintain. Note the fallback is per *file*, not per element — any file we ship
  has to be complete.
- **`Aero7.colors`** — the application palette.
- **`start-orb.svg`**, **`wallpaper.svg`**.

Two constraints shaped these files. Qt's SVG renderer is a Tiny-profile parser:
no filters, no `<use>` across states, so glows and shadows are built from
gradient stops. And each element's *bounding box* is its slice geometry, so
every group opens with a near-invisible rect pinning its rect.

The wallpaper is the exception: it is rasterised by librsvg at build time, never
handed to Qt, so it can use real Gaussian blur.

### Fetch only what would be silly to draw

B00merang's Windows-7 GTK theme and icon set (hundreds of icons), and
Microsoft's own open-source Selawik, which is metric-compatible with Segoe UI.
Both icon-set workarounds in `modules/win7.nix` are for upstream breakage that
fails the build outright — dangling symlinks, and filenames with spaces that
make `gtk-update-icon-cache` reject its own output.

### Wiring

`plasma-manager` (new flake input) drives the selection: Plasma style, colour
scheme, icon theme, cursor, wallpaper, fonts, the single bottom panel and its
widgets, the titlebar button layout, blur/contrast, and Alt+Tab as thumbnails.

Split deliberately in two:

- `nixosModules.win7` installs the artwork and fonts **system-wide**. Plasma
  finds themes through `XDG_DATA_DIRS`, and an SDDM-launched session cannot be
  relied on to have `~/.nix-profile/share` in it.
- `homeModules.win7` selects them, and does the GTK side. It self-gates on
  `osConfig.noughty.host.desktop == "kde"` because the `gui-nixos` bundle that
  imports it is used by every NixOS desktop.

`modules/desktop.nix` had its GTK theme set to dark Nordic; those are now
`mkDefault` so this can take over on KDE hosts without a `mkForce` fight.

## Verification

`nixosConfigurations.g14.config.system.build.toplevel` builds. The generated
`~/.local/share/plasma-manager/scripts/1_script_apply_themes.sh` applies
`Aero7` / `DMZ-White` / `Windows-7`, and the panel script carries the orb icon
path and launchers.

**Applies at the next Plasma login, not at activation** — plasma-manager runs
its theme and panel scripts from an autostart entry.

## Known gaps

- The SDDM login screen keeps Breeze's background; only its cursor and font are
  set. A themed one needs a QML SDDM theme, not a config key.
- No app-icon (menu) button top-left: Aurorae draws that from the window icon
  rather than from theme art, so it would not match the rest of the frame.
- The Windows 7 sound scheme is not redistributable.
