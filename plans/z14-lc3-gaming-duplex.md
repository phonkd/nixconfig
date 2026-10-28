# Persistent LC3 gaming duplex on z14

**Repo:** nixconfig  **Status:** in-progress (cold-boot validation pending)

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
- [x] Retain/reuse WirePlumber's disconnected SPA device and validate its lifecycle.
- [x] Build, activate and verify normal reconnect without endpoint commands.
- [x] Confirm playback with user and preserve final evidence.

## Verification (2026-10-28)
Activated and saved generation
`/nix/store/6fi075q2z1xmvwqxdimhp49mn0hgy41q-nixos-system-z14-26.05.20261025.1f607aa`.
PipeWire's 52 package tests passed. Optimized codec checks cover default/zero
context, gaming 48 kHz, available-context masking, overflow, unsupported presets
and null-settings capability probes. Lua/native lifecycle checks cover retaining
Bluetooth children, single handler registration, removal and other factories.

Final normal BlueZ Device1 disconnect/connect selected bap-duplex automatically,
without SetConfiguration or Reconfigure calls: context 8, 48 kHz, 10 ms,
240-byte stereo output and 120-byte mono input, CIG 2/CIS 0, RTN 5, latency 20 ms,
presentation delay 40 ms. Zen remained linked to E; the user confirmed "Yes,
normal". Simultaneous microphone capture after reconnect produced 480000 samples,
476987 nonzero, RMS 933.29 (s16). Both default devices point to E; EasyEffects is
stopped. Evidence is in `/tmp/z14-le-diag/gaming-final-*.json` (no PCM retained).

BlueZ crashed once while cleaning up the earlier experimental session. After
its restart, automatic LC3 negotiation and the next normal disconnect/connect
succeeded; BlueZ PID 31225 and WirePlumber PID 30921 stayed alive. No claim that
the BlueZ cleanup crash is fixed. Reboot has not been tested, but the running and
boot-default system profile both point to the activated generation above.

## Risks / rollout
Local patches need review when PipeWire or WirePlumber changes. Keep normal codec
selection unchanged unless the new context option is set. Deploy z14 locally with
nixos-rebuild switch --flake .#z14 --impure; no kernel rebuild or reboot needed.
Audio restarts briefly interrupt playback. Keep the known working LC3 parameters
in /tmp/z14-le-diag for diagnosis; do not fall back to AAC or the laptop microphone.

## Cold-boot follow-up
The user's next rebuild/boot retained the patched kernel and correct gaming QoS,
but both BAP transports stayed idle. The trace shows successful CIG configuration
and ASE Enable followed by HCI LE Create CIS returning Command Disallowed (0x0c).
Disconnect/reconnect did not clear it. Native adapter power off/on restored audio,
confirmed by the user; both gaming-context transports became active.

The greeter (UID 988) ran WirePlumber and registered/removed BAP endpoints just
before phonkd's session. Add ConditionUser=!greeter to the existing WirePlumber
user unit so the text login screen does not negotiate Bluetooth audio. This is a
boot-race mitigation, not a verified controller fix. A subsequent cold boot still
needs validation. Matching upstream report: https://github.com/bluez/bluez/issues/2496.
If the controller wedges again, `bluetoothctl power off` followed by
`bluetoothctl power on` and reconnecting E is the verified recovery. No re-pairing
or manual endpoint settings are required.
