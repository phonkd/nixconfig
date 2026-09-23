#!/usr/bin/env python3
"""Stop the Fosi MC331's DSP noise gate chopping up quiet passages.

The MC331 gates its output aggressively out of the factory, which audibly cuts
the tails off fade-outs, film ambience and anything played quietly. The setting
lives in the BP1048B2 DSP and is writable over USB -- but the amp's MCU reloads
the factory parameter set into the DSP at every power-on, so there is nothing to
configure once: the frame has to be re-sent whenever the amp comes back.

Two things about this took real work to find, and both are easy to get wrong:

1. Transport. The amp's tuning interface advertises *zero* endpoints, so usbhid
   never binds it and no /dev/hidraw node exists for it. Everything goes as a
   USB control transfer (SET_REPORT on ep0) through libusb. Its interface number
   also moves with the input selector: on OPT/AUX/BT (PID 171E) the amp exposes
   only that interface, number 0; on USB (PID 1717) it is also a USB-Audio
   device, so 0 and 1 are audio (held by snd-usb-audio), 2 is Consumer Control
   (the remote's keys), and the tuning interface is 3. Hence "HID class with no
   endpoints" as the selector rather than a hardcoded number.

2. Framing. The payload must keep its leading 0x00 byte *in the data stage* and
   be padded to exactly 65 bytes. The HID spec says that byte is the report ID
   and belongs in wValue, and the ESP32 community firmware duly strips it -- but
   this amp scans the raw report buffer, so a stripped frame arrives shifted by
   one byte and is silently discarded. The amp ACKs it either way, which makes
   the failure invisible: every threshold from -1 to -1000 dB, every report
   length (17/64/256), both report types and both HID interfaces were accepted
   and ignored until the leading byte was put back.

The default payload is the community Android app's verbatim, the only framing
confirmed working on this unit:
github.com/CaseresMaxi/fosi_MC331_fix -- HidSender.kt + Constants.kt.

Exits 0 when the amp isn't there, so the systemd timer is a no-op while the amp
is off rather than a recurring failure.
"""

import sys

import usb.core
import usb.util

VID = 0x8888
PIDS = (0x1717, 0x171E)  # 1717 = input selector on USB, 171E = OPT/AUX/BT

SET_REPORT = 0x09
REPORT_TYPES = (("Output", 0x02), ("Feature", 0x03))

# Exactly what the Android app sends. The leading 0x00 is part of the data.
REPORT_BYTES = 65

# The app's own values, and the ones proven on this amp. Note the threshold is
# the *stock* -68 dB, so it is the flags byte rather than the threshold that
# appears to call the gate off -- the app calls this payload "disable the music
# noise suppressor". Both are overridable for experimenting now that the framing
# is right.
DEFAULT_THRESHOLD_DB = -68.0
DEFAULT_FLAGS = 0xFF


def crc8(data):
    """CRC-8, poly 0x07, init 0x00, no reflection, no final xor."""
    crc = 0
    for byte in data:
        crc ^= byte
        for _ in range(8):
            crc = ((crc << 1) ^ 0x07) & 0xFF if crc & 0x80 else (crc << 1) & 0xFF
    return crc


def packet(db, flags):
    """Noise-suppressor (page 0x88) report, ready for the data stage.

    Leading 0x00, A5 5A framing, command 0x88, 11 payload bytes, CRC-8 over
    those 11 only, zero-padded to the full report length. The threshold is a
    signed int16 LE in hundredths of a dB.
    """
    threshold = int(round(db * 100)) & 0xFFFF
    payload = [
        flags,
        0x00,
        0x00,
        threshold & 0xFF,
        threshold >> 8,
        0x03,
        0x00,
        0x05,
        0x00,
        0x64,
        0x00,
    ]
    frame = [0x00, 0xA5, 0x5A, 0x88, 0x0B] + payload + [crc8(payload)]
    return bytes(frame).ljust(REPORT_BYTES, b"\0")


def hid_interfaces(dev):
    """HID interfaces, the endpoint-less tuning one first.

    Zero endpoints is what identifies the tuning interface -- and is why usbhid
    won't bind it. The others are tried only as a fallback, so the remote's
    interface isn't detached from usbhid on every run for nothing.
    """
    found = {}
    for cfg in dev:
        for intf in cfg:
            if intf.bInterfaceClass == 0x03:
                found.setdefault(intf.bInterfaceNumber, intf.bNumEndpoints)
    return sorted(found, key=lambda num: (found[num] != 0, num))


def send(dev, interface, report):
    """Try Output then Feature on one interface. Returns True if either lands."""
    detached = False
    try:
        if dev.is_kernel_driver_active(interface):
            dev.detach_kernel_driver(interface)
            detached = True
    except Exception:
        pass

    try:
        for name, rtype in REPORT_TYPES:
            try:
                sent = dev.ctrl_transfer(
                    0x21, SET_REPORT, (rtype << 8) | 0x00, interface, report, 2000
                )
            except Exception as err:
                print("interface %d %s: %s" % (interface, name, err))
                continue
            print("interface %d %s: sent %d bytes" % (interface, name, sent))
            return True
        return False
    finally:
        if detached:
            try:
                usb.util.dispose_resources(dev)
                dev.attach_kernel_driver(interface)
            except Exception:
                pass


def main():
    args = sys.argv[1:]
    flags = DEFAULT_FLAGS
    if "--flags" in args:
        i = args.index("--flags")
        flags = int(args[i + 1], 0)
        del args[i:i + 2]
    db = float(args[0]) if args else DEFAULT_THRESHOLD_DB

    dev = None
    for pid in PIDS:
        dev = usb.core.find(idVendor=VID, idProduct=pid)
        if dev is not None:
            break
    if dev is None:
        print("MC331 not on the bus, nothing to do")
        return 0

    interfaces = hid_interfaces(dev)
    if not interfaces:
        sys.exit("no HID interface on %04x:%04x" % (dev.idVendor, dev.idProduct))

    report = packet(db, flags)
    print("device %04x:%04x  flags 0x%02X  threshold %.2f dB  frame %s"
          % (dev.idVendor, dev.idProduct, flags, db, report[:17].hex()))

    for interface in interfaces:
        if send(dev, interface, report):
            return 0

    # Usually means something else holds the interface -- it is single-owner.
    sys.exit("no HID interface accepted the report")


if __name__ == "__main__":
    sys.exit(main())
