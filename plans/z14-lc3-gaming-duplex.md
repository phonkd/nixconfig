# Persistent LC3 gaming duplex on z14

**Repo:** nixconfig  **Status:** in-progress

## Goal
Preserve E's proven simultaneous 48 kHz LC3 playback and microphone audio across
reconnects. Conversational context was silent; gaming context with 48_4_1 worked.
User approved the scoped package patch on 2026-10-28.

## Approach
Add an opt-in PipeWire BAP context setting and honor its explicit preset before
the normal TMAP duplex rate preference. Configure only E with context 8 and CIG 2.
WirePlumber must load the same patched PipeWire. Reconnect testing exposed a
WirePlumber 0.5.18 lifecycle regression: disconnected SPA devices are not retained,
losing per-device codec settings before BlueZ negotiates. Retain/reuse disconnected devices in its existing monitor, and preserve native
Bluetooth child objects during connection property updates. Real object removal
still releases them. Also guard PipeWire capability probes without settings and
prevent a replaced SPA device from clearing its successor's settings. The first
Lua-only fix was insufficient: the native handler also replaced each child.

## Steps
- [x] Build and activate PipeWire patch and E rule (3315d2a).
- [x] Check codec defaults, gaming selection, context masking and preset fallback.
- [x] Verify native reconfiguration: 48 kHz, gaming context, valid microphone audio.
- [ ] Retain/reuse WirePlumber's disconnected SPA device and validate its lifecycle.
- [ ] Build, activate and verify normal reconnect without endpoint commands.
- [ ] Confirm playback with user and preserve final evidence.

## Risks / rollout
Local patches need review when PipeWire or WirePlumber changes. Keep normal codec
selection unchanged unless the new context option is set. Deploy z14 locally with
nixos-rebuild switch --flake .#z14 --impure; no kernel rebuild or reboot needed.
Audio restarts briefly interrupt playback. Keep the known working LC3 parameters
in /tmp/z14-le-diag for diagnosis; do not fall back to AAC or the laptop microphone.
