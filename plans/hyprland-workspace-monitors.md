# hyprland: pin workspace groups to screens

**Repo(s):** nixconfig   **Status:** done

## Goal

Workspaces 1-9 should live on a predictable screen rather than on whichever
monitor happened to have focus when they were first opened:

| workspaces | screen |
|---|---|
| 1 2 3 | the built-in z14 panel |
| 4 5 6 | the external |
| 7 8 9 | a second external, when there is one -- the panel until then |

A screen that is not plugged in folds back onto one that is, and plugging it
back in restores the split without a logout.

## What shipped

`noughty.hyprland.workspaceScreens`, an attrset of monitor name -> workspaces,
rendered into stock Hyprland `workspace = <n>, monitor:<name>` rules
(`_nixos.nix` declares it, `_compositor.nix` emits it, `modules/hosts/z14.nix`
sets it). No code, no daemon.

Hyprland already does everything except the selector:

* a rule naming a monitor that is not connected is not an error -- the
  workspace opens on the focused monitor instead;
* the compositor parks the workspaces of a monitor that vanishes on a
  surviving one, and moves them back when it returns.

So the undocked laptop puts all nine workspaces on the panel with nothing
declared to that effect, and docking restores the split.

## The rejected first attempt

The original ask was positional -- "leftmost is monitor 2, rightmost is
monitor 3" -- and a workspace rule cannot say that. It names a monitor, by
connector or `desc:`, and there is no "the second screen from the left". So the
first cut was `modules/hyprland/workspace-monitors.nix`: a shell helper run as a
user unit that read `hyprctl monitors`, sorted the outputs by x, and pushed the
mapping in with `hyprctl keyword` / `moveworkspacetomonitor` on every
monitoradded/monitorremoved/configreloaded event. It worked, and was verified
against the running session.

It was backed out on the user's call, and the reason is worth keeping: it was
bespoke code in the path of something that otherwise has no moving parts, owned
by nobody, and able to fail in ways a config file cannot. Six static lines that
are occasionally *wrong* beat a daemon that can be *broken* -- the failure mode
of a stale connector name is a workspace on the wrong screen, fixed by editing
one line.

What that trade actually costs: if an external moves to a different port, or a
second external arrives on the left rather than the right, the names in
`modules/hosts/z14.nix` have to change. `hyprctl monitors` prints them.

## Note

nwg-displays (Super+P) can set the same rules from its workspace column, into
the `workspaces.conf` that `_compositor.nix` sources. That file is sourced
*after* the settings above and therefore wins while it says anything -- fine,
but it is local state outside git, so the nix option is the better home for a
mapping meant to be permanent.
