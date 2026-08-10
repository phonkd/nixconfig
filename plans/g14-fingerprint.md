# g14 fingerprint (Goodix 27c6:521d)

**Repo(s):** nixconfig   **Status:** blocked on one measurement

_Status (2026-08-10):_ Sensor is driven, provisioned, and **enrols**; it does
**not verify**. Everything below the matcher works. The open question is whether
the capture is good enough for NBIS at 64x80, and that is decided by one test
run described under "What I need next".

_Decisions locked:_ graft the driver onto **current** nixpkgs libfprint rather
than downgrading the whole library (the AUR approach); sensor **has been
reflashed** and its factory PSK is permanently gone; do **not** lower
`bz3_threshold` to force matches.

## Where this stands

| Stage | State |
|---|---|
| Driver claims device | works — `/net/reactivated/Fprint/Device/0` |
| Sensor PSK provisioned | done, irreversible (factory PSK overwritten) |
| `fprintd-enroll` | completes, 5 stages |
| `fprintd-verify` | **`verify-no-match`, always** |
| bozorth3 score | **0, occasionally 11**, threshold 24 |

## What I need next

The last commit (`82edbd1`) rewrote the capture path but is **untested against
hardware**. The new `fprintd` is already built and in the store, so this needs
no system rebuild.

Terminal 1 — new daemon, debug + image dump on:

```
sudo systemctl stop fprintd
sudo env G_MESSAGES_DEBUG=all GOODIX52XD_DUMP=/tmp/goodix \
  /nix/store/08cvyfn1cdq875kz7rzw6dx472v6mmy0-fprintd-1.94.5/libexec/fprintd -t
```

(If that store path has been GC'd, rebuild it with
`nix build --impure .#nixosConfigurations.g14.config.services.fprintd.package`.)

Terminal 2 — the old template came from the broken pipeline and must go:

```
fprintd-delete $USER
fprintd-enroll
fprintd-verify
```

**Report back two things:**

1. The `score N/24` lines from terminal 1.
2. That `/tmp/goodix-*.pgm` exist — those are the raw captures, and reading them
   directly is the whole point. Everything so far has been inferred from match
   scores; nobody has actually looked at what this sensor produces.

## How to read the result

- **Recognisable ridges + scores at/near 24** → done, set the threshold with
  evidence and re-enable normally.
- **Recognisable ridges + scores still ~0** → the images are fine but 64x80 is
  too small for NBIS. This is the sensor's real limit and the honest end of the
  road; upstream libfprint rejected this sensor for exactly this reason. Stop and
  disable rather than tune.
- **Noise / blank / smeared PGMs** → capture is still wrong. Next suspects, in
  order: ridge polarity (try `img->flags |= FPI_IMAGE_COLORS_INVERTED`), the
  commented-out `postprocess_frame()` background subtraction (the driver captures
  an empty background frame into `self->empty_img` and then never uses it), and
  `squash_frame_linear()`'s min/max normalisation being thrown off by a few
  outlier pixels.

**Do not lower `bz3_threshold` to make verification pass.** At a noise floor of
0 and occasional 11, a threshold that admits those is authenticating on noise —
and `fprintAuth` puts this in front of sudo and sddm.

## Key facts worth not rediscovering

- **Mainline libfprint does not support 27c6:521d.** The pid appears only in
  `fprint-list-udev-hwdb.c`'s autosuspend whitelist — a power-management list,
  not a driver list. Enabling fprintd alone finds no device.
- The only working driver is `goodixtls` from **infinytum/libfprint**, branch
  `unstable`, abandoned Nov 2021 at libfprint 1.94.1. The AUR package
  `libfprint-goodix-521d` ships the whole stale 1.94.1 tree; that is a dead end
  on NixOS because nixpkgs' fprintd needs libfprint >= 1.94.9.
- The fork's addition is **entirely self-contained** (a new `drivers/goodixtls/`
  plus meson wiring), which is why grafting it onto 1.94.10 works. libfprint's
  own test suite passes on the result: 97 ok, 0 fail.
- The `udev-hwdb` test diffs the shipped hwdb against the generated one, so it
  verifies the whitelist->driver-section move for 5110/521d/538d. If it fails
  after a nixpkgs bump, that is what it is complaining about.
- `ppmm` is **never assigned anywhere in libfprint** — it is 0 for every image
  driver, passed into NBIS. Upstream behaviour, not our bug. Already chased; do
  not chase again.
- `rotate_frame()` in the driver is dead code (never called).
- The sensor keeps state across warm reboots. A failed activation leaves it
  desynced, and the next tool run dies with `Invalid message protocol`; the
  provisioning script USB-resets it first for this reason.
- `scripts/goodix-521d-provision.sh` ends in `ValueError: Invalid OTP` **even on
  success** — that is its image-capture demo running after the PSK is written.
  Re-running it means erasing and reflashing the sensor again for nothing.

## Commits

- `3ac9d7c` graft goodixtls onto libfprint 1.94.10 + enable fprintd
- `019b4d8` pinned sensor provisioning script
- `94ce7d4` USB-reset the sensor before provisioning
- `2db2ec5` note the harmless trailing OTP error
- `82edbd1` press-capture fix (average frames, drop swipe stitching) + PGM dump
  — **untested against hardware**

## If this is abandoned

Set `services.fprintd.enable = false` in `modules/hosts/g14.nix` with a comment.
Leave the libfprint graft and the provisioning script in place — they are
correct and the sensor is already provisioned, so re-enabling is one boolean if
the driver ever improves. Do not leave it enabled-but-broken: `fprintAuth`
defaults to `services.fprintd.enable`, so every sudo and every login would wait
on a finger that cannot match before falling back to the password.
