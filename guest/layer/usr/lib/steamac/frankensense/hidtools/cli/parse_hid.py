#!/bin/env python3
# -*- coding: utf-8 -*-
#
# Copyright (c) 2012-2017 Benjamin Tissoires <benjamin.tissoires@gmail.com>
# Copyright (c) 2012-2017 Red Hat, Inc.
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
import sys
import hidtools.hid
from parse import parse as _parse


def get_report(time, report, rdesc):
    """
    Translate the given report to a human readable format.
    """

    output = f"{time:>10s} "
    indent_2nd_line = len(output)

    output += rdesc.format_report(report)

    # align the lines with the first '/'
    try:
        first_row = output.split("\n")[0]
    except IndexError:
        pass
    else:
        # we have a multi-line output, find where the fields are split
        try:
            slash = first_row.index("/")
        except ValueError:
            indent_2nd_line = 2
        else:
            # the `-1` below is to make a better visual effect
            indent_2nd_line = slash - 1

    indent = f"\n{' ' * indent_2nd_line}"

    return indent.join(output.split("\n"))


def parse_event(line, rdesc_object):
    e, time, size, report = line.split(" ", 3)
    report = [int(item, 16) for item in report.split(" ")]
    assert int(size) == len(report)
    rdesc = rdesc_object.get(report[0], len(report))
    if rdesc is None:
        return None

    return get_report(time, report, rdesc)


def dump_report(line, rdesc_object, f_out):
    """
    Translate the given report to a human readable format.
    """
    event = parse_event(line, rdesc_object)
    if event:
        f_out.write(f"{event}\n")


def parse_hid(f_in, f_out, print_events=True):
    rdesc_dict = {}
    device_index = 0
    for line in f_in:
        if line.startswith("#"):
            continue
        elif line.startswith("R:"):
            rdesc_object = hidtools.hid.ReportDescriptor.from_string(line.lstrip("R: "))
            rdesc_object.dump(f_out)

            rdesc_dict[device_index] = rdesc_object

            win8 = rdesc_object.win8
            if win8:
                f_out.write("**** win 8 certified ****\n")
        elif line.startswith("D:"):
            r = _parse("D:{d:d}", line)
            assert r is not None
            device_index = r["d"]
        elif line.startswith("E:"):
            if print_events:
                dump_report(line, rdesc_dict[device_index], f_out)
        elif line == "":
            # End of file
            break
        elif line.startswith("N:") or line.startswith("P:") or line.startswith("I:"):
            continue
        else:
            f_out.write(line)


@click.command()
@click.option(
    "--report-descriptor-only",
    default=False,
    is_flag=True,
    help="Only print the Report Descriptor",
)
@click.argument(
    "recording",
    metavar="<Path to device recording (stdin if missing)>",
    default=sys.stdin,
    type=click.File("r"),
)
def main(recording, report_descriptor_only):
    """Parse a HID recording and display it in human-readable format"""
    with recording as f:
        try:
            parse_hid(f, sys.stdout, not report_descriptor_only)
        except KeyboardInterrupt:
            pass
        except BrokenPipeError:
            pass


if __name__ == "__main__":
    main()
