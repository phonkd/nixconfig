# hy3 — i3/sway tiling layout for the Hyprland session

**Repo(s):** nixconfig   **Status:** draft

## Goal

Replace dwindle with [hy3](https://github.com/outfoxxed/hy3) as the layout for the
Hyprland session (`modules/hyprland.nix`): explicit i3/sway-style split nodes
instead of dwindle's automatic halving, plus hy3's tabbed groups. The point is
predictability — with dwindle, where a new window lands depends on the focused
window's aspect ratio; with hy3 you say where the split goes and it stays there.

Additive in the same way the Hyprland session itself is additive: hy3 is a
compositor plugin, KDE is untouched, and backing it out is flipping one option.

## Findings that shape the approach

Verified against this repo's actual pins, not the upstream README:

- **hy3 is already in nixpkgs.** `pkgs.hyprlandPlugins.hy3` is **0.55.0** in
  `nixos-26.05`, built against the same `pkgs.hyprland` **0.55.4** this session
  runs, and it **substitutes from cache.nixos.org** (361 KiB download, verified
  by `nix build`). No new flake input, no `follows`, no from-source build.
- **Do NOT follow hy3's README Nix instructions.** They tell you to add a
  `hy3` flake input with `inputs.hyprland.follows = "hyprland"`. Here that would
  build hy3 against `inputs.hyprland` — which is `git+https://github.com/hyprwm/Hyprland`
  **master** — while the session actually runs nixpkgs' 0.55.4. Hyprland refuses
  to load a plugin built against a different commit, so that route produces a
  plugin that silently never loads.
- **`inputs.hyprland` is dead code.** Declared at `flake.nix:47`, and
  `grep -rn 'inputs\.hyprland'` over the repo returns nothing. The session gets
  its compositor from `programs.hyprland.enable` → `pkgs.hyprland`. Worth
  deleting separately (see Steps), and worth knowing so nobody "fixes" hy3 by
  pointing it at that input.
- **Plugin loading is `exec-once`, and that is the one real risk.** The module
  pins `configType = "hyprlang"` (`modules/hyprland.nix`, in the
  `wayland.windowManager.hyprland` block). In that mode Home Manager renders
  `plugins` as `exec-once = hyprctl plugin load <path>`
  (home-manager's `modules/services/window-managers/hyprland/lib.nix`) — i.e. the
  plugin loads *after* the config is parsed. So at parse time `general:layout = hy3`
  names a layout that does not exist yet, and `plugin:hy3:*` keys belong to a
  plugin that has not registered them. This module already documents that
  unknown config keys are a **hard error, not a warning** (see the
  `dwindle:pseudotile` and `windowrule` grammar notes). Step 1 below is to find
  out which way this actually falls, because it decides the rest.
- **Escape hatch already exists.** `configType = "lua"` renders plugin loads as
  `hl.plugin.load(<path>)` at config-parse time, which is correctly ordered by
  construction. The module comment next to `configType` even says "`settings`
  below is format agnostic, so this is one line to change later." Hyprland 0.55.4
  ships the `hl.plugin` namespace (confirmed in its
  `share/hypr/stubs/hl.meta.lua`).
- **The wallpaper timer is a free repair mechanism.** matugen's `post_hook` runs
  `hyprctl reload` on every rotation (default every 300 s). By then the plugin
  is loaded, so a reload re-parses the config *with* hy3 present. If hy3 looks
  broken at login and correct a few minutes later, that is the cause — and it is
  also a usable diagnostic.

## Approach

Land it behind an option, smallest slice first.

**Phase 1 — make hy3 loadable and provable.** Add the plugin, a
`noughty.hyprland.layout` enum (`"dwindle"` | `"hy3"`, default `"dwindle"`), and
gate the layout/keybind/plugin-config changes on it. Nothing changes for anyone
until a host opts in. Prove the parse-order question with
`Hyprland --verify-config` before deploying anything.

**Phase 2 — bindings.** Swap the dispatchers hy3 requires, then add the group
bindings.

**Phase 3 — theming.** Wire hy3's tab colours into the matugen pipeline so tabs
follow the wallpaper like every other surface in this session already does.

**Phase 4 — rollout**, then decide whether the option stays (see Open decisions).

## Steps

### 1. Prove the load order (do this first, it gates everything)

Build a throwaway config with `layout = hy3` and a `plugin { hy3 { ... } }`
block and run the compositor's own checker — the exact workflow the module
header already prescribes:

```
Hyprland --verify-config -c /path/to/candidate.conf
```

Three outcomes:

- **"config ok"** → the happy path; `exec-once` loading is fine, continue.
- **errors on `plugin:hy3:*` only** → keep the plugin config out of the
  HM-generated file and let hy3 use its defaults for now, or move it behind the
  reload (see below).
- **errors on `general:layout`** → hy3 cannot be configured this way in
  hyprlang mode. Fall back, in order of preference:
  1. append `hyprctl reload` to the plugin-load `exec-once` (one extra line,
     cheapest);
  2. flip `configType = "lua"` so `hl.plugin.load()` runs at parse time. This is
     the correct fix but it re-renders the whole config, including the 0.55
     `windowrule`/`layerrule` grammar the module spent real effort getting
     right — so it is a fallback, not the opening move.

### 2. Plugin + option

In `modules/hyprland.nix`:

- NixOS half: add `layout` to `options.noughty.hyprland`:
  ```nix
  layout = lib.mkOption {
    type = lib.types.enum [ "dwindle" "hy3" ];
    default = "dwindle";
    description = "Tiling layout for the Hyprland session.";
  };
  ```
- Home half: `wayland.windowManager.hyprland.plugins =
  lib.optional (cfg.layout == "hy3") pkgs.hyprlandPlugins.hy3;`
- `general.layout = cfg.layout;` (currently hardcoded `"dwindle"`).
- Gate the `dwindle` block (`preserve_split`) on `cfg.layout == "dwindle"` — it
  is inert under hy3, and leaving it is the kind of dead config this module
  deliberately doesn't carry.
- `general.gaps_in = 8` / `border_size = 3` / `decoration.rounding = 12` stay,
  but note `plugin:hy3:group_inset` (default 10) stacks on top of the gaps.
  Expect one round of visual tuning.

### 3. Bindings

hy3's README is explicit that `movefocus` and `movewindow` **must** be replaced
or the layout misbehaves. Also swap `killactive` and `movetoworkspace`, which
are group-aware in hy3.

**Required swaps** (existing keys keep their meaning — only the dispatcher changes):

| Key | today | under hy3 |
|---|---|---|
| `ALT` + H/J/K/L | `movefocus, l/d/u/r` | `hy3:movefocus, l/d/u/r` |
| `ALT SHIFT` + H/J/K/L | `movewindow, l/d/u/r` | `hy3:movewindow, l/d/u/r` |
| `SUPER` + Q | `killactive` | `hy3:killactive` |
| `ALT SHIFT` + Q/W/E/A/S/D/U/I/O | `movetoworkspace, N` | `hy3:movetoworkspace, N` |

That last one is `workspaceBinds` — the `movetoworkspace` half of the `imap1`,
not the `workspace` half.

**New group bindings.** Key space is tight: `ALT` already owns H J K L F B V M
and Q W E A S D U I O (workspaces), so the free `ALT` letters are C G N P R T X
Y Z. Recommendation, following the module's own thesis of mirroring AeroSpace —
AeroSpace binds `alt-slash` to "flip tiling axis" and `alt-comma` to "accordion",
and hy3's tabs are this session's accordion:

| Key | dispatcher | mnemonic |
|---|---|---|
| `ALT, R` | `hy3:changegroup, opposite` | **r**otate the split axis (AeroSpace `alt-slash`) |
| `ALT, T` | `hy3:changegroup, toggletab` | **t**ab the group (AeroSpace `alt-comma`) |
| `ALT, N` | `hy3:makegroup, h` | i3 `split h` — **n**ew split right |
| `ALT SHIFT, N` | `hy3:makegroup, v` | i3 `split v` — new split down |
| `ALT, P` | `hy3:changefocus, raise` | focus **p**arent (i3 `focus parent`) |
| `ALT SHIFT, P` | `hy3:changefocus, lower` | focus child |
| `SUPER, Tab` / `SUPER SHIFT, Tab` | `hy3:focustab, r` / `hy3:focustab, l` | cycle tabs |
| `ALT, X` / `ALT SHIFT, X` | `hy3:expand, expand` / `hy3:expand, base` | e**x**pand node |

Deliberately letters, not punctuation. The literal AeroSpace keys (`,` and `/`)
are a trap on this keyboard: the layout is `ch`/`de_nodeadkeys`, where `/` is
Shift+7, and the module already carries a note (at the screenshot binds) about
keysym-vs-`code:` spelling biting exactly this way. Letters sidestep it.

`bindm` (`SUPER` + mouse drag) needs no change — it is float-drag, not a tiling
dispatcher.

Full dispatcher list for later additions: `hy3:equalize`, `hy3:locktab`,
`hy3:setswallow`, `hy3:setephemeral`, `hy3:warpcursor`, `hy3:togglefocuslayer`,
`hy3:debugnodes`.

### 4. Tab config and theming

```nix
plugin.hy3 = {
  tabs = { height = 22; padding = 6; radius = 6; border_width = 2;
           render_text = true; text_font = "Inter"; text_height = 11; };
  autotile = { enable = true; trigger_width = 800; trigger_height = 500; };
};
```

`Inter` is already in `fonts.packages` on these hosts, so the tab text has a font
without adding one.

For colours, follow the rule the module header sets out — *matugen only ever owns
a separate `colors.*` file*. Concretely: add `$hy3_tab_active`,
`$hy3_tab_active_border`, `$hy3_tab_inactive`, `$hy3_tab_text`, `$hy3_tab_urgent`
(etc.) as **variables** to `hyprTemplate`, derived from the same Material You
roles the borders already use (`primary` / `outline_variant` / `on_surface` /
`error`), and reference those variables from `plugin.hy3.tabs.colors` in the
HM-owned settings.

Variables rather than a `plugin { hy3 { ... } }` block inside `colors.conf`, for
two reasons: it keeps every `plugin:` key in the one file Step 1 actually
verifies, and it keeps matugen ignorant of hy3's schema. The alternative — a
full colours block in the template, matching how `general { col.active_border }`
is done today — is more consistent-looking but doubles the parse-order surface.

hy3's tab colour keys are `plugin:hy3:tabs:colors:{active, active_border,
active_text, focused, focused_border, focused_text, inactive, inactive_border,
inactive_text, urgent, urgent_border, urgent_text, locked, ...}`. Note tabs
default to `blur = true`, which the `decoration.blur` block here already
enables — consistent with the `caelestia-*` layerrules.

### 5. Rollout

Deploy in this order, and it matters:

1. **`g14`** — laptop, and Plasma is still in the SDDM session list. If hy3
   wedges the session, log into KDE and fix it.
2. **`blac`** — same KDE fallback.
3. **`z14` last.** There is *no* KDE on z14 (`desktop = "hyprland"` in
   `lib/registry.nix`); Hyprland is the only session, and the login screen is
   greetd/tuigreet rather than SDDM (`modules/desktop.nix`). A layout that
   fails to load here leaves one session entry that does not come up. It is
   not a lockout — tuigreet is a text UI on VT1, so `Ctrl+Alt+F2` gets a TTY —
   but the fix is then `git revert` + `deploy z14` from that TTY, or booting
   the previous generation from the boot menu.

Each host flips `noughty.hyprland.layout = "hy3"` in its registry entry / host
module. `deploy <host>` per `nixconfig-ops`.

### 6. Housekeeping (separate commit)

Delete the unused `hyprland` flake input at `flake.nix:47` and its `flake.lock`
nodes. It is not hy3's business, but it is the thing most likely to mislead the
next person who reads hy3's install docs against this repo.

## Open decisions

- **Keep the `layout` option after rollout, or inline hy3?** Recommendation:
  keep it. It costs ~6 lines, it is the whole rollback story for z14, and this
  module already carries options at exactly this granularity (`scale`,
  `colorMode`, `colorScheme`). Alternative: once all three hosts have run hy3
  for a while, drop the option and the dwindle branch.
- **Autotile on or off?** Recommended **on** with `trigger_width = 800` /
  `trigger_height = 500` — hy3 defaults it off, but off means every single split
  is manual, which is a big step down from dwindle for casual use. The trigger
  sizes mean "only auto-split when the node is big enough to be worth splitting."
  Alternative: `enable = false` for strict i3 behaviour.
- **Bindings.** The table above is a proposal, not a constraint. The required
  swaps in the first table are not optional; the second table is taste.
- **`configType`.** Staying on `hyprlang` unless Step 1 forces the change. Named
  here because if Step 1 goes badly it is a much larger change than the rest of
  this plan combined, and that is worth knowing before starting.

## Risks / rollout

- **Plugin fails to load silently** — the classic symptom of an ABI mismatch.
  Should not happen here (nixpkgs builds hy3 against the same `pkgs.hyprland`),
  but check with `hyprctl plugin list` and `journalctl --user -u hyprland-session`.
- **Config parse errors** — mitigated by Step 1's `--verify-config` gate, which
  is cheap and catches this before a deploy.
- **A Hyprland bump desyncs the pair.** Both come from the same nixpkgs input,
  so `pkgs.hyprland` and `pkgs.hyprlandPlugins.hy3` move together — this is
  precisely the failure mode the README's flake-input route would have created.
  Still worth a `hyprctl plugin list` after any nixpkgs bump.
- **Caelestia** should be unaffected: it is layer-shell, hy3 tabs are window
  decoration, and the `layerrule` blur rules target `caelestia-*` namespaces.
  Untested in combination, so it is on the list to eyeball on g14 first.
- **Back out:** `noughty.hyprland.layout = "dwindle"` and `deploy <host>`.
