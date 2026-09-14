# hy3 — i3/sway tiling layout for the Hyprland session

**Repo(s):** nixconfig   **Status:** done — hy3 is the default on all three Hyprland hosts

## Where this stands

**Live on all three hosts.** `noughty.hyprland.layout` defaults to `"hy3"`, and
blac / g14 / z14 are the complete set of hosts carrying the `"hyprland"` tag.
The option remains as the rollback — set a host to `"dwindle"` and it is back on
stock Hyprland with the native tabbed groups, byte-for-byte the config it had
before hy3 existed.

Corrections to what this plan originally said, all found by measuring:

- **Step 1's three predicted outcomes were all wrong**, and so was the thing it
  predicted would break. `general:layout = hy3` and the whole
  `plugin { hy3 { … } }` block parse fine before the plugin loads. It is the
  **binds** that hard-fail (`Invalid dispatcher, requested "hy3:movefocus"
  does not exist`), and an unresolved bind is *dropped*, not deferred. The fix
  is the plan's own fallback 1 — but chained into the same command as the load
  (`hyprctl plugin load … && hyprctl reload config-only`), because two separate
  `exec-once` entries are ordered by spawn only. `configType` stays `hyprlang`;
  the lua escape hatch was not needed.
- **`exec-once` does not cover a rebuild.** This one was found by living it, not
  by reading, and it is the failure most likely to recur. See "The rebuild gap"
  below.
- **hy3 is no longer the only tabbing story.** Commit `0182324` landed
  Hyprland's *native* tabbed/stacked groups on alt-comma, from a branch that
  ran in parallel with this plan and was merged the same day — neither
  supersedes the other. So the dwindle branch is kept intact rather than being
  dead weight, and alt-comma means "accordion" under both layouts.
- The colour decision in Step 4 was reversed; see that step.

## The rebuild gap

`exec-once` runs at session start and **does not re-run on `hyprctl reload`** —
that is by design, not a bug. So rebuilding while already logged into Hyprland
produces a session that has the new config but not the plugin:

- Home Manager's `onChange` reload re-parses the config;
- `general:layout = hy3` is accepted, because an unregistered layout is not an
  error (Step 1);
- every `hy3:` bind is rejected and **dropped**.

Observed symptom: a persistent config-error banner listing
`Invalid dispatcher, requested "hy3:movefocus" does not exist`, `hyprctl plugin
list` reporting **"no plugins loaded"**, zero hy3 binds, and a compositor that
is otherwise perfectly healthy. It looks like the plugin is broken. It is not —
it was simply never loaded into that session.

Fixed by `home.activation.hyprlandHy3Plugin`, which loads the plugin into any
running instance and then reloads so the binds register. It runs after
`writeBoundary`, i.e. after HM's own onChange reload, so the ordering is
load-then-reload. Both calls are safe to repeat — a second load is refused with
`Cannot load a plugin twice!` and exit 0.

**To fix such a session by hand** (no logout needed):

```
hyprctl plugin load /nix/store/…-hy3-0.55.0/lib/libhy3.so
hyprctl reload config-only
hyprctl plugin list      # expect: Plugin hy3 by outfoxxed
hyprctl binds | grep -c hy3:   # expect: 28
```

## Goal

Offer [hy3](https://github.com/outfoxxed/hy3) as an alternative layout for the
Hyprland session (`modules/hyprland.nix`): explicit i3/sway-style split nodes
instead of dwindle's automatic halving, plus hy3's tabbed groups. Originally
written as "replace dwindle"; it landed as an opt-in option instead, because
the native tabbed groups arrived in parallel and cover the accordion case
without a plugin.

The point is predictability: with dwindle, where a new window lands depends on
the focused window's aspect ratio; with hy3 you say where the split goes and it
stays there.

Additive in the same way the Hyprland session itself is additive: hy3 is a
compositor plugin, KDE is untouched, the dwindle path is byte-identical to what
it was, and backing it out is flipping one option.

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
  `dwindle:pseudotile` and `windowrule` grammar notes) -- which is what made
  this look dangerous. Step 1 measured it, and the guess above is wrong in both
  directions: the layout name and the `plugin:` keys are fine, the binds are
  not. See Step 1.
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

Land it behind an option, smallest slice first. All four phases are done.

**Phase 1 — make hy3 loadable and provable.** ✅ Plugin, the
`noughty.hyprland.layout` enum, and the layout/keybind/plugin-config changes
gated on it. Nothing changes for anyone until a host opts in. Parse order
proven with `Hyprland --verify-config` before any deploy.

**Phase 2 — bindings.** ✅ Required dispatcher swaps, plus the group bindings
— reusing `ALT, COMMA` rather than the new keys this plan first proposed.

**Phase 3 — theming.** ✅ Tab colours in the matugen pipeline, so tabs follow
the wallpaper like every other surface. Gated on the layout.

**Phase 4 — rollout.** ✅ Shipped to all three hosts at once, as the default
rather than per-host opt-in. The option stays (see Open decisions) -- it is the
rollback, and the dwindle branch it selects is not dead code.

## Steps

### 1. Prove the load order — DONE, and the answer was none of the three

Run against `Hyprland --verify-config -c <candidate>`, this is what 0.55.4
actually does. The prediction below was wrong in a way worth keeping on the
page, because the wrong half is the half people assume:

| config | verdict |
|---|---|
| `general:layout = hy3` with no plugin loaded | **fine.** Unregistered layout names are accepted and picked up when the plugin registers. |
| the whole `plugin { hy3 { … } }` block | **fine.** `plugin:` is a free-form bucket; unknown subkeys are tolerated. |
| `bind = …, hy3:movefocus, l` | **hard error.** `Invalid dispatcher, requested "hy3:movefocus" does not exist` — and the bind is *dropped*, not deferred. |

So the hazard is entirely in the binds, and the fix is fallback 1 with one
correction: the reload has to be **chained into the same command** as the
load —

```
exec-once = <hyprctl> plugin load <libhy3.so> && <hyprctl> reload config-only
```

— not a second `exec-once` line. Separate entries are ordered by *spawn* only,
so a standalone reload can re-parse before the load has finished registering
the dispatchers. `config-only` avoids re-running monitor detection, which is
what Home Manager's own onChange reload uses too.

Consequences worth knowing:

- `configType` stays `hyprlang`. The lua escape hatch was not needed. (It is
  real if it ever is — `hl.plugin.load` is in 0.55.4's
  `share/hypr/stubs/hl.meta.lua`.)
- Home Manager's `wayland.windowManager.hyprland.plugins` option is **not**
  used, because it emits the bare `hyprctl plugin load` line with nothing to
  sequence a reload after it. The module names the `.so` path directly instead
  — the same `$out/lib/lib<pname>.so` that option would have derived.
- Without the chained reload the session would still come up (config errors are
  reported, not fatal), but with every hy3 bind missing until the next
  wallpaper rotation's `hyprctl reload` — up to `wallpaperInterval` seconds.
  That is the "free repair mechanism" in Findings; it is a fallback, not the
  design.
- `--verify-config` on the *generated* hy3 config still prints those dispatcher
  errors, because it cannot load plugins. That is expected. The check that
  matters is "zero **non**-dispatcher errors", which it passes.

### 2. Plugin + option — DONE

`noughty.hyprland.layout` (enum `"dwindle"` | `"hy3"`, default `"dwindle"`) in
the NixOS half; the home half reads it off `osConfig` like `scale` and
`colorMode` already do.

Differences from the sketch this plan started with:

- **Not** `wayland.windowManager.hyprland.plugins` — see Step 1.
- The `dwindle` block is gated as planned, and so are the `group` block,
  `binds:movefocus_cycles_groupfirst` and the sourced `groupbar-mode.conf`,
  which the plan predates.
- Both layouts' settings live in one `layoutSettings` binding merged into
  `settings` with `//`. It is a plain `if`, **not** `lib.mkIf`: Home Manager's
  `settings` is a value type, not a submodule, so a nested `mkIf` is never
  resolved — it would reach `toHyprconf` as an attrset with `_type = "if"` and
  be rendered into the config file verbatim.
- `group_inset` at 6 rather than hy3's default 10 (see Step 4).

**Regression evidence.** On the dwindle path the generated `hyprland.conf`
comes out at the *identical store path* as before the change, and the matugen
template contains no hy3 text at all. The `groupBinds` list is spliced at the
original position in the bind list rather than appended, purely to keep that
byte-identity. So a dwindle host is provably unaffected.

### 3. Bindings — DONE

All eight hy3 dispatchers bound here were confirmed present in `libhy3.so`
(`strings libhy3.so | grep '^hy3:'`).

**Required swaps** — existing keys keep their meaning, only the dispatcher
changes:

| Key | dwindle | hy3 |
|---|---|---|
| `ALT` + H/J/K/L | `movefocus, l/d/u/r` | `hy3:movefocus, l/d/u/r` |
| `ALT SHIFT` + H/J/K/L | `movewindoworgroup, l/d/u/r` | `hy3:movewindow, l/d/u/r` |
| `SUPER` + Q | `killactive` | `hy3:killactive` |
| `ALT SHIFT` + Q/W/E/A/S/D/U/I/O | `movetoworkspace, N` | `hy3:movetoworkspace, N` |

That last one is `workspaceBinds` — the `movetoworkspace` half of the `imap1`,
not the `workspace` half.

**`movewindoworgroup` is the trap in that table.** The dwindle side does *not*
use plain `movewindow`: it uses `movewindoworgroup`, so the same four keys also
move windows in and out of the native tab groups. Deriving it through a generic
`"hy3:" + name` swap silently drops the `orgroup` half and breaks that on the
dwindle path — caught only by diffing the generated config against main's. It
is spelled out explicitly in the module for that reason.

**Group bindings.** The plan originally proposed `ALT, R` / `ALT, T` for these.
Superseded: the native-groups work took `ALT, COMMA` for "accordion" (the
literal AeroSpace key), so hy3 **keeps that key** and the muscle memory
survives the switch. `ALT SHIFT, COMMA` was "tabbed vs stacked" under the
native groupbar; hy3 has no stacked mode, so it is reused for the other half of
AeroSpace's layout pair.

| Key | dwindle | hy3 |
|---|---|---|
| `ALT, COMMA` | `togglegroup` | `hy3:changegroup, toggletab` |
| `ALT SHIFT, COMMA` | exec `toggleGroupbarMode` | `hy3:changegroup, opposite` (flip split axis, AeroSpace `alt-slash`) |
| `ALT, N` / `ALT SHIFT, N` | — | `hy3:makegroup, h` / `, v` (i3 `split h`/`split v`) |
| `ALT, P` / `ALT SHIFT, P` | — | `hy3:changefocus, raise` / `lower` (i3 focus parent/child) |
| `SUPER, Tab` / `SUPER SHIFT, Tab` | — | `hy3:focustab, r` / `l` |
| `ALT, X` / `ALT SHIFT, X` | — | `hy3:expand, expand` / `base` |

`SUPER, Tab` exists under hy3 but not dwindle because dwindle gets tab-cycling
for free from `binds:movefocus_cycles_groupfirst`, which hy3 has no equivalent
for.

The keyboard caveat still stands for the *additions* — letters, not
punctuation: the layout is `ch`/`de_nodeadkeys`, where `/` is Shift+7. `COMMA`
is safe because it is unshifted there.

`bindm` (`SUPER` + mouse drag) needs no change — it is float-drag, not a tiling
dispatcher.

Under hy3 the native `group` block, `binds:movefocus_cycles_groupfirst`, the
`dwindle` block and the sourced `groupbar-mode.conf` are all dropped from the
generated config: hy3 draws its own tabs, and the module does not carry dead
config for the layout that is not in use.

Full dispatcher list for later additions: `hy3:equalize`, `hy3:locktab`,
`hy3:setswallow`, `hy3:setephemeral`, `hy3:warpcursor`, `hy3:togglefocuslayer`,
`hy3:debugnodes`.

### 4. Tab config and theming — DONE, with the colour decision reversed

Shipped config (`plugin.hy3`): `group_inset = 6` (deliberately below hy3's
default of 10 — it stacks on `general:gaps_in = 8`, and 10 makes grouped nodes
read as noticeably airier than the same windows under dwindle), tabs at
`height 20 / padding 6 / radius 6 / border_width 2`, `render_text = true` in
`JetBrainsMono Nerd Font` at `text_height 11` to match the native groupbar, and
`autotile` on with `trigger_width 800` / `trigger_height 500`.

**Key names come from the plugin binary, not the README** —
`strings libhy3.so | grep plugin:hy3`. Two traps this caught:

- it is `plugin:hy3:tabs:**radius**`, not `rounding` (hy3 does not follow
  Hyprland's own `decoration:rounding` spelling);
- the colours are a nested `tabs { colors { … } }` section — `colors:active`,
  `colors:active_border`, … — not Hyprland's `col.` prefix.

**The colours go in the matugen template after all**, i.e. the alternative this
plan originally rejected. The reason the original argument missed: the seeding
activation in `modules/hyprland.nix` writes an **empty** colours file when no
wallpaper is readable, and an undefined hyprlang variable is a hard error —
verified: `Error parsing gradient $x: failed to parse $x as a color`. Emitting
`$hy3Tab*` variables from matugen and referencing them from hyprland.conf would
therefore turn "no wallpaper yet" into "session config is broken". With the
keys living in the generated file instead, an empty file just leaves hy3 on its
own defaults and the session comes up.

This also makes hy3 consistent with how `general` and `group` already work in
this module, which is the stronger argument in hindsight: matugen owns colour,
hyprland.conf owns behaviour, and no file references a variable the other might
not have defined.

Roles mirror the native groupbar's on purpose, so a hy3 tab and a groupbar tab
are the same surface in the same scheme: `primary`/`on_primary` active,
`secondary` for the focused-but-not-active tab, `surface_container` +
`outline_variant` inactive, `error`/`on_error` urgent. The block is gated on
the layout, so a dwindle host's colours file gains no hy3 text at all.

### 5. Rollout — DONE

Shipped to all three hosts at once by flipping the module default, rather than
the staged g14 → blac → z14 order this plan proposed. That order existed to
keep a KDE fallback available while hy3 was unproven; by the time it shipped,
the config had been verified against the compositor's own checker on all three
hosts and the plugin's ABI match confirmed by store-path reference, so the
staging bought little.

z14 remains the host with no fallback session (`desktop = "hyprland"` since
`76625c3`, greetd/tuigreet rather than SDDM). If it ever fails to come up:
`Ctrl+Alt+F2` for a TTY, then set `noughty.hyprland.layout = "dwindle"` and
rebuild, or pick the previous generation from the boot menu.

**What to check after a rebuild**, in this order, because each explains the
next:

```
hyprctl plugin list            # "Plugin hy3 by outfoxxed" -- if "no plugins
                               # loaded", see The rebuild gap above
hyprctl getoption general:layout
hyprctl binds | grep -c hy3:   # expect 28
journalctl --user -u hyprland-session -b
```

The failure mode to recognise is **"hy3 tiles nothing and the alt-keys are
dead, with an error banner"** — that is dropped binds from a session that never
loaded the plugin, not a broken plugin. It is the rebuild gap, and the
activation step now handles it; the manual repair is two commands.

Note that `g14`, `blac` and `z14` are **not** deploy-rs nodes — the registry
says laptops are "deploy clients rather than deploy targets", and none of the
three sets `deploy.hostname`. There is no `deploy <host>` for this change;
these hosts are rebuilt locally.

### 6. Housekeeping (separate commit)

Delete the unused `hyprland` flake input at `flake.nix:47` and its `flake.lock`
nodes. It is not hy3's business, but it is the thing most likely to mislead the
next person who reads hy3's install docs against this repo.

## Open decisions

- **Does hy3 earn its place next to the native groups?** This is now the real
  question, and it cannot be settled on paper — it needs one host running it.
  The native-groups commit argues hy3 adds nothing the Mac layout wants, and
  that is true *for the accordion*. What hy3 adds is the rest of the i3 tree:
  explicit split containers (`hy3:makegroup`), focus-parent/child, and window
  placement that does not depend on the focused window's aspect ratio. It is
  now running on all three hosts, so the evidence is being gathered. If after a
  week you only ever reach for alt-comma, the honest answer is to set the
  default back to "dwindle" and keep the native groups -- that branch is still
  there, intact, for exactly this.
- **Keep the `layout` option now that hy3 is the default?** Yes -- it is the
  whole rollback story for z14, which has no second session, and the module
  already carries options at this granularity (`scale`, `colorMode`,
  `colorScheme`). It is also what keeps both answers to the question above
  cheap. Note the dwindle branch it selects is not dead code: it still carries
  the native tabbed groups.
- **Autotile on or off?** Shipped **on** (`trigger_width = 800` /
  `trigger_height = 500`). hy3 defaults it off, but off means every split is
  manual, a big step down from dwindle for casual use. Flip to
  `enable = false` for strict i3 behaviour.
- **`configType`.** Settled: stays `hyprlang`. Step 1 did not force the change.

## Risks / rollout

- **Dropped binds, not a dead plugin, is the failure mode to expect.** Hy3
  tiles nothing, the alt-keys are dead, and a config-error banner lists
  `Invalid dispatcher`. Two causes: the chained `hyprctl reload config-only`
  regressing (Step 1), or -- far more likely -- a rebuild into a session that
  predates it, which is The rebuild gap above. Check `hyprctl plugin list`
  first; "no plugins loaded" distinguishes them immediately.
- **Plugin fails to load silently** — the classic ABI-mismatch symptom. Should
  not happen: `pkgs.hyprlandPlugins.hy3` 0.55.0 references the very same
  `pkgs.hyprland` 0.55.4 store path the session runs (checked with
  `nix-store -q --references`), and it substitutes from cache.nixos.org rather
  than building. Confirm with `hyprctl plugin list`.
- **Config parse errors** — gated by `--verify-config`, which is cheap. Note
  that on a *generated hy3 config* it will always report the dispatcher errors,
  because it cannot load plugins; the meaningful check is zero **non**-dispatcher
  errors.
- **A Hyprland bump desyncs the pair.** Both come from the same nixpkgs input,
  so the two move together — precisely the failure the README's flake-input
  route would have created. Still worth a `hyprctl plugin list` after a bump.
- **An empty colours file is survivable**, and deliberately so — see Step 4.
  This is why the tab palette is not referenced as `$variables`.
- **Caelestia** should be unaffected: it is layer-shell, hy3 tabs are window
  decoration, and the `layerrule` blur rules target `caelestia-*` namespaces.
  Untested in combination — eyeball it on g14 first.
- **Back out:** set `noughty.hyprland.layout = "dwindle"` (the module default,
  or per host) and rebuild -- these are not deploy-rs nodes. The dwindle config
  is byte-identical to what it was before hy3 existed, so backing out is
  genuinely a no-op rather than an approximation.
