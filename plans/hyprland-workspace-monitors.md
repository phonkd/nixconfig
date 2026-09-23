# hyprland: workspaces pinned to screens

**Repo(s):** nixconfig   **Status:** done -- deliberately NOT in nix

## Outcome

Workspaces 1-3 on the laptop panel, 4-6 on the external, 7-9 on a second
external when there is one. Set **once, by hand**, in
`~/.config/hypr/workspaces.conf` -- local state on z14, outside git.

Nothing in this repo implements it. That is the decision, not an omission:
`_compositor.nix` already `source`s that file (it is nwg-displays' half of the
monitor dialog, Super+P), so the mechanism was there all along and needed no
nix at all.

## Two rejected attempts, so they don't get rebuilt

**A helper daemon** (`modules/hyprland/workspace-monitors.nix`, since deleted).
The original ask was positional -- "leftmost external is monitor 2" -- and a
Hyprland workspace rule cannot say that; it names a monitor, by connector or
`desc:`. So the first cut watched the event socket, sorted outputs by x, and
pushed the mapping in with `hyprctl keyword`. It worked and was verified live.
Rejected: bespoke code, owned by nobody, in the path of something that
otherwise has no moving parts, able to break in ways a config file cannot.

**A nix option** (`noughty.hyprland.workspaceScreens`, also deleted). Static
`workspace = <n>, monitor:<name>` rules rendered from a per-host attrset.
Rejected for a simpler reason: the mapping is a fact about one desk on one
laptop, it gets set once, and it does not want a rebuild cycle to change.

## What Hyprland does on its own

Worth knowing before anyone reaches for machinery again:

* a rule naming a monitor that is **not connected** is not an error -- the
  workspace opens on the focused monitor instead, and the compositor moves it
  to its own screen when that screen appears. Verified by unplugging: with the
  external gone, all nine land on the panel and nothing complains.
* `monitor:desc:<EDID description>` matches the *display* rather than the
  *port*, by prefix, so it survives a different dock or cable. Verified on this
  machine: a real description resolves, a prefix of one resolves, a bogus one
  returns "Monitor not found". This is how people handle several docking
  stations without scripts -- list every monitor owned; absent ones are inert.
* what it still cannot do is positional selection. There is no "second screen
  from the left", and `desc:` cannot separate two monitors with identical or
  blank EDIDs (some DisplayLink docks, and this host has one).

## Where the file lives

`~/.config/hypr/workspaces.conf`, seeded empty at activation by `_theming.nix`
(Hyprland treats a missing `source` as a config error). nwg-displays rewrites
it wholesale when its Apply is used, so hand-written entries there are lost if
the dialog is used to reassign workspaces -- re-add them, or set them from the
dialog instead.
