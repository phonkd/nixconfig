# hyprland-lua-config

**Repo(s):** nixconfig   **Status:** draft
**Hosts:** blac, g14, z14 (every `hyprland`-tagged host at once)

## Goal

Move the Hyprland configuration off hyprlang and onto Hyprland's Lua config,
which is where upstream is going: 0.55.4 ships `share/hypr/hyprland.lua` and
`share/hypr/stubs/hl.meta.lua`, and Home Manager's `configType` already
*defaults* to `"lua"` for `stateVersion >= 26.05`. This repo pins
`"hyprlang"` explicitly in `modules/hyprland/_compositor.nix:52`, with a note
saying it is "one line to change later". It is not one line; this plan is what
that line actually costs.

## What is actually involved

Counted from the generated `~/.config/hypr/hyprland.conf` on z14, not from the
Nix (most of the 2860 lines under `modules/hyprland/` are comments, matugen
templates, systemd units and activation scripts, and none of those change):

| surface | count | becomes |
|---|---|---|
| `bind` / `bindel` / `bindl` / `bindm` | 68 | `hl.bind("SUPER + Q", hl.dsp.exec_cmd(...), opts)` |
| `windowrule` / `layerrule` | 6 | `hl.window_rule{...}` / `hl.layer_rule{...}` |
| `env` / `exec-once` | 9 | `hl.env(k, v)` / `hl.on("hyprland.start", ...)` |
| `general` / `decoration` / `input` / … | — | `hl.config{...}`, generated from Nix `settings` for free |
| `source` | 4 | **no equivalent** — see below |

Two things make this a rewrite rather than a reserialisation:

1. **Binds are structural, not stringly.** hyprlang takes
   `"$mod, Q, exec, kitty"`. Lua takes a key string in `+` form and a *typed
   dispatcher*: `hl.bind("SUPER + Q", hl.dsp.exec_cmd("kitty"))`. Home
   Manager renders a plain string setting as a single-argument call
   (`lib.nix:renderCall`), i.e. `hl.bind("$mod, Q, exec, kitty")`, which does
   not match `hl.bind(keys, dispatcher, opts?)` in the stubs. Every bind has
   to be restructured, whether into Nix `_args`/`mkLuaInline` attrsets or into
   hand-written Lua.

2. **`source` is gone.** The Lua config splits with `require()`, and each
   `require` is deliberately its own Lua scope. `require` resolves relative to
   `hyprland.lua`. There is no `hl.source`; the stubs have no such call.

## The real problem: four runtime-written files

All four `source` lines in `_compositor.nix` point at files that something
*other than Nix* rewrites while the session is running, and that `hyprctl
reload` is expected to pick up:

- `colors.conf` — matugen, on every wallpaper change
- `monitors.conf`, `workspaces.conf` — nwg-displays, when the user saves a layout
- `groupbar-mode.conf` — written by the groupbar toggle keybind itself

Under Lua these have to become Lua that gets `require`d (or `dofile`d). The
open question is whether a reload re-reads them: standard Lua `require`
memoises in `package.loaded`, so if Hyprland reuses the Lua state across a
reload, a regenerated colours file would be ignored until the compositor
restarts. `dofile` sidesteps the cache if so.

**This is the one thing that must be settled before any code is written**, and
it cannot be settled from the stubs — it needs a live check on a scratch
config. It decides the shape of `_matugen.nix` and `_theming.nix` (~875 lines
between them), because the matugen templates stop emitting hyprlang variables
and start emitting Lua.

## Approach

Recommended: **hybrid** — let each language do what it is good at.

- **Nix keeps** the host-parameterised and store-path-bearing config: the
  `general` / `decoration` / `input` / `misc` blocks, monitor scale, the
  hy3-vs-dwindle switch, package and plugin wiring. These already map to
  `hl.config{...}` straight out of `settings`, with no restructuring.
- **Lua gets** what is awkward in Nix and natural in Lua: the 68 binds with
  typed dispatchers, the window/layer rules, and the groupbar-toggle logic.
  These live as real files under `modules/hyprland/lua/`, delivered through
  `extraLuaFiles`, exactly as `modules/code-editors/nvim/` now does for Neovim.
- **The bridge** is a small Nix-generated `hypr/host.lua` returning a table
  (scale, layout, mod key, binary paths, whether hy3 is active) that the
  hand-written Lua reads. Host differences stay in Nix; Lua stays host-agnostic.

Home Manager supports this directly: `extraLuaFiles` takes file paths, dotted
names map to subdirectories, `autoLoad` emits the `require` calls, and it
writes `hypr/.luarc.json` pointing lua_ls at Hyprland's own stubs — so the
hand-written Lua gets completion and type checking for the whole `hl` API.

## Steps

1. Settle the reload/caching question above on a scratch config. Nothing else
   starts until this is answered.
2. Redesign the colour pipeline: matugen templates emit Lua, not hyprlang
   variables. Rework `_matugen.nix` and the `hyprland-gtk-colors` /
   wallpaper units in `_theming.nix` accordingly.
3. Generate `hypr/host.lua` from `_scope.nix`.
4. Port the 68 binds from `_keybinds.nix` to `modules/hyprland/lua/binds.lua`
   with typed dispatchers; port the 6 rules.
5. Convert `env` / `exec-once`; drop the four `source` lines.
6. Flip `configType = "lua"`, delete the hyprlang-only scaffolding.
7. Build, then test on **g14 or blac first** — never z14 first, see Risks.

## Open decisions

- **Split of Nix vs Lua** (the Approach above). The alternative is keeping
  everything in Nix `settings` and restructuring the binds into
  `_args`/`mkLuaInline` attrsets. That preserves one source of truth, but
  produces Nix that is strictly uglier than today's for no gain — you end up
  writing Lua call syntax in Nix data. Recommended against.
- **`require` vs `dofile`** for the runtime-written files: decided by step 1.
- **Whether to keep nwg-displays at all.** Its whole contract is writing
  hyprlang that gets `source`d. If reload-safe Lua inclusion turns out not to
  work, the monitor layout may be better off generated into `host.lua` and
  nwg-displays dropped.

## Risks / rollout

- **This is the daily-driver desktop on three machines.** A broken config is a
  session that will not start, on the machine you would use to fix it.
- **It cannot be verified here.** `CLAUDE.md` forbids full evals, so the
  ceiling is `nix-instantiate --parse` plus Lua `loadfile`. Neither catches a
  wrong dispatcher name or a bind that silently does nothing — only running it
  does. Unlike the hyprlang split, there is no byte-identity argument
  available: this is a semantic translation.
- Roll out on **g14 or blac first**, keep a TTY and the previous generation
  handy, and only move z14 once a full session has been driven on another
  host. These are `kind = "computer"`, not deploy-rs nodes, so it is a local
  `nixos-rebuild switch --flake .#<host>` on each, not `deploy`.
- Back out by reverting the commit and rebuilding; the previous generation is
  still in the boot menu / `home-manager generations`.
