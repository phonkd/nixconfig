#!/usr/bin/env python3
"""Lower the Fosi MC331's DSP noise-suppressor threshold.

The MC331 gates its output at -68 dB out of the factory, which audibly chops
the tails off quiet passages. The threshold lives in the BP1048B2 DSP and can
be rewritten over USB -- but the amp's MCU reloads the factory parameter set on
every power-on, so this has to be re-sent each time rather than configured once.

Transport note: the amp's HID interface advertises *zero* endpoints, so usbhid
never binds it and no /dev/hidraw node exists for it. The report therefore goes
out as a USB control transfer (SET_REPORT on ep0) via libusb, Output report
first and Feature as a fallback -- the same thing the ESP32 community firmware
does. See plans/fosi-mc331-noise-gate.md for the decoded frame format.

Exits 0 when the amp simply isn't there, so the systemd timer is a no-op while
the amp is off rather than a recurring failure.
"""

import sys

import usb.core

VID = 0x8888
PIDS = (0x1717, 0x171E)  # 1717 = input selector on USB, 171E = OPT/AUX/BT

SET_REPORT = 0x09
GET_DESCRIPTOR = 0x06
HID_REPORT_DESC = 0x22
REPORT_TYPES = (("Output", 0x02), ("Feature", 0x03))

# What interface 3 declares on this amp. Used when the descriptor can't be read.
DEFAULT_OUTPUT_BYTES = 256


def crc8(data):
    """CRC-8, poly 0x07, init 0x00, no reflection, no final xor."""
    crc = 0
    for byte in data:
        crc ^= byte
        for _ in range(8):
            crc = ((crc << 1) ^ 0x07) & 0xFF if crc & 0x80 else (crc << 1) & 0xFF
    return crc


def packet(db, enable=0xFF):
    """Noise-suppressor (page 0x88) frame, minus the leading report-ID byte.

    The report ID (0x00) travels in wValue of the control transfer rather than
    in the data stage. Threshold is a signed int16 LE in hundredths of a dB.
    """
    threshold = int(round(db * 100)) & 0xFFFF
    payload = [
        enable,
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
    return bytes([0xA5, 0x5A, 0x88, 0x0B] + payload + [crc8(payload)])


def tuning_interface(dev):
    """Find the DSP tuning interface: HID class, and no endpoints.

    Its interface number moves with the amp's input selector, so it has to be
    discovered rather than hardcoded:

      OPT/AUX/BT (PID 171E)  the amp exposes this one interface only -> number 0
      USB        (PID 1717)  it is a USB-Audio device as well, so the layout is
                             0 audio control + 1 audio streaming (both held by
                             snd-usb-audio), 2 a real HID interface held by
                             usbhid, and 3 this one -> number 3

    Hardcoding 0 therefore worked over Bluetooth but hit snd-usb-audio's claim
    on the audio control interface over USB, failing with EBUSY. Zero endpoints
    is the distinguishing property: it is why usbhid won't bind this interface,
    which is in turn why everything has to go through control transfers.

    Iterating the device walks the cached configuration descriptors;
    get_active_configuration() would open a handle and so need root just to
    answer a question the descriptors already contain.
    """
    numbers = {
        intf.bInterfaceNumber
        for cfg in dev
        for intf in cfg
        if intf.bInterfaceClass == 0x03 and intf.bNumEndpoints == 0
    }
    return min(numbers) if numbers else None


def output_report_size(dev, interface):
    """How many bytes the interface's Output report is declared to be.

    This matters more than it looks. The amp declares a 256-byte vendor Output
    report, and a short transfer is ACKed and then silently dropped -- which is
    precisely what happened while this sent 64 bytes: the amp reported every
    frame as accepted and the DSP never saw one, at any threshold. hidapi pads
    a report out to its declared length for you, so every community tool got
    this for free; a hand-rolled control transfer has to do it itself.

    Read from the report descriptor rather than hardcoded, since the interface
    layout already turned out to differ between this amp's two modes.
    """
    try:
        raw = bytes(
            dev.ctrl_transfer(
                0x81, GET_DESCRIPTOR, (HID_REPORT_DESC << 8) | 0, interface, 4096, 2000
            )
        )
    except Exception:
        return DEFAULT_OUTPUT_BYTES

    size = count = None
    i = 0
    while i < len(raw):
        head = raw[i]
        length = head & 0x03
        length = 4 if length == 3 else length
        value = int.from_bytes(raw[i + 1:i + 1 + length], "little") if length else 0
        tag, kind = (head >> 4) & 0x0F, (head >> 2) & 0x03
        if kind == 1 and tag == 0x7:  # Global / REPORT_SIZE
            size = value
        elif kind == 1 and tag == 0x9:  # Global / REPORT_COUNT
            count = value
        elif kind == 0 and tag == 0x9 and size and count:  # Main / OUTPUT
            return (size * count) // 8
        i += 1 + length
    return DEFAULT_OUTPUT_BYTES


def main():
    # `--off` clears the flags byte instead of just lowering the threshold, i.e.
    # switches the suppressor off rather than moving its trigger point. Several
    # people on the vendor forum report that only the full disable cures the
    # cut-off for them. The byte's meaning is inferred, not documented -- but it
    # is the one byte that differs, the frame still carries a valid CRC, and the
    # amp reloads factory defaults on its next power-on regardless.
    args = sys.argv[1:]
    enable = 0xFF
    if "--off" in args:
        enable = 0x00
        args.remove("--off")
    db = float(args[0]) if args else -90.0

    dev = None
    for pid in PIDS:
        dev = usb.core.find(idVendor=VID, idProduct=pid)
        if dev is not None:
            break
    if dev is None:
        print("MC331 not on the bus, nothing to do")
        return 0

    interface = tuning_interface(dev)
    if interface is None:
        sys.exit("no endpoint-less HID interface on %04x:%04x -- cannot tune"
                 % (dev.idVendor, dev.idProduct))

    frame = packet(db, enable)
    report_bytes = output_report_size(dev, interface)
    print("device %04x:%04x  interface %d  report %dB  suppressor %s  threshold %.2f dB  frame %s"
          % (dev.idVendor, dev.idProduct, interface, report_bytes,
             "off" if enable == 0x00 else "on", db, frame.hex()))

    data = frame.ljust(report_bytes, b"\0")
    for name, rtype in REPORT_TYPES:
        try:
            sent = dev.ctrl_transfer(
                0x21, SET_REPORT, (rtype << 8) | 0x00, interface, data, 2000
            )
        except Exception as err:  # usb.core.USBError and friends
            print("%s report failed: %s" % (name, err))
            continue
        print("%s report accepted (%d bytes)" % (name, sent))
        return 0

    # Usually means something else holds the interface -- it is single-owner.
    sys.exit("both Output and Feature SET_REPORT failed")


if __name__ == "__main__":
    sys.exit(main())
