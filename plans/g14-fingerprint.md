# g14 fingerprint (Goodix 27c6:521d)

**Repo(s):** nixconfig   **Status:** closed — won't work, disabled deliberately

_Conclusion (2026-08-10):_ The driver works. The **sensor is too small to
authenticate with**, and no software change fixes that. `services.fprintd` is
left `enable = false` in `modules/hosts/g14.nix`; the driver graft, the patch
and the provisioning script all stay in place so re-enabling is one boolean if
a non-minutiae matcher ever appears.

## What was built, and it does work

| Stage | State |
|---|---|
| Driver claims device | works — `/net/reactivated/Fprint/Device/0` |
| Sensor PSK provisioned | done, irreversible (factory PSK overwritten) |
| Capture | works — clean 64x80 images, clear ridges |
| NBIS binarization | works — correctly thresholded parallel ridges |
| `fprintd-enroll` | completes, 5 stages |
| `fprintd-verify` | **never matches — and never can** |

Getting here took: grafting the abandoned `goodixtls` driver onto current
nixpkgs libfprint, reflashing the sensor's PSK, and fixing the driver's capture
path (it ran libfprint's *swipe* stitching on a *press* sensor, which smeared
every capture into an image three times too wide). All three were real problems
and all three are fixed. The captures at the end are genuinely good.

## Why it still cannot authenticate

libfprint matches with NBIS: `mindtct` extracts **minutiae** (ridge endings and
bifurcations), `bozorth3` scores how many two impressions share, and the driver
demands 24. Minutiae are the only thing that matters — a picture of ridges with
no endings or forks in it carries no identity.

Measured directly with `scripts/goodix-521d-minutiae-check.c` over 13 real
captures:

```
minutiae per capture: 0,0,1,0,0,1,2,2,2,2,2,0,2      (median 2)
```

That is not a capture-quality failure. The binarized images the tool dumps
alongside show clean, well-separated, correctly-thresholded ridges — detection
is working fine, there is simply almost nothing there to detect. The ridges run
edge to edge; they essentially never end or fork inside the window.

The geometry says this is exactly what should happen. Measuring the ridge period
in those binarized captures (perpendicular period **12.8 px**, ~5 ridges across
the 64 px width, consistent to within ±0.8 px across all captures) and taking
the human ridge period as 0.45 mm:

- effective resolution ≈ **28.5 px/mm (~720 dpi)**
- physical window ≈ **2.3 x 2.8 mm = 6.3 mm²**
- at a normal minutia density of 0.2–0.3 /mm², that window should contain
  **1.3–1.9 minutiae**

Predicted 1–2, observed 0–2. The model and the measurement agree, which is what
makes this a conclusion rather than a guess: **the features needed to
authenticate are not physically inside the sensor's window.** bozorth3 needs
roughly an order of magnitude more to reach 24. Hence the observed scores of 0,
occasionally 11 — that 11 is coincidence, not partial recognition.

This is why upstream libfprint declined the sensor. Windows Hello works on it
because Goodix's proprietary matcher is not minutiae-based; that algorithm is
not available to us and cannot be reimplemented from the captures.

**Do not lower `bz3_threshold` to make verification pass.** It is the one change
that would appear to work. With a noise floor of 0 and stray 11s, a threshold
admitting those authenticates on noise — and `fprintAuth` defaults to
`services.fprintd.enable`, so this sits in front of **sudo and sddm**.

## Reproducing the verdict

Captures come from the driver's `GOODIX52XD_DUMP` escape hatch; the analysis
tool is `scripts/goodix-521d-minutiae-check.c`. Both are documented in that
file's header, including the exact build command. It compiles clean with `-Wall`
against the patched libfprint and needs no hardware — only the `.pgm` dumps.

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
  not chase again. (It is also not the cause here: the ridge period shows the
  images are already at a sane scale for NBIS.)
- `rotate_frame()` in the driver is dead code (never called).
- The driver captures an empty background frame into `self->empty_img` and never
  uses it (`postprocess_frame()` is commented out). Irrelevant now — binarization
  is already clean, so background subtraction has nothing left to fix.
- The sensor keeps state across warm reboots. A failed activation leaves it
  desynced, and the next tool run dies with `Invalid message protocol`; the
  provisioning script USB-resets it first for this reason.
- `scripts/goodix-521d-provision.sh` ends in `ValueError: Invalid OTP` **even on
  success** — that is its image-capture demo running after the PSK is written.
  Re-running it means erasing and reflashing the sensor again for nothing.
- The sensor's **factory PSK is permanently gone**. It was never readable and
  has been overwritten. If this machine ever dual-boots Windows, Hello's
  fingerprint is broken there.

## Commits

- `3ac9d7c` graft goodixtls onto libfprint 1.94.10 + enable fprintd
- `019b4d8` pinned sensor provisioning script
- `94ce7d4` USB-reset the sensor before provisioning
- `2db2ec5` note the harmless trailing OTP error
- `82edbd1` press-capture fix (average frames, drop swipe stitching) + PGM dump
- `HEAD` disable fprintd with the minutiae measurement that settles it

## If someone wants to reopen this

The only thing that would change the answer is a matcher that does not rely on
minutiae — correlation or ridge-pattern based — since the images themselves are
fine and are reproducibly distinguishable to the eye. libfprint has no such
matcher and adding one is a research project, not a config change. Do not
reopen this by re-examining the driver; that part is finished and measured.
