#!/bin/env python3
# -*- coding: utf-8 -*-
#
# Copyright (c) 2017 Benjamin Tissoires <benjamin.tissoires@gmail.com>
# Copyright (c) 2017 Red Hat, Inc.
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

from datetime import datetime, timedelta
import click
import sys
import time
import hidtools.uhid
from parse import parse, findall

from hidtools.device.base_device import BaseDevice
from hidtools.device.sony_gamepad import PS3Controller
from typing import Tuple, Type

import logging

logging.basicConfig(format="%(levelname)s: %(name)s: %(message)s", level=logging.INFO)
base_logger = logging.getLogger("hidtools")
logger = logging.getLogger("hidtools.replay")


class HIDReplay(object):
    _known_devices: dict[Tuple[int, int], Type[BaseDevice]] = {
        (0x054C, 0x0268): PS3Controller
    }

    def __init__(self, filename):
        self._devices = {}
        self.filename = filename
        self.replayed_count = 0

        devices = {}
        dev = None
        with open(filename) as f:

            class DeviceInfo(object):
                def __init__(self):
                    self.name = None
                    self.info = None
                    self.phys = ""
                    self.rdesc = None
                    self.rdesc_length = None

            idx = 0
            for line in f:
                line = line.strip()
                if line.startswith("D:"):
                    r = parse("D: {idx:d}", line)
                    assert r is not None
                    idx = r["idx"]
                    continue
                if idx not in devices:
                    devices[idx] = DeviceInfo()
                dev = devices[idx]
                if line.startswith("N:"):
                    r = parse("N: {name}", line)
                    assert r is not None
                    dev.name = r["name"]
                elif line.startswith("I:"):
                    r = parse("I: {bus:x} {vid:x} {pid:x}", line)
                    assert r is not None
                    dev.info = r
                elif line.startswith("P:"):
                    r = parse("P: {phys}", line)
                    if r is not None:
                        dev.phys = r["phys"]
                elif line.startswith("R:"):
                    r = parse("R: {length:d} {desc}", line)
                    assert r is not None
                    dev.rdesc = r

        for idx, dev in devices.items():
            uhid_dev_class = self.determine_device_type_by_info(dev.info)
            uhid_dev = uhid_dev_class(
                name=dev.name,
                application=None,
                input_info=tuple([dev.info["bus"], dev.info["vid"], dev.info["pid"]]),
                rdesc=dev.rdesc["desc"],
            )
            uhid_dev.phys = dev.phys
            assert uhid_dev.rdesc is not None
            assert len(uhid_dev.rdesc) == dev.rdesc["length"]

            self._devices[idx] = uhid_dev

            uhid_dev.create_kernel_device()

        while not self.ready:
            hidtools.uhid.UHIDDevice.dispatch(10)

    def determine_device_type_by_info(self, info) -> Type[BaseDevice]:
        device_id = (info["vid"], info["pid"])
        if device_id in self._known_devices:
            return self._known_devices[device_id]
        return BaseDevice

    @property
    def ready(self) -> bool:
        for d in self._devices.values():
            if not d.device_nodes:
                return False
        return True

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_value, traceback):
        for d in self._devices.values():
            d.destroy()

    def inject_events(self, wait_max_seconds=2):
        t = None
        timestamp_offset = 0
        assert len(self._devices) > 0
        with open(self.filename) as f:
            idx = 0
            dev = self._devices[idx]
            if idx in self._devices:
                dev = self._devices[idx]
            for line in f:
                if line.startswith("D:"):
                    r = parse("D: {idx:d}", line)
                    assert r is not None
                    dev = self._devices[r["idx"]]
                elif line.startswith("E:"):
                    r = parse("E: {sec:d}.{usec:d} {len:2d}{data}", line)
                    assert r is not None
                    length = r["len"]
                    timestamp = r["sec"] + r["usec"] / 1000000
                    r_ = findall(" {:S}", r["data"])
                    data = [int(x[0], 16) for x in r_]
                    assert len(data) == int(length)
                    now = datetime.today()
                    if t is None:
                        t = now
                        timestamp_offset = timestamp
                    target_time = t + timedelta(seconds=timestamp - timestamp_offset)
                    sleep = 0
                    if target_time > now:
                        sleep = target_time - now
                        sleep = sleep.seconds + sleep.microseconds / 1000000
                    if sleep < 0.01:
                        pass
                    elif sleep < wait_max_seconds:
                        time.sleep(sleep)
                    else:
                        t = now
                        timestamp_offset = timestamp
                        time.sleep(wait_max_seconds)
                    dev.call_input_event(data)
        self.replayed_count += 1

    def replay_one_sequence(self):
        count = self.replayed_count
        re = "" if count == 0 else "re"
        print(f"Hit enter to {re}start replaying the events", end="", flush=True)
        sys.stdin.readline()
        self.inject_events()

        while count == self.replayed_count:
            hidtools.uhid.UHIDDevice.dispatch()


@click.command()
@click.option(
    "--verbose", default=False, is_flag=True, help="Show debugging information"
)
@click.argument("recording", metavar="recording.hid", type=str)
def main(verbose, recording):
    """Replay a HID recording"""
    if verbose:
        base_logger.setLevel(logging.DEBUG)

    try:
        with HIDReplay(recording) as replay:
            while True:
                replay.replay_one_sequence()
    except PermissionError:
        print("Insufficient permissions, please run me as root.", file=sys.stderr)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    if sys.version_info < (3, 6):
        sys.exit("Python 3.6 or later required")

    main()
