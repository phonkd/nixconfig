# Desktop config cleanup — trade features for readability

**Repo(s):** nixconfig   **Status:** in progress

Goal: fewer custom scripts/units/options in the Hyprland desktop, so the config
is readable and hand-editable. Matugen theming stays.

## Changes

- Remove unused/dead code: `ee-volume.nix` + `loudnessKnob`, the
  `noughty.hyprland.*` and `noughty.gui.*` options (no host sets them; become
  literals), monique workspace migration, `viewflow.nix` + input, niri and
  driftwm modules + inputs.
- Clipboard history and polkit agent: HM's `services.cliphist` and
  `services.hyprpolkitagent` instead of hand-written user units.
- Screenshots: grim/slurp piped into satty (config in `satty/config.toml`)
  instead of the grimblast `edit` wrapper.
- greetd: drop the `sessionsWithoutUwsm` filtered copy; point tuigreet at the
  stock session dir.
- Zen: flake package as-is, drop the `wrapFirefox` smooth-scroll rebuild.
- z14: drop the ollama service.

Out of scope: wluma, hy3/dwindle split, matugen pipeline.

## Verify

`nix build` both `blac` and `z14` toplevels, then `deploy z14` and `deploy blac`.
