# hyprland

**Repo(s):** nixconfig   **Status:** done

## Goal

A second, fully declarative desktop session on the KDE desktops (`g14`, `blac`):
Hyprland + Waybar, with the **same keybindings** the KDE hosts already have
(`modules/kde.nix`, which itself mirrors AeroSpace on the Mac), the
**same rotating wallpaper** the KDE hosts already have
(`modules/kde.nix`'s Plasma slideshow), and — the new part — a colour
scheme that is **re-derived from each wallpaper as it changes** and pushed into
the bar, the compositor and the GTK apps.

Additive, not a replacement: KDE stays exactly as it is and Hyprland shows up as
another entry in SDDM's session picker. Nothing about the Plasma session changes,
so backing this out is deleting one module.

## Approach

### Why this can be done without workarounds

The user's condition was "waybar only if dynamic wallpaper colour is feasible
without workarounds". It is, and the reason is a Waybar feature rather than a
trick — verified against the shipped man page of `waybar` 0.15.0 in our pinned
nixpkgs:

> **`reload_style_on_change`** — Option to enable reloading the css style if a
> modification is detected on the style sheet file **or any imported css files**.

So the whole colour pipeline is: something rewrites `colors.css`, and Waybar
notices by itself. No `killall -SIGUSR2 waybar`, no wrapper, no polling. Every
other consumer has the same story — `hyprctl reload` and `makoctl reload` are the
documented reload commands for those two, and rofi/hyprlock read their config at
launch anyway.

### Colour generation: matugen

`matugen` 4.0.0 (in our pinned nixpkgs, cached) does Material-You extraction from
an image and renders arbitrary templates. One caveat found by testing rather than
reading: **matugen 4 prompts interactively** to pick among candidate source
colours, and in a systemd unit that fails with

```
Failed to get source color / IO error: not a terminal
```

`--source-color-index 0` selects the top candidate and makes it non-interactive.
Verified end to end: with that flag it renders templates from a pipe with no tty.

matugen 4 has **no** built-in wallpaper setter (the `wallpaper_tool` key from
older versions is gone), so the wallpaper is set separately, by `swww`.

### The chain

A systemd **user timer**, bound to `hyprland-session.target` so it only ever runs
in a Hyprland session and never under Plasma:

```
pick a random image from the wallpaper dir
  -> awww img <image>            (set the wallpaper, with a fade)
  -> matugen image <image>       (re-render every template)
       -> ~/.config/waybar/colors.css     -> waybar reloads itself
       -> ~/.config/hypr/colors.conf      -> post_hook: hyprctl reload
       -> ~/.config/mako/colors           -> post_hook: makoctl reload
       -> ~/.config/gtk-{3,4}.0/colors.css
       -> ~/.config/rofi/colors.rasi
       -> ~/.config/hypr/hyprlock-colors.conf
```

`swww` is packaged as `awww`/`awww-daemon` in current nixpkgs (upstream rename);
the module calls those names.

### Files Home Manager owns vs. files matugen owns

These must not overlap — an HM-managed path is a read-only store symlink and
matugen would fail to write it. So every generated file is a **separate
`colors.*` file** that an HM-managed file pulls in by absolute path:

| HM writes (store symlink)        | imports                             |
|----------------------------------|-------------------------------------|
| `waybar/style.css`               | `@import ".../waybar/colors.css"`   |
| `hypr/hyprland.conf`             | `source = .../hypr/colors.conf`     |
| `hypr/hyprlock.conf`             | `source = .../hyprlock-colors.conf` |
| `gtk-3.0/gtk.css` (via extraCss) | `@import ".../gtk-3.0/colors.css"`  |
| `gtk-4.0/gtk.css` (via extraCss) | `@import ".../gtk-4.0/colors.css"`  |
| `mako/config`                    | `include=.../mako/colors`           |
| `rofi/themes/matugen.rasi`       | `@import ".../rofi/colors.rasi"`    |

Two ordering details that were found by reading the generated files rather than
by assumption, and that the module comments record:

- The `source=` line lands at the *top* of the Hyprland and hyprlock configs, so
  the `$primary`-style variables exist before the blocks that use them.
- HM emits mako's settings alphabetically, which puts `include=` in the middle
  of the file. mako parses an include in the enclosing context, so the included
  file must contain **no** `[criteria]` section — an open section would silently
  capture the parent's remaining keys (`margin`, `padding`, `width`).

rofi is reached by theme *name* (`@theme "matugen"`), resolved through rofi's own
theme search path, rather than by an absolute path in `@theme`.

This matters for GTK4 specifically: HM writes `gtk-4.0/gtk.css` on its own
whenever a GTK4 theme is set (it is, `Nordic-darker` from
`modules/desktop.nix`), so matugen writing that path directly would collide.
Routing through `gtk.gtk{3,4}.extraCss` keeps HM in charge of the file and lets
matugen own only the colours.

The generated files are **seeded** by an HM activation script if absent, so a
first login (before the timer has ever fired) does not hit Hyprland's "file
doesn't exist" config error or an unstyled bar.

### Keybindings

Taken from `modules/kde.nix` verbatim — `Alt` is the Mac's `Option`:

| key | action |
|---|---|
| `Alt+H/J/K/L` | move focus left/down/up/right |
| `Alt+Shift+H/J/K/L` | move window left/down/up/right |
| `Alt+F` | fullscreen |
| `Super+Q` | close window |
| `Alt+{Q,W,E,A,S,D,U,I,O}` | workspace 1..9 |
| `Alt+Shift+{same}` | move window to workspace 1..9 |
| `Alt+B` / `Alt+V` / `Alt+M` | Zen / kitty / Spotify |

Note KWin has no tiling "move node", so the KDE half had to spell `Alt+Shift+HJKL`
as *quick-tile*; Hyprland is a real tiling WM, so it gets `movewindow`, which is
what the AeroSpace original does. The nine workspace letters keep AeroSpace's
order, and Waybar labels its workspace pills with those letters so the mapping is
visible rather than memorised.

Hyprland additionally needs explicit binds for things Plasma provides for free
(launcher, screenshot, lock, media/brightness keys). Those are marked as such in
the module and are the only bindings not present in the KDE half.

## Steps

- [x] Recover the old Hyprland config from git history for reference
      (`modules/desktop-environment.nix`, deleted in 5727b1a).
- [x] Verify the package set and the two non-obvious behaviours
      (`reload_style_on_change`, matugen's interactive prompt).
- [x] `modules/hyprland.nix`: NixOS half (options + compositor + fonts) and HM
      half (hyprland, waybar, matugen, wallpaper timer).
- [x] Wire into `lib/registry.nix` for `blac`, `z14` and `g14`.
- [ ] Rebuild on the host itself, then pick "Hyprland" at SDDM (see rollout).

## Open decisions

- **Compositor from nixpkgs, not the `hyprland` flake input.** There is an
  uncommitted `hyprland.url = git+…` in `flake.nix` (not added by this work). It
  is not used here: nixpkgs' Hyprland is cached in `cache.nixos.org`, whereas the
  flake would build Hyprland and aquamarine from source on every bump unless
  `hyprland.cachix.org` is added as a trusted substituter. Recommend dropping
  that input; say so if you want the bleeding edge and the cache entry instead.
- **Both desktops, not just `g14`.** The session is additive, so enabling it on
  `blac` too costs nothing and keeps the two machines identical. Drop the
  `"hyprland"` tag from `blac` in `lib/registry.nix` if you'd rather it stayed
  KDE-only.
- **Bindings duplicated, not shared with the KDE module.** A single shared table
  consumed by both halves would be nicer. It was deliberately not done here:
  this work was written while a concurrent session was mid-refactor on
  `modules/kde-shortcuts.nix` (folding it into what is now `modules/kde.nix`),
  and editing that file would have meant conflicting against uncommitted work.
  That refactor has since landed, so unifying the two tables is now a clean
  follow-up -- the natural shape is a helper in `lib/` taking
  `{ pkgs, config, inputs }` and returning the key/action table both halves
  render.
- **Hosts: `blac`, `z14`, `g14`.** `z14` was added at the user's request after
  the fact — it landed in the registry from a concurrent session while this work
  was in flight. `g14` keeps its tag even though that laptop is offline and may
  be retired: the tag does nothing until something rebuilds that host, so
  leaving it costs nothing and keeps the three KDE machines uniform. Drop it
  from `lib/registry.nix` if the retirement is decided.
- **GTK apps do not restyle live.** New windows pick up the new colours; already
  running GTK apps re-read their CSS only when nudged. A `gsettings` theme-toggle
  post-hook does that for GTK3 and is included; GTK4/libadwaita apps keep their
  colours until restarted. Waybar, Hyprland and mako *are* live.

## Risks / rollout

- Zero risk to the Plasma session: nothing in this change touches a KDE module,
  and every systemd unit is bound to `hyprland-session.target`, which only
  Hyprland starts. Worst case Hyprland fails to start and SDDM drops you back to
  the picker, where Plasma is still sitting.
- Rollout is **not** `deploy <host>`. The desktops are deploy *clients*, not
  deploy-rs nodes — none of them sets `deploy.hostname` in `lib/registry.nix`,
  and `deploy --list` shows only the servers. So each machine rebuilds itself,
  from its own checkout of `main`:

  ```
  sudo nixos-rebuild switch --flake ~/git/nixconfig#blac    # on blac
  sudo nixos-rebuild switch --flake ~/git/nixconfig#z14     # on z14
  ```

  Then log out and pick "Hyprland" in SDDM's session menu. First login pulls
  ~230 MB (fonts are most of it) and the wallpaper lands about three seconds in,
  when the timer first fires.
- Back out by removing the `"hyprland"` tag from that host's registry entry (the
  module self-gates on it) and rebuilding.
