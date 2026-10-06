#!/usr/bin/env python3

import os
import sys
import threading
import time

sys.path.insert(0, "/usr/lib/steamac/frankensense")

from hidtools.device.sony_gamepad import PS5ControllerUSB

PORT = "/dev/virtio-ports/steamac.gamepad"

# Linux input codes emitted by the host's PlayStation PadState.
BTN_SOUTH    = 0x130
BTN_EAST     = 0x131
BTN_NORTH    = 0x133
BTN_WEST     = 0x134
BTN_TL       = 0x136
BTN_TR       = 0x137
BTN_TL2      = 0x138
BTN_TR2      = 0x139
BTN_SELECT   = 0x13A
BTN_START    = 0x13B
BTN_MODE     = 0x13C
BTN_THUMBL   = 0x13D
BTN_THUMBR   = 0x13E
BTN_TOUCHPAD = 0x2C0

ABS_X     = 0x00
ABS_Y     = 0x01
ABS_Z     = 0x02
ABS_RX    = 0x03
ABS_RY    = 0x04
ABS_RZ    = 0x05
ABS_HAT0X = 0x10
ABS_HAT0Y = 0x11


def parse_state(command):
    if not command.startswith("STATE "):
        return None

    fields = {}

    for part in command[6:].split():
        key, sep, value = part.partition("=")
        if sep:
            fields[key] = value

    buttons = set()
    raw_buttons = fields.get("buttons", "")

    if raw_buttons:
        buttons = {int(v) for v in raw_buttons.split(",") if v}

    axes = {}
    raw_axes = fields.get("axes", "")

    if raw_axes:
        for item in raw_axes.split(","):
            key, sep, value = item.partition("=")
            if sep:
                axes[int(key)] = int(value)

    return buttons, axes


def stick8(value):
    value = max(-32767, min(32767, value))
    return max(0, min(255, round((value + 32767) * 255 / 65534)))


def trigger8(value):
    return max(0, min(255, value))


def hat_value(x, y):
    # HID hat: 0=N, 1=NE, 2=E ... 7=NW, 15=neutral.
    return {
        (0, -1): 0,
        (1, -1): 1,
        (1, 0): 2,
        (1, 1): 3,
        (0, 1): 4,
        (-1, 1): 5,
        (-1, 0): 6,
        (-1, -1): 7,
        (0, 0): 15,
    }.get((x, y), 15)


def send_state(dev, buttons, axes):
    # PadState's PlayStation face-button codes are intentionally shuffled for
    # the legacy virtio path. Translate them back to native DualSense buttons.
    ds_buttons = {
        1: BTN_SOUTH in buttons,   # Square
        2: BTN_EAST in buttons,    # Cross
        3: BTN_NORTH in buttons,   # Circle
        4: BTN_WEST in buttons,    # Triangle
        5: BTN_TL in buttons,      # L1
        6: BTN_TR in buttons,      # R1
        7: BTN_TL2 in buttons,     # L2
        8: BTN_TR2 in buttons,     # R2
        9: BTN_SELECT in buttons,  # Create
        10: BTN_START in buttons,  # Options

        # Legacy PS5 virtio mapping:
        # MODE=physical L3, THUMBL=physical R3, THUMBR=physical PS.
        11: BTN_MODE in buttons,   # L3
        12: BTN_THUMBL in buttons, # R3
    }

    report = bytearray(
        dev.create_report(
            left=(
                stick8(axes.get(ABS_X, 0)),
                stick8(axes.get(ABS_Y, 0)),
            ),
            right=(
                stick8(axes.get(ABS_Z, 0)),
                stick8(axes.get(ABS_RZ, 0)),
            ),
            hat_switch=hat_value(
                axes.get(ABS_HAT0X, 0),
                axes.get(ABS_HAT0Y, 0),
            ),
            buttons=ds_buttons,
        )
    )

    # DualSense USB report 0x01:
    # bytes 5/6 = analog L2/R2.
    report[5] = trigger8(axes.get(ABS_RX, 0))
    report[6] = trigger8(axes.get(ABS_RY, 0))

    # Byte 10:
    # bit 0 = PS
    # bit 1 = physical touchpad click
    if BTN_THUMBR in buttons:
        report[10] |= 0x01
    else:
        report[10] &= ~0x01

    if BTN_TOUCHPAD in buttons:
        report[10] |= 0x02
    else:
        report[10] &= ~0x02

    dev.call_input_event(bytes(report))


def transport_reader(dev):
    print(f"Listening on {PORT}", flush=True)

    with open(PORT, "rb", buffering=0) as port:
        buffer = bytearray()

        while True:
            chunk = port.read(4096)

            if not chunk:
                time.sleep(0.05)
                continue

            buffer.extend(chunk)

            while b"\n" in buffer:
                raw, _, rest = buffer.partition(b"\n")
                buffer = bytearray(rest)

                command = raw.decode("utf-8", errors="replace").strip()

                if not command:
                    continue

                state = parse_state(command)

                if state is None:
                    print(f"Ignoring unknown host command: {command}", flush=True)
                    continue

                buttons, axes = state
                send_state(dev, buttons, axes)


def wait_for_transport():
    print(f"Waiting for {PORT}...", flush=True)

    while not os.path.exists(PORT):
        time.sleep(0.25)

    print(f"Transport available: {PORT}", flush=True)


def main():
    print("Steamac FrankenSense bridge starting...", flush=True)

    wait_for_transport()

    dev = PS5ControllerUSB()
    dev.create_kernel_device()

    print("UHID DualSense created.", flush=True)

    reader = threading.Thread(
        target=transport_reader,
        args=(dev,),
        daemon=True,
    )
    reader.start()

    try:
        while True:
            dev.dispatch(100)
    except KeyboardInterrupt:
        print("\nStopping bridge.", flush=True)
    finally:
        dev.destroy()


if __name__ == "__main__":
    main()
