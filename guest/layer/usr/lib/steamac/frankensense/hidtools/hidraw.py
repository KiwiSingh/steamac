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

import array
import datetime
import fcntl
import io
import os
import struct
import sys
from hidtools.hid import ReportDescriptor
from hidtools.util import BusType

from typing import Final


def _ioctl(fd, EVIOC, code, return_type, buf=None):
    size = struct.calcsize(return_type)
    if buf is None:
        buf = size * "\x00"
    abs = fcntl.ioctl(fd, EVIOC(code, size), buf)  # type: ignore
    return struct.unpack(return_type, abs)


# extracted from <asm-generic/ioctl.h>
_IOC_WRITE: Final = 1
_IOC_READ: Final = 2

_IOC_NRBITS: Final = 8
_IOC_TYPEBITS: Final = 8
_IOC_SIZEBITS: Final = 14
_IOC_DIRBITS: Final = 2

_IOC_NRSHIFT: Final = 0
_IOC_TYPESHIFT: Final = _IOC_NRSHIFT + _IOC_NRBITS
_IOC_SIZESHIFT: Final = _IOC_TYPESHIFT + _IOC_TYPEBITS
_IOC_DIRSHIFT: Final = _IOC_SIZESHIFT + _IOC_SIZEBITS


# define _IOC(dir,type,nr,size) \
# 	(((dir)  << _IOC_DIRSHIFT) | \
# 	 ((type) << _IOC_TYPESHIFT) | \
# 	 ((nr)   << _IOC_NRSHIFT) | \
# 	 ((size) << _IOC_SIZESHIFT))
def _IOC(dir, type, nr, size):
    return (
        (dir << _IOC_DIRSHIFT)
        | (ord(type) << _IOC_TYPESHIFT)
        | (nr << _IOC_NRSHIFT)
        | (size << _IOC_SIZESHIFT)
    )


# define _IOR(type,nr,size)	_IOC(_IOC_READ,(type),(nr),(_IOC_TYPECHECK(size)))
def _IOR(type, nr, size):
    return _IOC(_IOC_READ, type, nr, size)


# define _IOW(type,nr,size)	_IOC(_IOC_WRITE,(type),(nr),(_IOC_TYPECHECK(size)))
def _IOW(type, nr, size):
    return _IOC(_IOC_WRITE, type, nr, size)


# define HIDIOCGRDESCSIZE	_IOR('H', 0x01, int)
def _IOC_HIDIOCGRDESCSIZE(none, len):
    return _IOR("H", 0x01, len)


def _HIDIOCGRDESCSIZE(fd):
    """get report descriptors size"""
    type = "i"
    return int(*_ioctl(fd, _IOC_HIDIOCGRDESCSIZE, None, type))


# define HIDIOCGRDESC		_IOR('H', 0x02, struct hidraw_report_descriptor)
def _IOC_HIDIOCGRDESC(none, len):
    return _IOR("H", 0x02, len)


def _HIDIOCGRDESC(fd, size):
    """get report descriptors"""
    format = "I4096c"
    tmp = struct.pack("i", size) + bytes(4096)
    _buffer = array.array("B", tmp)
    fcntl.ioctl(fd, _IOC_HIDIOCGRDESC(None, struct.calcsize(format)), _buffer)
    (size,) = struct.unpack("i", _buffer[:4])
    value = _buffer[4 : size + 4]
    return size, value


# define HIDIOCGRAWINFO		_IOR('H', 0x03, struct hidraw_devinfo)
def _IOC_HIDIOCGRAWINFO(none, len):
    return _IOR("H", 0x03, len)


def _HIDIOCGRAWINFO(fd):
    """get hidraw device infos"""
    type = "ihh"
    return _ioctl(fd, _IOC_HIDIOCGRAWINFO, None, type)


# define HIDIOCGRAWNAME(len)     _IOC(_IOC_READ, 'H', 0x04, len)
def _IOC_HIDIOCGRAWNAME(none, len):
    return _IOC(_IOC_READ, "H", 0x04, len)


def _HIDIOCGRAWNAME(fd):
    """get device name"""
    type = 1024 * "c"
    cstring = _ioctl(fd, _IOC_HIDIOCGRAWNAME, None, type)
    string = b"".join(cstring).decode("utf-8")
    return "".join(string).rstrip("\x00")


# define HIDIOCGFEATURE(len) _IOC(_IOC_WRITE|_IOC_READ, 'H', 0x07, len)
def _IOC_HIDIOCGFEATURE(none, len):
    return _IOC(_IOC_WRITE | _IOC_READ, "H", 0x07, len)


def _HIDIOCGFEATURE(fd, report_id, rsize):
    """get feature report"""
    assert report_id <= 255 and report_id > -1

    # rsize has the report length in it
    buf = bytearray([report_id & 0xFF]) + bytearray(rsize - 1)
    fcntl.ioctl(fd, _IOC_HIDIOCGFEATURE(None, len(buf)), buf)
    return list(buf)  # Note: first byte is report ID


# define HIDIOCSFEATURE(len) _IOC(_IOC_WRITE|_IOC_READ, 'H', 0x06, len)
def _IOC_HIDIOCSFEATURE(none, len):
    return _IOC(_IOC_WRITE | _IOC_READ, "H", 0x06, len)


def _HIDIOCSFEATURE(fd, data):
    """set feature report"""

    buf = bytearray(data)
    sz = fcntl.ioctl(fd, _IOC_HIDIOCSFEATURE(None, len(buf)), buf)
    return sz


class HidrawEvent(object):
    """
    A single event from a hidraw device. The first event always has a timestamp of 0.0,
    all other events are offset accordingly.

    .. attribute:: sec

        Timestamp seconds

    .. attribute:: usec

        Timestamp microseconds

    .. attribute:: bytes

        The data bytes read for this event
    """

    def __init__(self, sec, usec, bytes):
        self.sec, self.usec = sec, usec
        self.bytes = bytes


class HidrawDevice(object):
    """
    A device as exposed by the kernel ``hidraw`` module. ``hidraw`` allows
    direct access to the HID device, both for reading and writing. ::

        with open('/dev/hidraw0', 'r+b') as fd:
            dev = HidrawDevice(fd)
            while True:
                dev.read_events()  # this blocks
                print(f'We received {len(dev.events)} events so far')

    :param File device: a file-like object pointing to ``/dev/hidrawX``

    .. attribute:: name

        The device name

    .. attribute:: bustype

        The :class:`hidtools.util.BusType` for this device.

    .. attribute:: vendor_id

        16-bit numerical vendor ID

    .. attribute:: product_id

        16-bit numerical product ID

    .. attribute:: report_descriptor

        The :class:`hidtools.hid.ReportDescriptor` for this device

    .. attribute:: events

        All events accumulated so far, a list of :class:`HidrawEvent`

    .. attribute:: time_offset

        The offset to be be applied for incoming events. Where the offset is
        not set by the caller, the offset is the timestamp of the first event.
        This offset can be used to synchronize events from multiple devices,
        simply apply the offset of the first device to receive an event to
        all other devices to get synchronized time stamps for all devices.
    """

    def __init__(self, device):
        fd = device.fileno()
        self.device = device
        self.name = _HIDIOCGRAWNAME(fd)
        bustype, self.vendor_id, self.product_id = _HIDIOCGRAWINFO(fd)
        self.bustype = BusType(bustype)
        self.vendor_id &= 0xFFFF
        self.product_id &= 0xFFFF
        size = _HIDIOCGRDESCSIZE(fd)
        rsize, desc = _HIDIOCGRDESC(fd, size)
        assert rsize == size
        assert len(desc) == rsize
        self.report_descriptor = ReportDescriptor.from_bytes([x for x in desc])

        self.events = []

        self._dump_offset = -1
        self.time_offset = None

    def __repr__(self):
        return f"{self.name} bus: {self.bustype:02x} vendor: {self.vendor_id:04x} product: {self.product_id:04x}"

    def read_events(self):
        """
        Read events from the device and append them to :attr:`events`.

        This function simply calls :func:`os.read`, it is the caller's task to
        either make sure the device is set nonblocking or to handle any
        :class:`KeyboardInterrupt` if this call does end up blocking.

        :returns: a tuple of ``(index, count)`` of the :attr:`events` added.
        """

        index = max(0, len(self.events) - 1)

        loop = True
        while loop:
            data = os.read(self.device.fileno(), 4096)
            if not data:
                break
            if len(data) < 4096:
                loop = False

            now = datetime.datetime.now()
            if self.time_offset is None:
                self.time_offset = now
            tdelta = now - self.time_offset
            bytes = struct.unpack("B" * len(data), data)

            self.events.append(HidrawEvent(tdelta.seconds, tdelta.microseconds, bytes))

        count = len(self.events) - index

        return index, count

    def _dump_event(self, event, file):
        report_id = event.bytes[0]

        rdesc = self.report_descriptor.get(report_id, len(event.bytes))
        if rdesc is not None:
            indent_2nd_line = 2
            output = rdesc.format_report(event.bytes)
            try:
                first_row = output.split("\n")[0]
            except IndexError:
                pass
            else:
                # we have a multi-line output, find where the fields are split
                try:
                    slash = first_row.index("/")
                except ValueError:
                    pass
                else:
                    # the `+1` below is to make a better visual effect
                    indent_2nd_line = slash + 1
            indent = f"\n#{' ' * indent_2nd_line}"
            output = indent.join(output.split("\n"))
            print(f"# {output}", file=file)

        data = map(lambda x: f"{x:02x}", event.bytes)
        print(
            f"E: {event.sec:06d}.{event.usec:06d} {len(event.bytes)} {' '.join(data)}",
            file=file,
            flush=True,
        )

    def dump(self, file=sys.stdout, from_the_beginning=False):
        """
        Format this device in a file format in the form of ::

            R: 123 43 5 52 2 ... # the report descriptor size, followed by the integers
            N: the device name
            I: 3 124 abcd # bustype, vendor, product
            # comments are allowed
            E: 00001.000002 AB 12 34 56 # sec, usec, length, data
            ...

        This method is designed to be called repeatedly and only print the
        new events on each call. To repeat the dump from the beginning, set
        ``from_the_beginning`` to True.

        :param File file: the output file to write to
        :param bool from_the_beginning: if True, print everything again
             instead of continuing where we left off
        """

        if from_the_beginning:
            self._dump_offset = -1

        if self._dump_offset == -1:
            print(f"# {self.name}", file=file)
            output = io.StringIO()
            self.report_descriptor.dump(output)
            for line in output.getvalue().split("\n"):
                print(f"# {line}", file=file)
            output.close()

            rd = " ".join([f"{b:02x}" for b in self.report_descriptor.bytes])
            sz = len(self.report_descriptor.bytes)
            print(f"R: {sz} {rd}", file=file)
            print(f"N: {self.name}", file=file)
            print(
                f"I: {self.bustype:x} {self.vendor_id:04x} {self.product_id:04x}",
                file=file,
                flush=True,
            )
            self._dump_offset = 0

        for e in self.events[self._dump_offset :]:
            self._dump_event(e, file)
        self._dump_offset = len(self.events)

    def get_feature_report(self, report_ID):
        """
        Fetch the Feature Report with the given report ID

        Note that the returned array contains the report ID as the first
        byte, but only if the report is a numbered report.

        :return: an array of bytes with the Feature Report data.
        """
        report = self.report_descriptor.feature_reports[report_ID]
        fd = self.device.fileno()
        return _HIDIOCGFEATURE(fd, report_ID, report.size)

    def set_feature_report(self, report_ID, data):
        """
        Set the Feature Report with the given report ID

        Note that the data array must always contain the report ID as the
        first byte.
        """
        # throw an exception for invalid ids
        self.report_descriptor.feature_reports[report_ID]
        assert data[0] == report_ID
        fd = self.device.fileno()
        sz = _HIDIOCSFEATURE(fd, data)
        if sz != len(data):
            raise OSError("Failed to write data: {data} - bytes written: {sz}")
