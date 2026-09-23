# hyprland: pin workspace groups to monitors by arrangement

**Repo(s):** nixconfig   **Status:** in-progress

## Goal

Workspaces 1-9 should always live on a predictable screen, chosen by where the
screen *is* rather than what it is called:

| workspaces | screen |
|---|---|
| 1 2 3 | the built-in z14 panel |
| 4 5 6 | the leftmost external |
| 7 8 9 | the rightmost external |

A screen that is not connected falls back to the built-in panel (and, if the lid
is shut and the panel is off, to the leftmost screen that does exist). Plugging
it back in must move its workspaces back without a logout.

## Approach

Hyprland's own `workspace = 4, monitor:<name>` rule is the mechanism, but it can
only name a monitor -- there is no "the second one from the left". Connector
names are also not stable across docks/ports (the only external ever seen here
is `HDMI-A-1`, and a second one would be whatever port it lands in), so the
static rule cannot be written out in nix.

So: a small helper, `hypr-workspace-monitors`, that computes the mapping from
the live output list and pushes it in as *dynamic* rules.

* **Order**: built-in panel (`eDP*`/`LVDS*`/`DSI*`) is slot 1 by definition;
  every external takes slots 2, 3, ... sorted by x. Externals keep their slot
  whether or not the panel is on, so with the lid shut ws 4-6 stay on the left
  screen and 7-9 on the right -- only 1-3 relocate.
* **Push**: `hyprctl keyword workspace <n>,monitor:<name>` for where a workspace
  will open next, plus `dispatch moveworkspacetomonitor` for the ones that
  already exist. One `--batch` call.
* **Re-run**: at session start and on `monitoradded` / `monitorremoved` /
  `configreloaded` from the socket2 event stream. The reload case is not
  optional -- `hyprctl keyword` rules are wiped by a config reload, and the
  wallpaper rotation reloads every few minutes.

## Steps

1. `modules/hyprland/workspace-monitors.nix` -- the perSystem package, same
   shape as `ee-volume.nix` / `rofi-sink-switcher.nix`.
2. `_scope.nix`: bind its store path next to the other helpers.
3. `_session.nix`: a user unit bound to `hyprland-session.target`.
4. Land on `main`, deploy z14.

## Notes

nwg-displays also writes `workspaces.conf` (it has a workspace-assignment
column). Nothing forbids using it, but anything set there is a static name and
gets overridden by this helper on the next event; leave that column alone.
