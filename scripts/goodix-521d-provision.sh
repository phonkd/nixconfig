#!/usr/bin/env bash
#
# One-shot provisioning for the g14's Goodix 27c6:521d fingerprint sensor.
#
# WHY THIS EXISTS
# ---------------
# modules/hosts/g14.nix builds libfprint with the reverse-engineered `goodixtls`
# driver, which is the only thing that drives a 521d. That driver talks to the
# sensor over TLS-PSK and only knows ONE key: the all-zero PSK (whose SHA-256,
# 66687aad..., is what it compares against). A factory sensor ships with its own
# provisioned PSK, and reading it back returns only a hash -- the secret itself
# is unrecoverable. So fprintd gets as far as opening the device and then fails:
#
#   fprintd[...]: failed during activation: Invalid device PSK: 0x<hash> (code: 35)
#
# The only known fix is to reprovision the sensor with the white-box PSK that
# hashes to the all-zero value, using goodix-fp-linux-dev/goodix-fp-dump.
#
# WHAT IT DOES TO YOUR HARDWARE -- READ THIS
# ------------------------------------------
# On this sensor's firmware (GFUSB_GM168SEC_APP_10019) the tool cannot write the
# PSK in place. Its flow is: ERASE the sensor firmware -> drop to IAP mode ->
# write the white-box PSK -> REFLASH the firmware. Notes:
#
#   * The firmware image it reflashes is the SAME version already on the device,
#     pinned below by commit and verified by sha256 before anything is erased.
#   * It is IRREVERSIBLE: the factory PSK cannot be restored, because it was
#     never readable in the first place.
#   * It will break Windows Hello fingerprint if you dual-boot. (Windows may
#     re-provision its own PSK, which would then break Linux again.)
#   * Upstream's own warning is "This program might break your device ...
#     don't hold us responsible if your device is broken!"
#
# HOW TO RUN
#
#   ./scripts/goodix-521d-provision.sh   # NOT under sudo -- it re-execs itself
#
# It stops fprintd and USB-resets the sensor itself before starting, so a
# previous failed enrol attempt doesn't leave the sensor desynced.
#
# Run it as yourself: it builds the python environment with nix first (sudo
# would clear NIX_PATH), then re-execs under sudo so only the resolved
# interpreter touches the device. You'll get a sudo password prompt.
#
# The tool asks you to type a random number to confirm. Once it prints
# "Valid PSK: True" and the firmware is back to GFUSB_GM168SEC_APP_10019, the
# provisioning is done -- it then moves on to capturing a test image, which you
# can Ctrl-C. Afterwards:
#
#   sudo systemctl start fprintd
#   fprintd-enroll                       # as your own user, NOT under sudo
#
set -euo pipefail

TOOL_REPO="https://github.com/goodix-fp-linux-dev/goodix-fp-dump.git"
TOOL_REV="cc43bb3b3154a0bccc0412ae024013c7e1923139"
FW_REPO="https://github.com/goodix-fp-linux-dev/goodix-firmware.git"
FW_REV="7b9a828d1d14dee587d9c900505233188c23a92d"
FW_FILE="52xd/GFUSB_GM168SEC_APP_10019.bin"
FW_SHA256="6ff41957f387160c089559dffff6e8a26d1fa344d01bdaa6d62c5dab61883804"

device_present() {
  local d
  for d in /sys/bus/usb/devices/*/idVendor; do
    [ -r "$d" ] || continue
    if [ "$(cat "$d")" = "27c6" ] && [ "$(cat "${d%idVendor}idProduct")" = "521d" ]; then
      return 0
    fi
  done
  return 1
}

if [ "$(id -u)" -ne 0 ]; then
  # Phase 1, as the invoking user. Everything that needs the network, nix, or
  # NIX_PATH happens here -- sudo clears the environment, and root should not
  # be fetching code off the internet anyway.
  if ! device_present; then
    echo "error: no 27c6:521d device found on USB." >&2
    exit 1
  fi

  echo ">> building python environment (as $USER)"
  pyenv="$(nix-build --no-out-link \
    -E 'with import <nixpkgs> {}; python3.withPackages(p: [ p.pyusb p.crcmod p.pycryptodome p.crccheck p.spidev p.python-periphery ])')"
  # .bin explicitly: openssl is multi-output, and nix-build prints one line per
  # installed output, which would corrupt the capture if that set ever changes.
  sslpkg="$(nix-build --no-out-link -E 'with import <nixpkgs> {}; openssl.bin')"

  workdir="$(mktemp -d)"
  echo ">> fetching pinned tool + firmware"
  git clone --quiet "$TOOL_REPO" "$workdir/tool"
  git -C "$workdir/tool" checkout --quiet "$TOOL_REV"
  git clone --quiet "$FW_REPO" "$workdir/tool/firmware"
  git -C "$workdir/tool/firmware" checkout --quiet "$FW_REV"

  echo ">> verifying firmware image before anything is erased"
  actual="$(sha256sum "$workdir/tool/firmware/$FW_FILE" | cut -d' ' -f1)"
  if [ "$actual" != "$FW_SHA256" ]; then
    echo "error: firmware checksum mismatch -- refusing to continue." >&2
    echo "       expected $FW_SHA256" >&2
    echo "       got      $actual" >&2
    rm -rf "$workdir"
    exit 1
  fi
  echo "   ok: $FW_FILE"

  echo ">> re-execing under sudo"
  exec sudo "$0" "$pyenv" "$sslpkg" "$workdir"
fi

# Phase 2, as root. No network, no nix -- just the pre-resolved store paths.
if [ $# -ne 3 ]; then
  echo "error: run this as your normal user, not under sudo -- it re-execs itself." >&2
  exit 1
fi
pyenv="$1"
sslpkg="$2"
workdir="$3"
trap 'rm -rf "$workdir"' EXIT

for required in "$pyenv/bin/python" "$sslpkg/bin/openssl" "$workdir/tool/run_521d.py"; do
  if [ ! -e "$required" ]; then
    echo "error: expected $required to exist" >&2
    exit 1
  fi
done

systemctl=/run/current-system/sw/bin/systemctl
if [ -x "$systemctl" ] && "$systemctl" is-active --quiet fprintd; then
  echo ">> stopping fprintd (it holds the device)"
  "$systemctl" stop fprintd
fi

# A failed fprintd activation leaves the sensor mid-conversation: its next reply
# no longer lines up with what the tool expects, and goodix-fp-dump dies with
# "Invalid message protocol" on the very first firmware_version() call. A USB
# port reset puts it back to a clean state -- same effect as replugging, which
# is not an option for an internal device.
echo ">> resetting the sensor over USB to clear stale state"
"$pyenv/bin/python" - <<'PY'
import sys
import usb.core

dev = usb.core.find(idVendor=0x27C6, idProduct=0x521D)
if dev is None:
    sys.exit("error: 27c6:521d disappeared from USB")
try:
    dev.reset()
except Exception as exc:
    sys.exit(f"error: USB reset failed: {type(exc).__name__}: {exc}")
print("   usb reset ok")
PY
sleep 2

cd "$workdir/tool"
echo ">> handing over to goodix-fp-dump"
export PATH="$sslpkg/bin:$PATH"   # run_driver() shells out to `openssl s_server`
exec "$pyenv/bin/python" run_521d.py
