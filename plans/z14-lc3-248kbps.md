# LC3 playback at 248 kb/s on z14

**Repo:** nixconfig  **Status:** in-progress (248 kb/s playback confirmed; mode selector pending)

## Goal
Test E at 48 kHz stereo, 10 ms, 155 bytes per channel (248 kb/s total).
The user approved a kernel patch on 2026-10-30 after the native BlueZ test
failed with repeated 310-byte sends returning EMSGSIZE.

## Evidence and approach
The controller accepted Max_SDU_C_To_P=310, then reported Max_PDU_C_To_P=155
and BN_C_To_P=2 in LE CIS Established. Linux 6.18.57 replaces the configured
SDU limit with that PDU size, so iso_send_frame rejects the complete audio frame.
Preserve the central's configured input/output SDU limits; still zero a direction
when its burst number is zero. Leave the peripheral path unchanged because it
does not obtain its limits through the local Set CIG Parameters command.
Do not infer SDU size by multiplying PDU size by burst number.

## Steps
- [x] Add a z14-only patch through boot.kernelPatches, retaining the MediaTek fix.
- [x] Check application against 6.18.57 and regression cases for playback,
      duplex, disabled directions, and the unchanged peripheral path.
- [x] Commit on local main and build with parallel compilation; stage next boot.
- [x] After reboot, trace 310-byte sends and ask for a listening check.
- [ ] Check established duplex again before offering persistent profile choices.

## Source validation
Patch applies with zero fuzz against upstream v6.18.57 hci_event.c. Compiled
the actual event-handler role switch before and after patching in a temporary
C harness (GCC, -O2 -Wall -Wextra -Werror): nine cases, four expected failures
before and zero after. Covers the captured 310/155 split, existing 240/120
duplex, fragmentation in both directions, disabled directions, preserving a
configured limit smaller than Max_PDU, and unchanged peripheral behavior.
Harness: /tmp/z14-cis-sdu-regression.py. Nix parse and whitespace checks passed
(space-before-tab checking disabled for the unified patch's context markers).
This validates the limit update, not actual radio transmission or audible output.

## Build and staging (2026-10-30)
Implementation committed as a313c80 on local main, not pushed. Full 6.18.57
kernel, all 7296 modules, and the dependent evdi/DisplayLink packages built
successfully on 205-builder. Observed make -j12 and concurrent compiler workers;
both hci_event.o and btmtk.o compiled successfully.

`nixos-rebuild boot` exited successfully and Limine installation completed.
The next-boot system profile is
`/nix/store/5gv1r3x1jzjlmzg6f6vmhhjq2mcmvkp1-nixos-system-z14-26.05.20261025.1f607aa`,
with kernel `/nix/store/h3mc05kdv76nvkl9y57idz0lim88jwiy-linux-6.18.57/bzImage`.
The running kernel remains the previous `42scrrgvrqp17hr5k2yz727nqdr09zb5`
build. No reboot or post-patch radio/listening test has happened.
Log: /tmp/z14-lc3-248-kernel-build.log. Retain 48_4_1 in the saved configuration;
retry the manual playback-only 310-byte SDU test after booting the patched kernel.

## Live validation (2026-10-31)
Confirmed the patched h3mc05kd kernel is booted. The initial manual endpoint
test was invalid: a 240-byte stream remained configured beside the new 310-byte
stream. BlueZ enabled both ASEs and attempted two CIS connections; the second
failed after a connection timeout. The user observed the headset reboot. This
does not establish that the bitrate or SDU patch caused the reboot.

Replaced manual endpoint configuration with PipeWire's native 48_6_1 preset.
Paused Spotify, disconnected E, stopped WirePlumber, verified zero remaining
transports, then restarted with only the local bap_source role and connected
using org.bluez.Bearer.LE1.Connect. Exactly one playback transport negotiated.
Gaming context 8 remained silent, despite 800 successful 310-byte sendto calls
and zero send errors. Changing only context to media (4), again after a full
teardown, produced normal audio confirmed by the user.

Working playback-only settings: 48_6_1, 48 kHz stereo, 10 ms unframed,
155 bytes/channel, 310-byte SDU (248 kb/s total), context 4, CIG 3/CIS 0,
RTN 5, latency 20 ms, presentation delay 40000 us, PHY 2M. Controller CIS setup
succeeded with Max_PDU=155 and BN=2. Actual ISO output is split into HCI
fragments of 256 and 58 bytes; controller completion events continue.
The local sink monitor measured 380160 samples, RMS 581.3 and peak 2724 (s16).
The user answered "Normal audio". Spotify remains routed to E.

Evidence: /tmp/z14-le-diag/248-clean-send.strace,
/tmp/z14-le-diag/248-clean-playing.btsnoop and its text log,
/tmp/z14-le-diag/248-media-working.json. No microphone PCM was retained.
The btmon process itself aborted with "stack smashing detected" while decoding
fragmented ISO output shortly after the media-context connection started, so
that capture is truncated. WirePlumber and E's transport remained active, and
normal audio was user-confirmed independently; the monitor crash is not a
headset reboot. The 800 successful sends were captured in the preceding
gaming-context test using the same 310-byte SDU size.

The active native test override is outside Nix, at
~/.config/wireplumber/wireplumber.conf.d/99-z14-lc3-248-test.conf. It overrides
monitor.bluez.properties to bluez5.roles=[bap_source] (playback-only globally)
and appends E's preset/context/CIG rule. Leave this working mode active for now;
the declared Nix configuration still contains the established 48_4_1/context-8
duplex settings. Remove the temporary override when implementing the permanent
mode selection, otherwise it will override the declarative settings. No
playback/duplex selector or post-patch duplex listening test is completed yet.

## Risks / rollout
This is a local experimental Bluetooth core fix, not an upstream backport.
Retain the current kernel version and all existing audio fixes. Keep the saved
48_4_1 duplex preset until the higher-rate test succeeds. Use nixos-rebuild boot
on z14; reboot requires the user's go-ahead. Previous boot generations remain
available. No automatic AAC fallback. A successful build does not establish
working 248 kb/s playback; controller/headset behavior needs live validation.
