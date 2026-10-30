# LC3 playback at 248 kb/s on z14

**Repo:** nixconfig  **Status:** in-progress

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
- [ ] Commit on local main and build with parallel compilation; stage next boot.
- [ ] After reboot, trace 310-byte sends and ask for a listening check.
- [ ] Check established duplex again before offering persistent profile choices.

## Source validation
Patch applies with zero fuzz against upstream v6.18.57 hci_event.c. Compiled
the actual event-handler role switch before and after patching in a temporary
C harness (GCC, -O2 -Wall -Wextra -Werror): nine cases, four expected failures
before and zero after. Covers the captured 310/155 split, existing 240/120
duplex, fragmentation in both directions, disabled directions, preserving a
configured limit smaller than Max_PDU, and unchanged peripheral behavior.
Harness: /tmp/z14-cis-sdu-regression.py. Nix parse and git diff --check passed.
This validates the limit update, not actual radio transmission or audible output.

## Risks / rollout
This is a local experimental Bluetooth core fix, not an upstream backport.
Retain the current kernel version and all existing audio fixes. Keep the saved
48_4_1 duplex preset until the higher-rate test succeeds. Use nixos-rebuild boot
on z14; reboot requires the user's go-ahead. Previous boot generations remain
available. No automatic AAC fallback. A successful build does not establish
working 248 kb/s playback; controller/headset behavior needs live validation.
