# auto-brightness on z14

**Repo(s):** nixconfig   **Status:** done — both halves are on `main`. The
sensor is live and wluma consumes it.

## Verdict

**Yes, auto-brightness can work on this laptop.** The Zenbook 14 UM3406GA has a
real ambient light sensor, the kernel already has a driver bound to it, and the
backlight is writable from the user session without any new udev rule. None of
the three things that usually kill this feature on a Linux laptop are wrong
here.

The symptom that prompted the question — `in_illuminance_raw` reading a flat `0`
— is not a broken sensor. **The sensor was asleep because nothing had ever asked
it for a reading.**

## The hardware, measured

```
$ cat /sys/class/backlight/amdgpu_bl1/max_brightness
399000
$ ls /sys/bus/iio/devices/
iio:device0 -> ../../../devices/0020:1022:0001.0002/HID-SENSOR-200041.2.auto/iio:device0
trigger0
$ cat /sys/bus/iio/devices/iio:device0/name
als
```

`HID-SENSOR-200041` is the HID usage ID for an ambient light sensor, behind the
AMD sensor-fusion hub. The device exposes more than just lux:

```
in_illuminance_raw        in_illuminance_scale (0.1)   in_illuminance_offset
in_colortemp_raw          in_chromaticity_x_raw        in_chromaticity_y_raw
in_intensity_both_raw     + an industrialio triggered buffer (buffer/, scan_elements/)
```

So the panel could in principle drive adaptive colour temperature too, not only
brightness. That is out of scope here but worth knowing the channels exist.

## Why it read zero

Polling the sysfs value directly gave the same answer every time, while the
colour-temperature channel returned a plausible 4500:

```
$ for i in 1 2 3; do echo "raw=$(cat .../in_illuminance_raw) colortemp=$(cat .../in_colortemp_raw)"; done
raw=0 colortemp=4500
raw=0 colortemp=4500
raw=0 colortemp=4500
```

The giveaway is one attribute over:

```
$ cat /sys/bus/iio/devices/iio:device0/in_illuminance_sampling_frequency
0.000000
```

A sampling frequency of zero means the HID sensor is not being polled at all.
These sensors are powered down until a consumer opens the device and asks for a
rate — at which point the driver starts sampling and `_raw` becomes live. Until
then it hands back its initial value, which is `0`, forever. This is a normal
idle state, not a fault, and it is why "cat the sysfs file" is a misleading test
for whether an ALS works.

And there was no consumer. Nothing on the host was holding the device open:

```
$ systemctl status iio-sensor-proxy
Unit iio-sensor-proxy.service could not be found.
$ busctl introspect net.hadess.SensorProxy /net/hadess/SensorProxy
Failed to introspect ... The name is not activatable
```

`grep -rn 'hardware.sensor\|iio-sensor' modules/` matched nothing either, so this
was never configured on any host in this repo — z14 is simply the first machine
here with a sensor worth using.

## The backlight half is already solved

The usual second obstacle is permissions: `/sys/class/backlight/*/brightness` is
root-owned, and the user is **not** in a `video` group (`id -nG` gives
`phonkd wheel dialout networkmanager`). Writing the file directly is refused.

`brightnessctl` works anyway, because it goes through logind rather than the
filesystem:

```
$ brightnessctl set 51870
Device 'amdgpu_bl1' of class 'backlight':
	Current brightness: 51870 (13%)
	Max brightness: 399000
```

So no udev rule and no group change is needed — the existing `Super+I` /
`Super+Shift+I` binds in `modules/hyprland.nix` already prove the write path,
and anything driving the backlight automatically can use the same route.

Note the range: `max_brightness` is 399000, not 100 or 255. Anything written
against this panel has to work in percentages or scale to that number.

## What landed

`hardware.sensor.iio.enable = true` in `modules/hosts/z14.nix`. That is the
NixOS option for iio-sensor-proxy, the daemon that claims the device, sets a
sampling rate and republishes readings on D-Bus as `net.hadess.SensorProxy`.

It is the right thing to enable regardless of what eventually consumes it, for
two reasons: it is the prerequisite for *every* option below, and it is the
interface GNOME's and KDE's own auto-brightness already speak — so it commits to
nothing. On its own it changes no screen behaviour; it only makes the sensor
readable.

**This needs a rebuild to take effect, and the reading should be confirmed
afterwards** — see Open question.

## Recommendation for the backlight half

`wluma` (4.10.0 in nixpkgs, confirmed resolvable) is the one to use. It is the
Wayland-native answer and the one that fits this session:

- It talks to the ALS and to the backlight directly, with no desktop
  environment in the loop — which matters, because Hyprland provides none of the
  GNOME/KDE plumbing that normally does this job.
- It *learns*: rather than shipping a fixed lux→brightness curve, it watches the
  brightness you set by hand at a given light level and converges on your
  preference. That suits a manual `Super+I` habit that already exists instead of
  fighting it.
- It can additionally dim on screen *contents* (a dark terminal vs. a white
  page). That is a real feature on an OLED panel, and also the thing most likely
  to feel wrong at first — it is separately configurable.

Rejected:

- **clight/clightd** — wants geoclue and a dbus service of its own for sunrise
  and sunset maths; more moving parts than this needs.
- **A hand-rolled systemd user timer** polling the IIO device and calling
  `brightnessctl` — perfectly possible now that the sensor works, but it is a
  hand-tuned curve nobody will maintain, and it duplicates wluma badly.
- **GNOME/KDE built-in auto-brightness** — not applicable; z14 runs Hyprland and
  has no Plasma session at all (`desktop = "hyprland"` in `lib/registry.nix`).

Deliberately **not** enabled in the same change as the sensor. Auto-brightness is
a continuous, opinionated change to how the screen behaves all day, and whether
it is pleasant is a matter of taste rather than correctness — unlike everything
above it, which is just "make the hardware work". Flipping it is a one-line
follow-up once the sensor is confirmed live.

> **Since superseded.** The sensor was confirmed live and wluma landed in
> `modules/hosts/z14.nix`. It was not a one-liner: see the next section for the
> config and unit nixpkgs does not install, and for the threshold rescaling the
> sensor's 0.1 scale forced.

## What the wluma half needed, and the two surprises in it

`services.udev` rules and the `video` group are **not** part of this, though
every wluma guide prescribes them. `Backlight::new` probes the sysfs file by
writing its own value back to it and only falls through to
`org.freedesktop.login1.Session.SetBrightness` when that fails — which it does
here, `brightness` being `root:root 0644`. That D-Bus path is the same one
`brightnessctl` and the existing `Super+I` binds use, and it works because the
caller owns the active session, not because of any group. Confirmed by running
wluma as `phonkd` (groups: `dialout wheel networkmanager`):

```
Using DBUS for /sys/class/backlight/amdgpu_bl1 to change brightness value
```

Adding the rule would only flip it to the direct-write branch and leave the
backlight group-writable in exchange for nothing.

**The ALS thresholds had to be rescaled.** wluma computes lux the way IIO
does — `(in_illuminance_raw + offset) * scale` — and this sensor's scale is
`0.1`, offset `0`. A lit room at night reads `raw=17`, i.e. 1.7 lux, which
wluma casts to `u64` as `1`. Upstream's default ladder does not leave `night`
until 20 lux, so the panel would have sat in the darkest profile permanently
and wluma would have had exactly one bucket to learn in. Compressed onto the
range this sensor actually produces:

```toml
thresholds = { 0 = "night", 1 = "dark", 3 = "dim", 10 = "normal", 30 = "bright", 100 = "outdoors" }
```

The bright end is extrapolated — it cannot be measured from a shell at night.
To retune, read `in_illuminance_raw` in the conditions that feel mis-graded,
divide by 10, and move the neighbouring threshold. Getting one wrong degrades
gently: thresholds only bucket the sensor, and wluma still learns a preferred
brightness inside each bucket.

## The open question is answered: the sensor tracks

It was not confirmable at the time of writing, needing someone to watch the
number move. It moved on its own between two readings an hour apart, and the
sampling frequency is no longer pinned:

```
in_illuminance_sampling_frequency   10.000000   (was 0.000000)
in_illuminance_raw                  2  →  17     (was pinned at 0)
iio-sensor-proxy                    active
net.hadess.SensorProxy HasAmbientLight  true
```

## Verification

wluma run against the generated `/etc/xdg/wluma/config.toml`, under the live
Hyprland session:

```
Detected support for wlr-screencopy-unstable-v1 protocol
Detected support for ext-image-copy-capture-v1 protocol
Using output 'Samsung Display Corp. ATNA40CT06-0   (eDP-1)' for config 'eDP-1'
Using ext-image-copy-capture-v1 protocol to request frames
Processing frame in DRM format XR24
[keyboard-asus] Learning Entry { lux: "dark", luma: 0, brightness: 3 }
[eDP-1] Learning Entry { lux: "dark", luma: 21, brightness: 191520 }
```

Both outputs learn, the capture path negotiates without being told which
protocol to use, and the rescaled thresholds put a lit night-time room in
`dark` rather than `night`.

`capturer = "wayland"` keeps protocol selection with wluma rather than naming
one, since Hyprland's support has moved over time. Screen-contents dimming is
left on: it is the half most likely to feel wrong at first, and on this OLED
also the half most worth having. `capturer = "none"` reverts to ALS-only and
changes nothing else.
