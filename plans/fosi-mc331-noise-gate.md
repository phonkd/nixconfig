# Fosi MC331 — kill the low-volume noise gate

**Repo(s):** nixconfig (a new tag-gated module) + possibly a new `aarch64-linux`
host   **Status:** draft — needs the "which box is cabled to the amp" answer
before Phase 1 lands.

## Goal

The MC331 chops off quiet passages — fade-ins, film ambience, classical pianissimo
all cut in and out. That is not a defect in this unit: it is the DSP's *Music Noise
Suppressor* firing at a stock threshold of **−68 dB**, which is absurdly high for a
desktop/living-room amp. Fosi has acknowledged it, has not shipped a firmware fix,
and (as of the vendor forum thread, Sep 2026) is talking about a hardware revision
instead.

Outcome we want: the gate never audibly fires, and nobody performs a ritual to get
there — no phone app, no Windows VM, no "remember to run the script" after every
power cycle.

## What is actually going on

The amp is built on an **MVSilicon BP1048B2** DSP (which is also its DAC — the USB
input is 16 bit / 48 kHz only, despite the manual). The DSP is configurable over
the USB-C port with the OEM tool *ACPWorkbench*; the noise suppressor lives on
page `0x88`.

The trap, and the reason there is no "permanent" fix:

> The amp's **MCU is the master**. On every power-on it re-pushes the factory
> parameter set into the DSP. Saving to the DSP's own flash from ACPWorkbench
> does not survive, because the MCU overwrites it a second later. The MCU's
> parameter store is password-locked and Fosi has not released the password.

So **every** working fix in the wild is the same shape: *after each power-on, send
one HID packet over USB.* The only question is who sends it.

### The protocol, decoded

Community tools ship one hardcoded blob. I decoded it, so we can generate any
threshold instead of being stuck with someone else's capture:

```
00  A5 5A  88  0B  | FF 00 00  D8 DC  03 00  05 00  64 00 | 18
^   ^      ^   ^     ^         ^      ^      ^      ^       ^
|   |      |   |     |         |      +------+------+       CRC-8
|   |      |   |     |         int16 LE, threshold x100 dB (0xDCD8 = -9000 = -90.00 dB)
|   |      |   |     enable/flags byte (0xFF in every known-good capture)
|   |      |   payload length (11)
|   |      command: noise suppressor page 0x88
|   frame header
HID report ID (report is padded to 65 bytes total)
```

* **Threshold** = signed int16 little-endian at packet offset 8, in hundredths of a dB.
* **Trailing byte** = plain **CRC-8** (poly `0x07`, init `0x00`, no reflection, no
  final xor) over the 11 payload bytes only — *not* over the header/command/length.
  Verified: it reproduces both independently-captured packets in the wild exactly
  (the `-68.00` one from the forum's `usbhidtool` line and the `-90.00` one baked
  into the ESP32 firmware). Generator:

  ```python
  def crc8(d):
      c = 0
      for b in d:
          c ^= b
          for _ in range(8):
              c = ((c << 1) ^ 0x07) & 0xFF if c & 0x80 else (c << 1) & 0xFF
      return c

  def packet(db, enable=0xFF):
      t = int(round(db * 100)) & 0xFFFF
      pl = [enable, 0x00, 0x00, t & 0xFF, t >> 8, 0x03, 0x00, 0x05, 0x00, 0x64, 0x00]
      return bytes([0x00, 0xA5, 0x5A, 0x88, 0x0B] + pl + [crc8(pl)])
  ```

  ```
  -68.00 dB (stock)  00 A5 5A 88 0B FF 00 00 70 E5 03 00 05 00 64 00 16   <- reference capture
  -80.00 dB          00 A5 5A 88 0B FF 00 00 C0 E0 03 00 05 00 64 00 5A
  -90.00 dB          00 A5 5A 88 0B FF 00 00 D8 DC 03 00 05 00 64 00 18   <- reference capture
  -96.00 dB          00 A5 5A 88 0B FF 00 00 80 DA 03 00 05 00 64 00 A7
  ```

* **USB identity:** VID `0x8888`; PID `0x1717` when the amp's input is set to USB,
  `0x171E` when it is on OPT/AUX/BT. Both must be handled — the PID *changes when
  the input selector changes*, which also gives us a free hotplug event.
* Send as an **Output** report; fall back to **Feature** (SET_REPORT) if that
  fails. The interface is single-owner: it fails while ACPWorkbench holds it.
* Wait ~3 s after the device appears — the MCU is still pushing defaults before that.

The remaining unknown is the semantics of the flags byte (`0xFF`). Users report that
*fully disabling* the suppressor in ACPWorkbench also fixes the cut-off; `0x00` there
is the obvious candidate and is now cheap to test, since we can compute its CRC
(`00 A5 5A 88 0B 00 00 00 D8 DC 03 00 05 00 64 00 DB`). Lowering the threshold is the
safer default regardless — it keeps the gate for true digital silence.

## Options

| # | Approach | Verdict |
|---|---|---|
| A | Live with it / keep the volume up | Free. This is the thing we're fixing. |
| B | ACPWorkbench or the community Android app, per power-cycle | Works, but it's the ritual we're trying to delete. |
| C | **Systemd unit on a NixOS box already cabled to the amp** | Declarative, fits this repo, zero new hardware — *if* such a box exists next to the amp. |
| D | **Dedicated small USB host tethered to the amp** (Pi, or ESP32-S3) | Source-independent: fixes the amp even when it's fed by Bluetooth/optical/RCA. |
| E | Patch the MCU firmware | Locked, no dump, no upside. Out of scope. |

C and D are the same software problem; D just moves it onto a box whose only job is
to be permanently plugged in.

## Approach

Three phases; each is useful on its own and phase 0 can happen in the next ten
minutes with hardware already on hand.

### Phase 0 — prove it on the actual unit (no repo changes)

Plug any NixOS machine into the amp's USB-C with a **USB-A → USB-C** cable (the amp
is the USB *device*; the machine must be the host) and run:

```sh
nix shell nixpkgs#python3Packages.hid -c python3 - <<'EOF'
import hid, time
PKT = bytes.fromhex("00A55A880BFF0000D8DC03000500640018")  # -90.00 dB
d = hid.Device(vid=0x8888, pid=0x1717)   # 0x171E if the input selector is not on USB
time.sleep(3)
try:
    d.write(PKT.ljust(65, b"\0"))
except Exception:
    d.send_feature_report(PKT.ljust(65, b"\0"))
EOF
```

Then listen to something with a long fade-out. This settles three things at once:
that the packet works on *this* unit, which PID the amp presents, and whether −90 dB
is enough or we want the flags-byte-off variant.

### Phase 1 — a tag-gated NixOS module

`modules/fosi-mc331.nix`, in the style of `modules/gigaplayer.nix`: a cross-host
module in `alwaysImport` that self-gates on a `fosi-mc331` host tag, so the whole
opt-in is one word in `lib/registry.nix`.

Contents:

* a `pkgs.writers.writePython3Bin "fosi-mc331-fix"` wrapping the generator above,
  with the threshold as a module option (`default = -90.0`) rather than a magic blob;
* `systemd.services.fosi-mc331-fix` — `Type = "oneshot"`, runs as root (which is why
  we need none of the `plugdev`/`hidraw` udev permission dance the forum thread
  describes), `ExecStartPre = sleep 3` for the MCU settle, `Restart`/`RestartSec` so
  a busy interface retries;
* `services.udev.extraRules` matching VID `8888` / PIDs `1717` and `171e` with
  `TAG+="systemd", ENV{SYSTEMD_WANTS}+="fosi-mc331-fix.service"` — this is what makes
  it fire on amp power-on *and* on every input-selector change;
* a slow `systemd.timers` safety net (60 s; the packet is idempotent and costs
  nothing) so a missed udev event can never leave the gate armed for a whole evening.

No secrets, no traefik, no ports — nothing to register in the app registry.

### Phase 2 — the always-on box, if Phase 1 has no host to live on

Only needed if the amp is fed by something that isn't a NixOS machine (TV over
Bluetooth, an external DAC over RCA, a phone). Two candidates:

* **Raspberry Pi** (Zero 2 W is plenty; a 4 is nicer). Best fit *if* it can earn its
  keep by also becoming a `gigaplayer-client` snapclient — then one USB-A → USB-C
  cable carries both the audio and the fix, the amp stays in USB mode (PID `0x1717`),
  and we delete a separate DAC. Honest cost: this flake is entirely `x86_64-linux`
  (+ one `aarch64-darwin`), so a Pi means a **new platform** — an SD/UEFI image to
  build, and `205-builder` can't build for it without binfmt emulation. Wire the Pi's
  **USB-A** port to the amp: on a Pi 4/5 the USB-C port is power/gadget only, and on a
  Zero it needs an OTG adapter.
* **ESP32-S3** flashed with the community firmware
  (`github.com/CaseresMaxi/fosi-fix-mc331-sp32`, ~$8, has a web UI, re-applies on
  reconnect and every 30 s). Five minutes, zero flake churn — but it's a
  hand-configured box outside the config, which is exactly the kind of thing this
  repo exists to avoid.

Recommendation: **Phase 1 on an existing host if the amp is cabled to one; a Pi
only if it also becomes the streamer.** A single-purpose Pi is worse than the ESP32
at the same job, and a single-purpose ESP32 is worse than either at being
declarative.

## Steps

1. [ ] Phase 0 — run the one-liner against the amp; record the working PID, and
       whether −90 dB alone is enough.
2. [ ] Decide the host (see open decisions).
3. [ ] `modules/fosi-mc331.nix` — option + writer script + service + udev rule + timer.
4. [ ] Add the `fosi-mc331` tag to that host in `lib/registry.nix`.
5. [ ] `deploy <host>`; power-cycle the amp; `journalctl -u fosi-mc331-fix` and a
       fade-out listen.
6. [ ] (optional, Phase 2) Pi as `gigaplayer-client` + fix applier — its own plan,
       because a new platform in this flake is not a side quest.

## Open decisions

1. **Which machine is physically next to the amp, and what feeds it today?** This is
   the only real blocker: it decides Phase 1 vs Phase 2 outright. `blac`, `g14` and
   `z14` are all `gigaplayer-client`s and any of them could carry the tag.
2. **−90 dB vs. disabling the suppressor outright.** Defaulting to −90 dB: it fixes
   every reported symptom, is the field-proven packet, and keeps a gate for true
   digital silence. The disable variant is one option flip away if −90 still audibly
   gates.
3. **Pi vs ESP32, if Phase 2 happens.** Recommending the Pi *only* bundled with the
   snapclient role; otherwise the ESP32 is the honest answer.

## Risks / rollout

* **Hiss floor.** The gate exists to hide the amp's noise floor. Every user in the
  thread who disabled or lowered it reports no audible difference on speakers
  (headphone hiss is present either way). Reversible: raise the option back to −68.
* **Interface contention.** The HID interface is single-owner; the service will fail
  while ACPWorkbench or the Android app holds it. `Restart=on-failure` covers it.
* **Missed hotplug.** Covered by the 60 s timer.
* **Don't fuzz the DSP.** We can now compute valid CRCs for *any* byte pattern, which
  means we can also write nonsense to a device with no recovery path. Stay on page
  `0x88`, change only the threshold and (once tested) the flags byte.
* **Rollout / back-out:** `deploy <host>`; back-out is removing the tag from
  `lib/registry.nix` and redeploying — the amp reverts to stock on its next power-on
  by itself, since nothing was ever persisted to it.

## Sources

* Vendor forum thread, Oct 2025 – Sep 2026: `community.fosiaudio.com/threads/mc331-low-volume-cut-off.42905/`
  (doxygenthief's ACPWorkbench find, Lozioandry's HID-injection script, sorbet8876's
  Linux udev rules, Maximiliano6969's Android app and ESP32 firmware).
* `github.com/CaseresMaxi/fosi-fix-mc331-sp32` — `src/config/Config.h` is where the
  known-good −90 dB packet and the VID/PIDs come from.
