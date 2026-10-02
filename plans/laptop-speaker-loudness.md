# Laptop speaker loudness ("make the z14 speakers sound good at any volume")

**Repo(s):** nixconfig (phase 1–2); possibly a small new repo for the phase-3 app
**Status:** draft — not started; user wants the plan only for now

## Goal

The z14 (and previously the g14) EasyEffects presets make the laptop speakers
sound much better — more bass, fuller — **at low volume**. But that only happens
when you lower the *source* volume (Spotify's own slider). Lowering the *system*
volume does nothing to the tone. The goal is one normal volume control (Super+M,
the media keys, the OSD) that gives the "good at low volume" sound automatically,
without hiding a second gain stage like last time.

## Why it behaves this way (measured, not guessed)

`~/.local/share/easyeffects/output/z14.json` (`g14.json` is the same shape) runs
`equalizer → crystalizer → multiband_compressor`. In the multiband compressor,
band 0 (below about 500 Hz) uses `compression-mode: Boosting`: upward
compression of up to +6 dB, below a −72 dB threshold, ratio 20. Upward
compression is **level-dependent by design**: the quieter the signal *entering*
the chain, the more the bass is lifted. So:

- Spotify volume is applied **before** the chain, so the tone changes.
- System volume (the `alsa_output…analog-stereo` sink) is applied **after** the
  chain, so it's just quieter, with the same tone.

The earlier measurement (dd1fec9): bass/mid ratio went from 3.4 at 100% to 6.2
at 50% pre-effects gain.

## What was tried before, and why it was dropped

dd1fec9 removed the Alt+M "loudness knob". It turned `easyeffects_sink`'s volume
into a pre-effects gain (`monitor.channel-volumes = true` node rule) on separate
keys. It worked acoustically, but it was a **second, invisible gain stage**: no
OSD, not the default sink. Audio could be quiet or silent while the device
volume looked fine. **Design constraint for this plan: there is exactly one
user-facing volume, it is the default sink, and the OSD shows it.**

## Approach

Put the speaker processing **inside a virtual sink whose own volume is applied
before the effects**, and make that sink the default output when the speakers
are in use. Then the ordinary volume keys work like the Spotify slider. The
real ALSA speaker sink sits behind it at a fixed, pinned level, and a limiter at
the end protects the speakers.

```
spotify ─▶ "Laptop Speakers" (virtual, default sink, OSD volume = PRE-effects)
             └▶ EQ ─▶ [loudness comp] ─▶ multiband (bass upward-boost) ─▶ limiter
                 └▶ alsa_output.pci-0000_63_00.6.analog-stereo  (pinned, hidden)
```

Headphones, the beyerdynamic dongle and the Sonos/RAOP sinks are separate,
unprocessed sinks that you pick with the existing Alt+0 switcher. Speaker tuning
should never touch them (today EasyEffects processes *everything*).

### Phased

1. **Phase 1 — declarative, no app.** Port the z14 preset to a PipeWire
   `libpipewire-module-filter-chain` sink, declared in Nix
   (`services.pipewire.extraConfig.pipewire."60-laptop-speakers"`). EasyEffects'
   heavy plugins are LSP plugins underneath (para EQ, multiband compressor,
   limiter), so `pkgs.lsp-plugins` LV2 nodes in the filter-chain give a near 1:1
   port of the JSON parameters. The filter-chain runs inside PipeWire: no
   EasyEffects daemon, no GUI, no custom unit. This alone fixes the original
   complaint.
2. **Phase 2 — real loudness compensation.** Upward compression reacts to
   *content*, not to the knob: quiet passages get boosted, loud ones don't.
   That's "punchy", not true loudness compensation. Add an equal-loudness
   (ISO 226) curve that follows the volume level: LSP's *Loudness Compensator*
   or a bass/treble shelf pair whose gain is a function of the virtual sink
   volume. A tiny watcher reads the sink's volume (`pw-dump --monitor` /
   `wpctl`) and pushes params with `pw-cli set-param <node> Props
   '{ params = [ "lc:volume" <dB> ] }'`. This is where it starts being an app.
3. **Phase 3 — the app (optional).** A small tuning tool for the laptop
   speakers: A/B bypass, live EQ/bass/loudness sliders, a "speaker
   protection" ceiling, save to a JSON that Nix can then consume. It drives
   the same filter-chain over `pw-cli`/libpipewire. It is **not** built on
   EasyEffects. EE 8 has no stable runtime parameter API (only
   `--load-preset`/bypass), and its "grab every stream" model is the reason it
   collides with per-device tuning. Language: Rust or Python + GTK/Qt or just a
   TUI — decide when we get there.

## Steps (phase 1)

1. **Verify the key assumption first:** a filter-chain *sink's* volume is applied
   before the filter graph (the capture-side adapter applies channel volumes on
   input). Test with a throwaway filter-chain that holds only a fixed upward
   compressor. Play pink noise, record the hw sink's monitor (`pw-record`), and
   compare the bass/mid ratio at 100% vs 50% (same method as dd1fec9). If it's
   applied *after*, fall back to `capture.props` + an explicit gain node driven
   by the phase-2 watcher.
2. Port `z14.json` to filter-chain nodes: EQ bands → `lsp para_equalizer_x32_lr`
   (or `builtin` biquads if there are few enough active bands). Multiband →
   `lsp mb_compressor_stereo` with the same band0 Boosting params. Add a final
   `lsp limiter_stereo` as a safety ceiling. The crystalizer is EasyEffects'
   own plugin with no LSP equivalent: drop it, or approximate it with a gentle
   high-shelf. A/B by ear.
3. Make it a z14-scoped Nix option (e.g. `noughty.laptopSpeakers.enable`,
   matching the old `noughty.hyprland.*` style). It sets
   `playback.props.target.object` to the ALSA speaker node and gives the virtual
   sink a high `priority.session` so WirePlumber picks it as the default.
4. Pin and hide the real speaker sink: fixed hw volume (100% or a calibrated
   max), excluded from `rofi-sink-switcher.nix` like `easyeffects_sink` is
   today. Pinning is either a WirePlumber rule or a Hyprland `exec-once wpctl
   set-volume` — prefer the rule, see open decisions.
5. Turn EasyEffects off on z14 (`services.easyeffects.enable` becomes a host
   override of `modules/desktop.nix`) so it stops pulling every stream into
   `easyeffects_sink`. blac keeps it.
6. Keep the original preset JSON in the repo next to the new config
   (`modules/hosts/z14/`), the way 8cafe86 did for g14. Restore `g14.json` from
   8cafe86 too, as reference material.
7. Re-measure, tune by ear at roughly 15/30/60/100%, then `deploy z14`.

## Open decisions

- **Filter-chain vs. keep EasyEffects with `easyeffects_sink` as the default
  sink.** Recommendation: filter-chain. Making `easyeffects_sink` the default
  means pinning EE's output device, its auto-preset-per-device logic, and the
  sink switcher's assumptions (it treats the default as a *real* device). That's
  the same tangle as last time. The filter-chain is declarative and
  speaker-only.
- **Volume curve.** Pre-effects volume can push the upward compressor to its
  full +6 dB at very low levels, which may get boomy. Phase 1 accepts that, and
  phase 2's curve is the real fix.
- **Phase-2 watcher = a user systemd unit.** CLAUDE.md says to ask before writing
  a custom unit. Alternative: Hyprland `exec-once`. Decide at phase 2.
- **Packaging the app (phase 3).** Its own repo + flake input, or
  `pkgs/` in this repo. Defer.
- **g14.** The host is gone (714281b). The plan targets z14. The g14 preset is
  only kept as a reference unless that laptop comes back.

## Risks / rollout

- **Silent-audio failure mode (the reason it was dropped last time).** It's
  mitigated structurally: the only knob is the default sink's volume, the OSD
  shows it, and the hw sink is pinned. Remaining risk: if the virtual sink
  fails to load, WirePlumber falls back to the real sink at its pinned 100%, so
  it's loud rather than silent. Acceptable, but check the hw pin isn't
  "max + boost".
- **Speaker damage / clipping.** Pre-effects gain plus upward compression can
  exceed 0 dBFS. The final limiter is mandatory, not optional.
- **Latency.** LSP multiband + lookahead limiter add a few ms. Irrelevant for
  music, and fine for video.
- **Rollout:** `deploy z14`. Back out by setting the option to false (EasyEffects
  comes back with the old presets, which are still in `~/.local/share`).
