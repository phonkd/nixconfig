# Fosi MC331 — kill the low-volume noise gate

**Repo(s):** nixconfig   **Status:** done — working on z14. `modules/fosi-mc331.nix`
re-sends the frame on every amp power-on and input-selector change. Read "What
the hardware actually did" before touching it: several parts of the original
design below are wrong, and the one that mattered is subtle.

## The bug, in one paragraph

**The payload was never the problem; the framing was.** The report must keep its
leading `0x00` byte *in the data stage* and be padded to exactly **65 bytes**.
The HID spec says that byte is the report ID and belongs in `wValue`, and the
ESP32 community firmware duly strips it — so this repo did too. But the amp
scans the raw report buffer, so a stripped frame arrives shifted one byte along
and is silently discarded. The amp ACKs it regardless, which makes the failure
invisible: every threshold from −1 to −1000 dB, every report length (17/64/256),
both report types and both HID interfaces were "accepted" and ignored until the
leading byte went back. The community Android app
(`github.com/CaseresMaxi/fosi_MC331_fix`, `HidSender.kt`) passes all 65 bytes
into the data stage and is the only implementation that made this explicit —
reading it rather than reconstructing from the ESP32 source would have saved the
entire detour.

A second, quieter lesson: the working payload carries the **stock −68 dB
threshold**. So it is the flags byte (`0xFF`), not the threshold, that calls the
gate off — and the −90 dB value the forum quotes was only ever proven under a
framing this amp ignores. The module therefore ships the app's bytes verbatim
rather than an "improved" threshold.

## What the hardware actually did (z14, 2026-09-23)

The module is live on z14 and the amp accepts frames. It just doesn't act on
them. Measured, not inferred:

* **The HID interface has no endpoints**, so `usbhid` never binds it and no
  `/dev/hidraw*` node exists for it. Everything must go over control transfers
  (SET_REPORT on ep0) via libusb — the plan's original hidapi/hidraw design
  cannot work here, and `modules/fosi-mc331-fix.py` uses pyusb instead.
* **The tuning interface number moves with the input selector.** On OPT/AUX/BT
  (PID `171E`) the amp exposes that one interface, number 0. On USB (PID `1717`)
  it is also a USB-Audio device: 0 and 1 are audio interfaces held by
  `snd-usb-audio`, 2 is Consumer Control (the remote's volume/play keys), and
  the tuning interface is 3. Addressing 0 in USB mode collides with
  `snd-usb-audio` and fails `EBUSY`. Select it by signature instead: HID class,
  zero endpoints.
* **Interface 3 declares a 256-byte Output report** — `06 00 FF` (Usage Page
  0xFF00), `0A AA 55` (Usage 0x55AA), `75 08` × `96 00 01` — plus a 256-byte
  Input report and an 8-byte Feature report, with no Report IDs. A 64-byte
  transfer is ACKed and dropped. hidapi pads to the declared length for free,
  which is why no community tool had to know this.
* **With a correctly sized 256-byte report, the amp ACKs everything and applies
  nothing.** `-1`, `-10`, `-90`, `-100`, `-1000`, a nonsense `-10001230123`, and
  the suppressor-off variant (flags byte `0x00`) are all audibly identical. A
  `-10 dB` threshold sits above nearly all programme material and should gate
  almost continuously; it does nothing. `GET_REPORT` on Input returns zeros and
  on Feature returns what looks like uninitialised SRAM (ARM pointers such as
  `0x20016cc8`).

So the amp ACKs a well-formed SET_REPORT regardless of content. **Resolved:** the
frames were being discarded because the leading `0x00` had been stripped out of
the data stage — see "The bug, in one paragraph" above. Nothing was wrong with
the unit, the payload or the interface selection.

The decoded frame format below still stands on its own terms — the CRC-8
derivation reproduces both independent captures exactly — it simply isn't what
this amp listens to.

### How it was found, for next time

The forum hands over the payload, and that part was right all along. What it
does *not* hand over is the framing, because every community implementation goes
through hidapi, which picks the interface, the padding and the request type
invisibly. Reconstructing from the ESP32 source inherited that firmware's one
wrong choice (stripping the leading byte) with no way to see it, because the amp
ACKs a malformed frame exactly like a good one.

What broke the deadlock was reading the Android app's `HidSender.kt` — the only
implementation that spells the framing out. **When a community fix exists as
source, read the source before reconstructing the protocol from a description of
it.** The sweeps over interface, length and report type were all reasonable and
all useless, because the one variable that mattered wasn't in the matrix.

Still open, if anyone wants it: **Lozioandry's `fosi_watcher.zip`** on the forum
thread (login-walled) is the original implementation, and would confirm whether
it framed things the same way.

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
Bluetooth, an external DAC over RCA, a phone).

#### Powering the fixer — the thing that bites first

The amp's USB-C is a **device** port. It sources no VBUS, so nothing plugged into it
gets powered from it, and the fixer has to be the USB **host**. That kills the naive
"single-USB-C ESP32 plugged straight into the amp": that board's only connector is
also its only power inlet, and you can't have both.

The saving grace is that **the amp does not need the host to supply VBUS either.**
The reference firmware targets `esp32-s3-devkitc-1`, whose OTG port physically
*cannot* source VBUS — both USB connectors feed the 5 V rail through Schottky
diodes, a documented DevKitC-1 limitation — and the firmware contains no
VBUS-enable GPIO code at all. It works regardless, which means the MC331, being
self-powered from its own PSU, asserts its D+ pull-up without seeing host VBUS. The
two data lines are enough.

So the constraint is only "the fixer needs power from somewhere other than the amp",
and every option below satisfies it:

| Fixer | Powered by | Link to the amp |
|---|---|---|
| Pi 4 / 5 | its own USB-C PSU | USB-**A** → USB-C. Nothing to think about. |
| Pi Zero 2 W | the `PWR IN` micro-USB | the second (`USB`/OTG) micro-USB → OTG adapter → USB-C |
| ESP32-S3, two USB-C (DevKitC-1 & clones) | the UART/programming port | the OTG port → USB-C |
| ESP32-S3, one USB-C (S3 Zero, Super Mini) | **5 V + GND on the pin header**, from any charger | the single USB-C → amp, data only |

The single-port S3 is therefore still viable — just never power it through the
connector you need for the amp. Two caveats if you go that way: with
`ARDUINO_USB_MODE=0` the native port is in host mode, so there's no CDC serial and
reflashing means the BOOT-button download mode; and *if* this particular unit turns
out to want VBUS after all, the fix is a wire (or a shorted Schottky) from the
board's 5 V rail to the connector's VBUS pad.

#### The candidates

* **Raspberry Pi** (Zero 2 W is plenty; a 4 is nicer). Best fit *if* it can earn its
  keep by also becoming a `gigaplayer-client` snapclient — then one USB-A → USB-C
  cable carries both the audio and the fix, the amp stays in USB mode (PID `0x1717`),
  and we delete a separate DAC. It also has the least to go wrong electrically:
  separate power inlet, a real host port that does supply VBUS, no board mods. Honest
  cost: this flake is entirely `x86_64-linux` (+ one `aarch64-darwin`), so a Pi means
  a **new platform** — an SD image to build, and `205-builder` can't build for it
  without binfmt emulation. Note the Pi's *own* USB-C is power/gadget only; the amp
  hangs off a USB-A port.
* **ESP32-S3** flashed with the community firmware
  (`github.com/CaseresMaxi/fosi-fix-mc331-sp32`, ~$8, has a web UI, re-applies on
  reconnect and every 30 s). Cheapest and quickest, and a two-USB-C DevKitC-1 needs
  no thought at all since that is the board the firmware was written for. Downsides:
  a single-port board needs the header-power trick above, and either way it's a
  hand-flashed box outside the config — the kind of thing this repo exists to avoid.

Recommendation: **Phase 1 on an existing host if the amp is cabled to one; a Pi only
if it also becomes the streamer; otherwise a two-port ESP32-S3.** A single-purpose Pi
is worse than the ESP32 at the same job, and a single-purpose ESP32 is worse than
either at being declarative.

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
  known-good −90 dB packet and the VID/PIDs come from; `platformio.ini`
  (`board = esp32-s3-devkitc-1`) and the absence of any VBUS GPIO handling are what
  establish that the amp enumerates without host VBUS.
* `docs.espressif.com/projects/esp-dev-kits/.../esp32-s3-usb-otg/user_guide.html` and
  the ESP32 forum thread "USB Host example on ESP32-S3-DevKitC-1" — the DevKitC-1
  cannot drive VBUS out of its USB port; the ESP32-S3-USB-OTG kit is the board that
  can (GPIO12 `DEV_VBUS_EN` / GPIO13 `BOOST_EN` / GPIO18 `USB_SEL`, 500 mA limited),
  if a future use ever does need to power a bus-powered peripheral.
