# quickshell-bar

**Repo(s):** nixconfig   **Status:** done — landed on `main`; the hosts still
need a local `nixos-rebuild switch` (see Risks / rollout).

## Goal

Replace the Waybar top bar in the Hyprland session with a small Quickshell bar
that **reveals itself when the pointer reaches the top edge of the screen** and
hides again shortly after it leaves. Two reasons, in order:

1. The user does not like the Waybar bar.
2. These are OLED panels. A permanently lit 34px strip of clock glyphs is the
   worst thing to leave on screen all day, and the keybind-driven peek added in
   `d23f7c8` answered the burn-in half but not the ergonomics — you have to
   remember a chord to see the time.

Hover-to-reveal answers both: nothing is drawn until you go looking for it, and
"go looking for it" is a mouse gesture rather than `Super+Shift+B`.

Scope is deliberately **minimal** — workspace pills, battery, clock. The old bar
carried twelve modules; most of them were never read at a glance, and a bar that
is hidden by default is the wrong place for a CPU graph. Waybar comes out
entirely; it is recoverable from git if Quickshell disappoints.

## Approach

### Why the reveal is expressible without a compositor hack

Verified against the **actual** `quickshell` 0.3.0 in our pinned nixpkgs — the
`.qmltypes` API dump in the store path, plus live runs against this g14 Hyprland
0.55.4 session. Version accuracy matters here: Quickshell's QML API moves between
releases and several things the web docs describe are not in 0.3.0.

A `PanelWindow` is a wlr-layer-shell surface. Three of its properties do the
whole job:

- `exclusionMode: ExclusionMode.Ignore` — reserves **no** screen space. This is
  not the default and the default will bite: an unset `PanelWindow` with three
  anchors is `ExclusionMode.Auto` and reserves `implicitHeight`. Confirmed live
  via `hyprctl monitors -j`: default → `"reserved": [0, 36, 0, 0]`, with
  `Ignore` → `"reserved": [0, 0, 0, 0]`.
- `mask: Region { item: … }` — limits which part of the window accepts pointer
  input. The window stays full bar height; input is confined to a 2px strip at
  the top until hovered, then expands to the full bar.
- `color: "transparent"` — the default is **white**, and an opaque window cannot
  become transparent later unless `surfaceFormat.opaque` is false. Set it
  declaratively from the start.

The reveal itself is a plain `MouseArea { hoverEnabled: true }`. This was run
end-to-end with the cursor driven by `hyprctl dispatch movecursor`: entering the
2px strip fires exactly one `entered`, the mask grows to full height, and moving
*within* the newly-grown region fires **no** spurious `exited` — no flicker at
the transition.

### The one trap

`proxywindow.cpp` sets `Qt::WindowTransparentForInput` when the mask resolves to
an **empty** region. A zero-height hidden strip therefore makes the window ignore
*all* pointer input and the hot zone can never fire — the bar becomes
unreachable. Confirmed live: strip height `0` produced nothing at the top edge;
growing it to `2` made the very next cursor move fire `entered`.

So the hidden strip is **2px, never 0**. The cost is that the top two rows of
pixels belong to the bar and not to the window underneath. That is the price of
an edge-triggered reveal and it is worth a comment in the module.

### Not drawing, vs. not existing

`visible: false` destroys the surface — nothing drawn, but also no input region,
so the reveal could never trigger. The window therefore stays `visible` with a
transparent background, and the *content* is what stops painting (`opacity: 0`,
`visible: opacity > 0`). A transparent layer surface emits no light of its own,
so there is no burn-in contribution: the panel shows whatever is behind it.

### Colours

Same matugen pipeline as every other consumer, one more template. Quickshell gets
a **JSON** file rather than a stylesheet, read by a `FileView` with
`watchChanges: true` and parsed with `JSON.parse`. Bindings across the bar then
update live, with no reload and no signal.

Two details that are easy to get wrong and are already accounted for:

- `FileView.text` is a **function** in 0.3.0 (`text()`), not a property, because
  of the `FileView.qml` wrapper.
- `watchChanges: true` only *watches*. The reload is not automatic — it needs
  `onFileChanged: reload()` wired explicitly. That is the documented idiom.

Quickshell's own QML hot-reload is irrelevant here and is left alone: it watches
only files under the shell directory, and ours is an immutable store path.

### What the built-ins cover

0.3.0 ships more than expected, so the minimal bar needs **no** subprocess
polling at all:

- `Quickshell.Hyprland` — `Hyprland.workspaces.values`, each with `id`, `focused`,
  `active`, `urgent`, `toplevels`, and an `activate()` method for click-to-switch.
- `Quickshell/SystemClock` — `date`, with `precision: SystemClock.Minutes` so it
  wakes once a minute rather than once a second.
- `Quickshell.Services.UPower` — `UPower.displayDevice.percentage` and `.state`.

Two gaps in 0.3.0 that shaped the design: workspaces have **no** `occupied`
property (derive it from `toplevels.values.length > 0`), and `UPowerDevice`
`percentage` is **0..1, not 0..100** — it needs multiplying, and getting this
wrong yields a bar permanently reading "0%".

### Wiring

`programs.quickshell` exists in our pinned home-manager and mirrors
`programs.waybar` closely enough that the module keeps its shape: `configs` (a
named config directory), `activeConfig`, and `systemd.{enable,target}`. The
target is pinned to `hyprland-session.target` for exactly the reason waybar's
was — the default is `graphical-session.target`, which Plasma reaches too, and
that would put the bar on top of the Plasma panel.

The workspace letters (`Q W E A S D U I O`) are already a Nix list driving the
keybindings. They get interpolated into the QML as a JS array so the pills and
the `Alt`-bindings cannot drift apart — the same parity the Waybar config had.

## Steps

1. Add the `quickshellTemplate` matugen template (JSON) and a
   `generated.quickshell` path; drop `waybarTemplate` and `generated.waybar`.
2. Write `shell.qml` as a `pkgs.writeTextDir`, with the palette singleton, the
   hover-reveal panel, and the three widgets.
3. Wire `programs.quickshell` (package, config, `hyprland-session.target`).
4. Remove Waybar: the `programs.waybar` block and its style, the
   `hyprland-waybar-peek` unit, the three `Super+…+B` keybinds, the waybar entry
   in the colour-seeding activation script, and the file-header rationale that
   explains why Waybar was chosen.
5. Verify: config evaluates on all three Hyprland hosts, the generated `shell.qml`
   parses, `Hyprland --verify-config` still passes, and nothing references waybar.

All five done. What the verification actually turned up, since some of it was
more useful than a green tick:

- `qmllint` flagged every `root.…` reference inside the `Variants` and `Repeater`
  delegates as **unqualified access** — it resolves through the context chain
  today and is exactly the kind of thing that stops resolving later. Fixed with
  `pragma ComponentBehavior: Bound`, which the delegates' existing
  `required property` declarations already satisfy. Clean afterwards.
- `qmllint` also reports `PanelWindow is not creatable`, and the qmltypes do say
  `isCreatable: false`. That one is a **false positive** — Quickshell substitutes
  the platform implementation at runtime. Confirmed by loading the real config:
  "Configuration Loaded", no errors.
- Ran against the live g14 Hyprland session: `hyprctl layers` puts the surface on
  **overlay level 3**, and `hyprctl monitors` reports `reserved: 0 0 0 0` — the
  `ExclusionMode.Ignore` claim is real and not just a property that was set.
- Drove the cursor with `hyprctl dispatch movecursor` to test the reveal for
  real: top edge → `revealed=true`, away → `revealed=false`, exactly one
  transition each way. Moving *down into* the grown mask produced no spurious
  exit, so there is no flicker to debounce.

## Open decisions

- **Reveal dwell.** A bar that pops the instant the cursor grazes the top edge is
  annoying when you are just reaching for a window's titlebar. Plan adds a short
  (~120ms) dwell before revealing and a ~500ms grace before hiding. Alternative:
  instant reveal. Easy to tune — two `Timer` intervals.
- **The 2px input strip** is load-bearing (see above) and does consume the top two
  pixel rows of pointer input. The alternative is a keybind reveal, which is what
  we are replacing. Recommendation: keep the strip.
- **Tray is dropped** along with the rest. `SystemTray` is available in 0.3.0 if
  it turns out to be missed — easily added later.

## Risks / rollout

- **Not deployable from this session.** The Hyprland hosts (`blac`, `g14`, `z14`)
  are not deploy-rs targets — `deploy --list` has only the homelab servers — and
  the local `nixos-rebuild switch` needs a sudo password this session cannot
  supply. The closure gets pre-built so the switch is an activation only.
- The bar only appears once Hyprland is re-entered, since the unit is bound to
  `hyprland-session.target`.
- Back out by reverting the commit: Waybar and its peek unit come back intact.
