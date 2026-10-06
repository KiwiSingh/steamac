#!/bin/env python3
# -*- coding: utf-8 -*-
#
# Copyright (c) 2018 Red Hat, Inc.
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#

import click
import select
import sys
import os

from hidtools.hidraw import HidrawDevice


def list_devices():
    outfile = sys.stdout if os.isatty(sys.stdout.fileno()) else sys.stderr
    devices = {}
    for fname in os.listdir("/dev/"):
        if not fname.startswith("hidraw"):
            continue

        with open(f"/dev/{fname}") as f:
            d = HidrawDevice(f)
            devices[int(fname[6:])] = d.name

    if not devices:
        print("No devices found", file=sys.stderr)
        sys.exit(1)

    print("Available devices:", file=outfile)
    for num, name in sorted(devices.items()):
        print(f"/dev/hidraw{num}:	{name}", file=outfile)

    lo = min(devices.keys())
    hi = max(devices.keys())

    print(
        f"Select the device event number [{lo}-{hi}]: ",
        end="",
        flush=True,
        file=outfile,
    )
    try:
        num = int(sys.stdin.readline())
        if num < lo or num > hi:
            raise ValueError
        return f"/dev/hidraw{num}"
    except ValueError:
        print("Invalid device", file=sys.stderr)
        sys.exit(1)


@click.command()
@click.option(
    "--output",
    metavar="output-file",
    default=sys.stdout,
    nargs=1,
    type=click.File("w"),
    help="The file to record to (default: stdout)",
)
@click.argument(
    "device_list",
    metavar="<Path to the hidraw device node(s)>",
    nargs=-1,
    type=click.File("r"),
)
def main(device_list, output):
    """Record a HID device"""

    devices = {}
    last_index = -1
    poll = select.poll()
    is_first_event = True

    try:
        if not device_list:
            device_list = [open(list_devices())]

        for idx, fd in enumerate(device_list):
            device = HidrawDevice(fd)
            if len(device_list) > 1:
                print(f"D: {idx}", file=output)
            device.dump(output)
            poll.register(fd, select.POLLIN)
            devices[fd.fileno()] = (idx, device)

        if len(devices) == 1:
            last_index = 0

        while True:
            events = poll.poll()
            for fd, event in events:
                idx, device = devices[fd]
                device.read_events()
                if last_index != idx:
                    print(f"D: {idx}", file=output)
                    last_index = idx
                device.dump(output)

                if is_first_event:
                    is_first_event = False
                    for idx, d in devices.values():
                        d.time_offset = device.time_offset

    except PermissionError:
        print("Insufficient permissions, please run me as root.", file=sys.stderr)
    except KeyboardInterrupt:
        pass
    except OSError as e:
        print(f"{str(e)}", file=sys.stderr)


if __name__ == "__main__":
    if sys.version_info < (3, 6):
        sys.exit("Python 3.6 or later required")

    main()
