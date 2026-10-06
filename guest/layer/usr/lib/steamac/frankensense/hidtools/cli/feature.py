#!/bin/env python3
# -*- coding: utf-8 -*-
#
# Copyright (c) 2020 Red Hat, Inc.
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
from pathlib import Path

from hidtools.hidraw import HidrawDevice


def make_id(ridx, idx):
    return (ridx & 0xFF) << 16 | idx & 0xFFFF


def feature_report_fields(device, report_id=None):
    """Return a flat list of Feature Report fields for this device"""
    rdesc = device.report_descriptor
    fields = []
    for report in rdesc.feature_reports.values():
        if report_id is not None and report.report_ID != report_id:
            continue

        for idx, field in enumerate(report.fields):
            field._unique_id = make_id(report.report_ID, idx)
            fields.append(field)
    return fields


@click.group()
def hid_feature():
    pass


@hid_feature.command()
def list_devices():
    """List available HID devices"""

    print("Available devices:")
    for hidraw in sorted(Path("/dev/").glob("hidraw*")):
        with open(hidraw) as fd:
            d = HidrawDevice(fd)
            print(f"{hidraw}: {d.name}")


@hid_feature.command()
@click.argument(
    "device", metavar="<Path to the hidraw device node>", type=click.File("r")
)
@click.option(
    "--fetch-values",
    is_flag=True,
    default=False,
    help="Fetch the current value from the device",
)
@click.option(
    "--report-id",
    type=click.IntRange(-1, 255),
    default=None,
    required=False,
    help="Only list the given Feature Reports",
)
def list(device, fetch_values, report_id):
    """
    List the available Feature Reports of a device and their respective items
    with details about each item.

    If --fetch-values is given, the current value of each item is shown as
    well. Note that the value depends on the device, no consistent formatting
    should be expected.
    """

    d = HidrawDevice(device)

    reports = {}  # report_ID: [data-from-device]

    # Formatting nicety: we don't print the header until we have at least
    # one line to print, otherwise the error messages are messy.
    header_printed = False

    def print_header():
        header = f"Feature | Report | {'Usage Page':25s} | {'Usage':42s} | {'Range':9s} | Count | Bits "
        if fetch_values:
            header += "| Value(s)"
        divisor = "".join(["-" if x != "|" else "|" for x in header])
        print(header)
        print(divisor)

    all_fields = feature_report_fields(d, report_id)

    for f in all_fields:
        if fetch_values:
            if f.report_ID not in reports:
                try:
                    reports[f.report_ID] = d.get_feature_report(f.report_ID)
                except OSError as e:
                    print(
                        f"Failed to get Feature Report ID {f.report_ID} from device: {e}"
                    )
                    print("Cannot run with --fetch-values")
                    sys.exit(1)

            values = f.get_values(reports[f.report_ID])
            if len(values) == 1:
                vstring = f" | {values[0]}"
            else:
                vstring = f" | {', '.join([str(x) for x in values])}"
        else:
            vstring = ""

        if not header_printed:
            header_printed = True
            print_header()

        print(
            f"{f._unique_id:7x} | {f.report_ID:6d} | {f.usage_page_name:25s} | {str(f.usage_name):42s} | [{f.logical_min:2d}, {f.logical_max:3d}] | {f.count:5d} | {f.size:3d} {vstring}"
        )


@hid_feature.command()
@click.argument(
    "device", metavar="<Path to the hidraw device node>", type=click.File("r")
)
@click.option(
    "--feature",
    "-f",
    "feature_ids",
    type=(str, int),
    required=True,
    multiple=True,
    help="Set the given feature(s)",
)
def set(device, feature_ids):
    """
    Set the given features of a Feature Report. The feature must be
    specified as a tuple of index and value, where the index is the one
    listed by hid-feature list-report

    Only features of the same Report ID can be changed in one go.
    """

    d = HidrawDevice(device)
    all_fields = feature_report_fields(d)
    try:
        # arg has to be string because we expect non-prefixed hex
        fids = [int(x[0], 16) for x in feature_ids]
    except ValueError:
        print("Invalid Feature ID format(s)", file=sys.stderr)
        sys.exit(1)

    allowed_ids = [f._unique_id for f in all_fields]
    for fid in fids:
        if fid not in allowed_ids:
            print(f"Invalid feature index: {fid}", file=sys.stderr)
            sys.exit(1)

    fields = []
    report_id = None
    for f in all_fields:
        if f._unique_id not in fids:
            continue

        if report_id is None:
            report_id = f.report_ID
        elif report_id != f.report_ID:
            print("All features must belong to the same Report ID", file=sys.stderr)
            sys.exit(1)

        fields.append(f)

    assert len(feature_ids) == len(fields)

    # Fetch the FeatureReport first so we have the correct values for the
    # fields we are not about to change
    try:
        data = d.get_feature_report(report_id)
    except OSError as e:
        print(f"Failed to get feature report ID {report_id}: {e}")
        sys.exit(1)

    # Now update the report with the data for each field
    # FIXME: this breaks where we have multiple values for a field, we can
    # worry about that in the future I guess
    for f, (_, value) in zip(fields, feature_ids):
        f.fill_values(data, [value])

    try:
        d.set_feature_report(report_id, data)
    except OSError as e:
        print(f"Failed to set feature report ID {report_id}: {e}")
        sys.exit(1)


def main():
    hid_feature()


if __name__ == "__main__":
    main()
