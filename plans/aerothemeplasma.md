# Windows 7 look for Plasma 6: AeroThemePlasma

**Repo(s):** nixconfig   **Status:** done

## Goal

Make the KDE desktops look like Windows 7, declaratively, so it survives a
rebuild and lands on any KDE host in the registry rather than being hand-clicked
into one machine's System Settings.

## History: what this replaces

The first pass at this drew a Plasma theme by hand in `modules/win7/` — an
Aurorae glass frame, a panel background, task buttons, a colour scheme, a start
orb, a wallpaper — and pointed Plasma at them with plasma-manager. It worked and
it looked like Aero, but a *theme* is the wrong size of tool for this job: it can
restyle Plasma's start menu, it cannot replace it with Windows 7's. Same for the
taskbar, the tray flyouts, Aero Peek, Flip3D, the UAC dialog.

[AeroThemePlasma](https://gitgud.io/wackyideas/aerothemeplasma) does replace
them. It is a Plasma *shell*, not a theme: it ships its own plasmoids and
rebuilds `libplasma` and `plasma-workspace` with the aeroshell patches so that
things like the Windows 7 tooltip behaviour are possible at all. It runs as its
own session next to plain Plasma.

So the hand-drawn artwork is deleted, not kept as a fallback — it would only be a
second, worse answer to the same question.

## Approach

### Don't package it; it's already packaged

[`github:nyakase/aerothemeplasma-nix`](https://github.com/nyakase/aerothemeplasma-nix)
is a maintained flake covering the whole stack: the patched `libplasma` and
`plasma-workspace`, the KWin C++ effects (Aero glass blur, Aero Peek, Flip3D,
snap, glow), the plasmoids, the icon/cursor/sound themes, the SDDM theme, the
PlymouthVista boot splash and the UAC polkit agent. It exposes one NixOS module
under `programs.aeroshell`.

Packaging this ourselves would mean maintaining forks of two core Plasma
packages against a moving upstream. Not worth it.

### The pin is load-bearing

This is the one thing to be careful about. The flake patches `libplasma` **from
our nixpkgs**, so its revision has to match our Plasma version:

| | Plasma | works? |
|---|---|---|
| `nixos-26.05` (our pin) | 6.6.6 | — |
| upstream flake HEAD | targets 6.7 | **no** — the libplasma patch loses 4 of 7 hunks in `tooltiparea.h` and the build dies |
| upstream flake `2d80b38` | last of the 6.6 series | yes, applies with zero rejects |

So the input is pinned to `2d80b38`. Unpin it when nixpkgs reaches Plasma 6.7,
and not before. A routine `nix flake update` that lets this follow HEAD breaks
the desktop build, not just the theme — hence the long comment on the input.

(The alternative, moving g14 to `nixpkgs-unstable` for its Plasma 6.7.4, was
rejected: it drags the whole host off the release branch for a rice.)

### What we switch on

`modules/aerothemeplasma.nix`, self-gating on
`host.is.nixosDesktop && host.desktop == "kde"` like the module it replaced:

- the shell itself, the SDDM theme, the PlymouthVista boot splash, the UAC
  polkit agent, and Segoe UI (from the MIT-licensed Microsoft repo upstream
  vendors it from, not from a Windows ISO);
- **Wayland only.** `sessions.x11.enable` defaults to `services.xserver.enable`,
  which `modules/desktop.nix` sets on every desktop, so it has to be turned off
  explicitly — otherwise five KWin C++ effects get compiled a second time for a
  session we don't log into. KDE drops X11 in Plasma 6.8 regardless;
- `defaultSession = "aerothemeplasma"` at `mkOverride 900`, because nixos'
  `plasma6.nix` already `mkDefault`s it to `"plasma"` and two defaults collide.
  900 beats that but still loses to an ordinary host definition.

The home-manager half is now only GTK: B00merang's Windows 7 GTK theme, ATP's
own icon theme and the `aero-drop` cursor. AeroThemePlasma explicitly doesn't do
GTK, and the dark Nordic default from `modules/desktop.nix` would otherwise be
the one thing on screen still contradicting the rest. Those defaults were made
`mkDefault` in the previous pass and stay that way.

### plasma-manager is gone

Removed as a flake input, not just unused. Upstream names it specifically as the
thing that fights AeroThemePlasma: ATP configures Plasma from a first-login
setup wizard (`atpootb`), and plasma-manager rewrites the same files from an
autostart script. Two writers, one `kdeglobals`. If declarative Plasma settings
are wanted back later they have to be reconciled with the wizard, not layered on
top of it.

## Verification

`nixosConfigurations.g14.config.system.build.toplevel` builds, including the
patched `libplasma`/`plasma-workspace` and the KWin effects.

**The theme is not fully applied at activation.** The first login to the
AeroThemePlasma session runs a setup wizard that finishes applying it. Pick the
session at SDDM (it is the default), and let the wizard run.

## Known gaps

- Plain Plasma stays installed and listed at the login screen. That's deliberate
  — it's the escape hatch if a Plasma point release ever breaks the patched
  shell before the flake catches up. **Switching between the two sessions needs
  a reboot, not a logout.** `PLASMA_DEFAULT_SHELL` is what the systemd user
  drop-ins condition on to pick `aeroshell` over `plasmashell`, and it is set in
  the systemd *user manager*, which outlives an individual session. Log out of
  AeroThemePlasma and pick "Plasma (Wayland)" and the variable is still there,
  so you get aeroshell again and the escape hatch silently isn't one. Check with
  `systemctl --user show-environment | grep PLASMA_DEFAULT_SHELL`; clear it for
  the current manager with `systemctl --user unset-environment
  PLASMA_DEFAULT_SHELL`.
- Logging straight back in after `nixos-rebuild switch` can bounce you to the
  login screen once. The user manager survives the switch holding a dead
  `WAYLAND_DISPLAY`, so `plasma-ksplash` core-dumps and the new session's
  `plasma-workspace-wayland.target` is refused with "Requested transaction
  contradicts existing jobs … graphical-session.target has 'stop' job queued".
  A slow-stopping user unit (easyeffects, here) widens the window. Waiting a few
  seconds, or rebooting, gets past it — it isn't a broken build.
- Lucida Console (used only on the Plymouth LUKS prompt) is off: it has to be
  copied off a Windows install by hand.
- The Windows 7 *sound* theme is packaged by the flake and installed with the
  rest, but selecting it is part of the wizard, not something set here.
- Windows 7 games, Office 2010-on-Wine and the Geckium/Aero-userchrome Firefox
  work from the same rice writeup are out of scope; none of them are Plasma
  configuration.
- Dolphin gets Windows 7 *defaults* (Details view, Explorer's columns, 16px
  rows, no tab bar, full-width status bar) but not Explorer's *chrome*. Two
  parts can't be reached from configuration: the Places sidebar headings
  ("Places / Remote / Recent / Devices" rather than Favorites / Libraries /
  Computer / Network) are hardcoded in KFilePlacesModel, and Windows 7's
  command bar — Organize / Include in library / Share with / New folder — has
  no Dolphin equivalent. Rebuilding the toolbar would mean shipping our own
  `dolphinui.rc`, which is version-coupled to Dolphin and would break on
  upgrades; not worth it for the gain.
