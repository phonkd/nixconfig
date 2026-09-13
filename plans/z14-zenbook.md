# z14 — ASUS Zenbook 14 UM3406GA

**Repo(s):** nixconfig   **Status:** in-progress — everything below is on `main`; the local `nixos-rebuild switch` is the one step left

## Goal

The new ASUS laptop has been running `nixosConfigurations.g14` as a stopgap. Give
it its own host — `z14` — so its hardware is described truthfully instead of
borrowing a Zephyrus GA401's, and switch on the OLED settings its panel wants.

## What the machine actually is

Measured on the box itself, not assumed:

| | g14 (existing) | z14 (new) |
|---|---|---|
| Model | ASUS Zephyrus GA401 | ASUS Zenbook 14 UM3406GA |
| CPU | Intel/AMD + ROG firmware | AMD Ryzen AI 7 445 |
| GPU | Radeon iGPU **+ NVIDIA dGPU** | Radeon 840M only (`amdgpu`, 1002:1902) |
| Panel | LCD | **OLED** |
| Fingerprint | Goodix 27c6:521d | none |
| Root | — | LUKS ext4, dual-boot with Windows |

So "same as g14" holds for the *role* (KDE desktop laptop, gigaplayer client,
build-offload client, tailnet member) but not for the hardware. Everything in
`modules/hosts/g14/g14.nix` that is GA401-specific — the `nixos-hardware`
`asus/zephyrus/ga401` profile, every `hardware.nvidia.*` block, `nvidia-powerd`,
`rog-control-center`, the Goodix libfprint graft, the speaker-tuned EasyEffects
preset, the cpufreq-boost tmpfiles hack — is wrong here and is not carried over.

## Approach

1. **Registry entry** `z14` in `lib/registry.nix`: a copy of g14's role fields
   (`kde`, `laptop`, `gigaplayer-client`, `builder-client`, no `deploy.hostname`
   — laptops are deploy *clients*), with `gpu.vendors = [ "amd" ]`. That one field
   is what keeps `nvidia-desktop`'s config block off (it gates on
   `gpu.hasNvidia`) while still pulling in the shared desktop baseline, which
   reaches every host through that module's unconditional `imports`.

2. **Host module** `modules/hosts/z14.nix`, gated on `host.name == "z14"`. A
   single file, not a directory like `modules/hosts/g14/` — there is no preset
   JSON or driver patch to sit next to it. It is deliberately short: every
   generic thing `nixos-hardware`'s AMD-laptop profiles would set is already
   true in this config (checked by eval, not assumed — `fstrim`,
   `enableRedistributableFirmware`, `graphics.enable32Bit`, `upower`,
   `power-profiles-daemon` on and `tlp` correspondingly off, and the generated
   `hardware-configuration.nix` already carries `cpu.amd.updateMicrocode`).
   There is no `asus/zenbook/um3406` profile upstream to import anyway. What is
   left is genuinely host-specific:
   - `networking.hostName = "z14"`;
   - limine, matching g14 — it is what is already installed on this disk from
     the stopgap rebuild, so keeping it means no bootloader churn;
   - `amd_pstate=active`, the one thing `common/cpu/amd/pstate.nix` would
     contribute on a 6.18 kernel;
   - the AirPlay/avahi sender stack, carried from g14 because it is about the
     LAN's Sonos speakers, not about the GA401.

3. **OLED** — `noughty.kde.panelAutoHide = true`, the same reasoning as blac's
   (`modules/kde.nix`): the permanently-lit taskbar is the worst burn-in
   offender. The wallpaper slideshow, the other half of that story, is already
   on for every KDE host by default, so it needs no per-host line.

4. **Tailnet** — `modules/tailnet.nix` keys the exit-node client wiring and
   `--operator=phonkd` on `host.name == "g14"`. Both become a list membership
   test so z14 gets the same, and blac is left exactly as it is.

## Steps

- [x] `lib/registry.nix`: add the `z14` entry
- [x] `modules/hosts/z14.nix`: new host module
- [x] `modules/tailnet.nix`: extend the two g14-keyed branches to z14
- [x] Verify: build `nixosConfigurations.z14.config.system.build.toplevel` and
      diff its closure against the running (g14-shaped) system
- [x] Commit to `main`
- [ ] `sudo nixos-rebuild switch --flake ~/git/nixconfig#z14` on the laptop
      (needs a password, so it is the user's one command)

## Open decisions

- **g14 stays in the registry.** The old laptop is still a live tailnet node
  (`g14`, 100.64.0.9, last seen 4 days ago) while this machine is currently
  enrolled beside it as `g14-irpwhkmw`, so its config is not dead weight yet.
  If the GA401 is gone for good, deleting the entry plus
  `modules/hosts/g14/` is the follow-up — say so and it is a two-minute change.
- **Battery charge limit not carried.** g14 gets `hardware.asus.battery` via the
  ga401 profile, but its `chargeUpto` default is 100, i.e. a no-op. Skipped
  rather than reimplementing an upstream module for nothing; easy to add if a
  charge ceiling is actually wanted.

## Risks / rollout

- Not deploy-rs deployable (laptops set no `deploy.hostname`), so this lands via
  a local `nixos-rebuild switch` on the machine.
- The hostname change means headscale sees a new node name. This host is
  currently `g14-irpwhkmw` — a collision-suffixed name, because the real g14 is
  still registered — and will re-announce as `z14`. Its tailnet IP may change;
  nothing in this repo hardcodes a laptop's tailnet address.
- Back out by rebuilding `#g14` again; the flake still has that config.
