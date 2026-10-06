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
from pathlib import Path
import re
import sys
import hidtools.hid
import hidtools.hidraw
import logging
import yaml
from hidtools.hid import ReportDescriptor

logging.basicConfig(format="%(levelname)s: %(name)s: %(message)s", level=logging.INFO)
base_logger = logging.getLogger("hid")
logger = logging.getLogger("hid.decode")


class Oops(Exception):
    pass


def open_sysfs_rdesc(path):
    logger.debug(f"Reading sysfs file {path}")
    with open(path, "rb") as fd:
        data = fd.read()
        return [hidtools.hid.ReportDescriptor.from_bytes(data)]


def open_devnode_rdesc(path):
    if not path.startswith("/dev/input/event"):
        raise Oops(f"Unexpected event node: {path}")

    node = path[len("/dev/input/") :]
    # should use pyudev here, but let's keep that for later
    sysfs = Path(f"/sys/class/input/{node}/device/device/report_descriptor")

    if not sysfs.exists():
        raise Oops(
            f"Unable to find report descriptor for {path}, is this a HID device?"
        )

    return open_sysfs_rdesc(sysfs)


def open_hidraw(path):
    with open(path, "rb+") as fd:
        device = hidtools.hidraw.HidrawDevice(fd)
        return [device.report_descriptor]


def open_binary(path):
    # This will misidentify a few files (e.g. UTF-16) as binary but for the
    # inputs we need to accept it doesn't matter
    with open(path, "rb") as fd:
        data = fd.read(4096)
        if b"\0" in data:
            logger.debug(f"{path} is a binary file")
            return [hidtools.hid.ReportDescriptor.from_bytes(data)]
    return None


def interpret_file_hidrecorder(fd):
    data = fd.read()
    # The proper (machine-readable) hid-recorder output
    rdescs = [
        ReportDescriptor.from_string(line[3:])
        for line in data.splitlines()
        if line.startswith("R: ")
    ]
    if rdescs:
        return rdescs

    # The human-readable version (the comment in the hid-recorder output)
    if any(filter(lambda x: x.strip().startswith("Usage Page ("), data.splitlines())):
        rdescs = [hidtools.hid.ReportDescriptor.from_human_descr(data)]
        if rdescs:
            return rdescs

    return None


def interpret_file_libinput_record(fd):
    try:
        libinput_data = yaml.load(fd, Loader=yaml.Loader)
    except UnicodeDecodeError:
        # binary file?
        return None
    if "libinput" not in libinput_data:
        # not a libinput record
        return None

    rdescs_data = [dev["hid"] for dev in libinput_data["devices"]]

    rdescs = [hidtools.hid.ReportDescriptor.from_bytes(r) for r in rdescs_data]

    return rdescs


def open_report_descriptor(path):
    abspath = Path(path).resolve()
    logger.debug(f"Processing {abspath}")

    if abspath.is_dir() or not abspath.exists():
        raise Oops(f"Invalid path: {path}")

    if re.match("/sys/.*/report_descriptor", str(abspath)):
        return open_sysfs_rdesc(path)
    if re.match("/dev/input/event[0-9]+", str(abspath)):
        return open_devnode_rdesc(path)
    if re.match("/dev/hidraw[0-9]+", str(abspath)):
        return open_hidraw(path)
    rdesc = open_binary(path)
    if rdesc is not None:
        return rdesc

    with open(path, "r") as fd:
        logger.debug(f"Opening {path} as text file")
        rdesc = interpret_file_hidrecorder(fd)
        if rdesc is not None:
            return rdesc

    with open(path, "r") as fd:
        rdesc = interpret_file_libinput_record(fd)
        if rdesc is not None:
            return rdesc

    raise Oops(f"Unable to detect file type for {path}")


class FakeHidraw(hidtools.hidraw.HidrawDevice):
    def __init__(self, name, rdesc):
        self.name = name
        self.bustype, self.vendor_id, self.product_id = 3, 1, 1
        self.report_descriptor = rdesc
        self.events = []


@click.command()
@click.argument(
    "report_descriptor",
    metavar="<Path to report descriptor>",
    nargs=-1,
    type=click.Path(exists=True, dir_okay=False, readable=True),
)
@click.option(
    "--output",
    metavar="output-file",
    default=sys.stdout,
    nargs=1,
    type=click.File("w"),
    help="The file to record to (default: stdout)",
)
@click.option(
    "--verbose", default=False, is_flag=True, help="Show debugging information"
)
def main(report_descriptor, output, verbose):
    """Decode a HID report descriptor to human-readable format.

    \b
    Supported formats for the report descriptor are:
    - a syspath to the report descriptor, i.e. /sys/path/.../report_descriptor/
    - an evdev device node, e.g. /dev/input/event2
    - a hidraw node, e.g. /dev/hidraw2
    - a recording produced by hid-recorder
    - a recording produced by libinput record
    """
    try:
        if verbose:
            base_logger.setLevel(logging.DEBUG)

        for d, path in enumerate(report_descriptor):
            rdescs = open_report_descriptor(path)
            for r, rdesc in enumerate(rdescs):
                fake = FakeHidraw(f"device {d}:{r}", rdesc)
                fake.dump(output, from_the_beginning=True)
                if rdesc.win8:
                    output.write("# **** win 8 certified ****\n")
    except BrokenPipeError:
        pass
    except PermissionError as e:
        print(f"{e}", file=sys.stderr)
    except Oops as e:
        print(f"{e}", file=sys.stderr)


if __name__ == "__main__":
    main()
