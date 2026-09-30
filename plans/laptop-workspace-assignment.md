# Laptop workspace assignment picker

**Repo(s):** nixconfig   **Status:** draft

## Goal

After plugging one or two monitors into the z14 laptop, run a small terminal
script to put Q/W/E on the built-in screen, A/S/D on the first external screen,
and U/I/O on the second external screen when present. Pick the screens and
workspace groups interactively with fzf instead of editing Hyprland rules by
hand. Keep the existing workspace keybindings and numbering (1–9).

## Approach

- Add a command for the Hyprland session that reads connected outputs from
  `hyprctl monitors -j`. Show connector, display description, resolution, and
  current position in an fzf picker so identical-looking outputs can be told
  apart. Preselect the built-in panel when it is identifiable, but let the user
  change it.
- Present the workspace groups as Q/W/E (1–3), A/S/D (4–6), and U/I/O (7–9)
  in fzf. For each selected group, choose one connected output from fzf; show
  the proposed mapping and require one confirmation before applying. Prevent
  accidental duplicate choices unless the user explicitly assigns two groups
  to one screen.
- With one external screen, offer Q/W/E → built-in and A/S/D → external as
  defaults; leave U/I/O unpinned so Hyprland can place them normally. With two,
  offer the three-way mapping. If an external disconnects, absent-output rules
  must not trap access to its workspaces; rerunning the command should make the
  current setup easy to restore or change.
- Save the confirmed assignments in one script-owned Hyprland config file and
  apply them to the live session, including workspaces already open. Write the
  file atomically and keep the last good mapping if fzf is cancelled or a
  command fails. A later run replaces the prior mapping rather than appending
  conflicting rules.
- Keep monitor geometry and scale with Monique, whose migration is currently
  in progress (`plans/monique-displays.md`). Before implementation, verify how
  Monique writes workspace rules and ensure it and this script do not both own
  the same assignments. If Monique cannot leave workspace rules alone, use its
  supported profile interface instead of editing a competing config file.

## Steps

- [ ] Confirm z14's final Monique config location and rule precedence after the
      Monique migration lands; choose the single persistence path.
- [ ] Add the picker script and make it available in z14's Hyprland session.
- [ ] Add a convenient launcher or keybinding for use after docking.
- [ ] Verify no external, one external, and two external layouts; check fzf
      cancellation, same-description displays, reconnects, and moving existing
      workspaces without changing their keybindings.

## Open decisions

- **Target:** this assumes the z14 Hyprland laptop. The Mac uses AeroSpace and
  maps the third key group to Y/X/C, so it would need a separate backend.
- **One external:** U/I/O stay unpinned by default. They could instead follow
  A/S/D to the single external if that better matches the intended workflow.
- **Persistence:** use a separate generated Hyprland file only if Monique can
  own display layout without overwriting workspace ownership; otherwise use
  Monique's own saved profile mechanism.

## Risks / rollout

Wrong output selection can move visible workspaces to an unintended display.
Show the complete mapping before applying and retain the prior file for easy
recovery. This is a z14 session change; verify live after deployment and rerun
the picker to correct the layout if needed.
