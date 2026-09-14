# caelestia-shell

**Repo(s):** nixconfig   **Status:** done — landed on `main`; the hosts still
need a local `nixos-rebuild switch` (see Risks / rollout).

## Goal

Replace the hand-written Quickshell bar (`quickshellConfig` in
`modules/hyprland.nix`) with **Caelestia**, an existing, good-looking community
Quickshell shell. The hand-rolled bar works and hides correctly, but it looks
plain; the user asked to borrow someone else's rather than keep hand-styling
ours.

Caelestia was chosen over the alternatives despite being the *harder* Nix fit,
because the user explicitly asked to try it. What the survey found:

- **DankMaterialShell** is the easier adoption — already in nixos-26.05 as
  `programs.dms-shell`, runs on our pinned quickshell 0.3.0, no new input. Kept
  as the fallback if this goes badly.
- **Noctalia** is no longer a Quickshell shell at all (v5 is a C++/Wayland
  rewrite, TOML-configured), so it is out of scope.
- **end-4 / illogical-impulse** exports a whole Home Manager *configuration*
  rather than a reusable module. Unusable as a component.

## Approach

### The quickshell version problem, and why it is smaller than it looked

Caelestia requires quickshell from git, not our pinned 0.3.0. The worry was a
from-source Qt6 build. Measured rather than assumed — `nix build --dry-run` on
`github:caelestia-dots/shell#default`:

```
these 7 derivations will be built
these 654 paths will be fetched (980.4 MiB download, 3.6 GiB unpacked)
```

The 7 are `quickshell-0.3.1`, its wrapper, `cpptrace`, `m3shapes`,
`caelestia-qml-plugin`, `caelestia-extras`, `caelestia-shell`. Everything
else — Qt6 included — substitutes from `cache.nixos.org`. The pinned git rev is
**0.3.1**, a tagged release, not some far-flung master.

And the build does not land on the laptop: **g14 is already a `builder-client`**
(`/etc/nix/machines` has both `nixremote@100.64.0.2` entries), so the compile
offloads to 205-builder without any config change. Verified in the build log:
`building '/nix/store/…-quickshell-0.3.1.drv' on 'ssh://nixremote@100.64.0.2'`,
with 205 at load 16 on 11 `cc1plus` processes.

There is also a public `quickshell.cachix.org`
(`quickshell.cachix.org-1:vBm3s5tZThc5KDLj6zhHVCMp8wX/AZJwle9wqdi81ts=`). Not
used yet — only root is a trusted user here, so it has to be added declaratively
to be worth anything. Optional follow-up, not needed given the builder.

### Flake input: deliberately NOT following our nixpkgs

`inputs.caelestia.inputs.nixpkgs` stays on caelestia's own lock. Following our
nixpkgs would change every derivation hash and throw away the 654 cached paths
measured above, forcing a much larger rebuild against 26.05's Qt6 — and risking
breakage, since upstream only tests against its own pin. This repo already has
the precedent and the convention of documenting it: `mac-app-util` is
deliberately not following, with the reason written down.

The cost is a second nixpkgs in the flake and a second Qt6 in the closure. That
is the price of borrowing someone else's shell, and it is worth stating plainly.

### What Caelestia insists on owning, and what it gives back

Caelestia is a whole desktop, not a bar. Every claim below is from reading its
source, not its README:

| Concern | Verdict |
|---|---|
| **Bar hide/reveal** | `bar.persistent = false` + `bar.showOnHover = true`. Both are real properties in `plugin/src/Caelestia/Config/barconfig.hpp`. This is the feature we would otherwise be hand-writing. |
| **Wallpaper** | Would draw its own — `background.wallpaperEnabled` defaults **true**. Set it false and `Background.qml` puts the layer on Bottom with `color: "transparent"`, so swww shows through untouched. |
| **Idle / lock** | Ships `IdleMonitors` with a default 180s→lock, 300s→dpms, 600s→suspend. Set `general.idle.timeouts = []` and `lockBeforeSleep = false` to hand idle back to hypridle/hyprlock. |
| **Notifications** | **No toggle.** `modules/ServiceLoader.qml` force-loads `Notifs` unconditionally (contrast `VPN`, which *is* gated on `GlobalConfig.utilities.vpn.enabled`), and `services/Notifs.qml` creates a `NotificationServer`. It will claim `org.freedesktop.Notifications`. |
| **Launcher / lock screen** | Only appear on keybind. rofi and hyprlock keep their existing binds; nothing collides. |

**So mako has to go.** Two daemons cannot both hold the notification bus name,
and leaving both enabled makes it a start-order race — the worst outcome, since
it would work until it didn't. mako is disabled deliberately and Caelestia owns
notifications. This deletes a working, well-commented chunk of config, which is
the single biggest cost of this change and is one `git revert` away.

### Colours: the existing matugen pipeline keeps working

The nicest finding. `services/Colours.qml` reads
`~/.local/state/caelestia/scheme.json` through a `FileView` with
`watchChanges: true` and `onFileChanged: reload()` — structurally identical to
what our own bar already did. The format is:

```json
{ "name": "...", "flavour": "...", "mode": "dark", "colours": { "primary": "aabbcc", … } }
```

Colour keys are Material 3 names and the values are hex **without** a leading
`#` (the loader prepends it) — which is exactly matugen's `hex_stripped`. So
this is one more matugen template, and swww + the rotation timer + every other
template stay exactly as they are. Caelestia's own `caelestia scheme set` engine
is simply never invoked.

Caveat: custom named schemes are not an officially supported feature upstream
(issues #240 / #103), so writing this state file directly is undocumented
surface that could change between releases. Accepted knowingly; the fallback is
letting `caelestia-cli` own colours instead.

## Steps

1. `flake.nix`: add the `caelestia` input, no `nixpkgs.follows`, with the reason
   recorded next to the `mac-app-util` precedent.
2. `modules/hyprland.nix`: import `caelestia.homeManagerModules.default`; add
   `programs.caelestia` with `systemd.target = "hyprland-session.target"` and the
   settings above.
3. Remove the hand-written bar: `quickshellConfig`, `quickshellTemplate`,
   `generated.quickshell`, `programs.quickshell`, and the `quickshell-bar`
   layerrule.
4. Add the `scheme.json` matugen template + `generated.caelestia` path.
5. Disable mako and drop its template, generated path and reload hook.
6. Add Hyprland layerrules for the `caelestia-*` namespaces (blur +
   `ignore_alpha`), in the 0.55 `match:` grammar.
7. Verify: all three hosts evaluate, `Hyprland --verify-config` passes, the
   shell starts against the live session and the bar reveals on hover.

All done. What verification actually turned up:

- **The mako conflict is confirmed empirically, not just by reading.** Running
  the shell against the live session while mako was still up logged
  `Could not register notification server at org.freedesktop.Notifications,
  presumably because one is already registered.` It degrades to a warning and
  retries rather than crashing — which is precisely the failure mode that made
  leaving both enabled a bad idea, since it would look fine and silently drop
  one side's notifications.
- **`Configuration Loaded`** with our generated `shell.json` — the settings are
  accepted as written.
- The matugen template was rendered for real against a wallpaper: valid JSON,
  **37 colour keys, zero unresolved placeholders**, values bare hex. The keys I
  was least sure existed (`scrim`, `surfaceContainerLowest`, `inverseOnSurface`)
  all resolve.
- **New behaviour worth knowing: `hyprctl monitors` reports
  `reserved: 10 10 10 10`.** That is Caelestia's screen-border feature
  (`border.thickness`, default 10), not the bar — the bar itself reserves
  nothing, as intended. It is part of the rounded-screen look, but it does mean
  windows no longer go edge to edge. `settings.border.thickness = 0` removes it
  if that is unwanted.
- The wallpaper daemon (`awww-daemon`) is unaffected and `caelestia-background`
  sits on the Bottom layer, as `wallpaperEnabled = false` promises.

## Open decisions

- **mako removal** is the one genuinely destructive step. Recommendation: do it,
  because the alternative is a nondeterministic bus race. Alternative: abandon
  Caelestia and take DankMaterialShell — but DMS has exactly the same
  notification conflict, so this cost is not specific to Caelestia.
- **Second nixpkgs / Qt6 in the closure.** Accepted, for the cache reasons above.
- **Keeping our bar as a fallback** is not viable: two bars, two quickshells.
  The hand-written one stays recoverable in git (`1201b63`).

## Risks / rollout

- Not deployable from this session (laptops are not deploy-rs targets and sudo
  needs a password). Closure is pre-built so the switch is activation-only.
- Caelestia is a personal-dotfiles-adjacent project: config keys can be renamed
  between releases, and the input is pinned, so a flake update could break the
  bar. The pin is the mitigation.
- Back out with `git revert` — that restores mako, the hand-written bar and the
  matugen templates together.
