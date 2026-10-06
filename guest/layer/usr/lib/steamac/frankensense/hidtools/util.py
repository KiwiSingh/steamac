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

import enum


class BusType(enum.IntEnum):
    """
    The numerical bus type (``0x3`` for USB, ``0x5`` for Bluetooth, see
        ``linux/input.h``)
    """

    UNKNOWN = 0x00
    PCI = 0x01
    ISAPNP = 0x02
    USB = 0x03
    HIL = 0x04
    BLUETOOTH = 0x05
    VIRTUAL = 0x06
    ISA = 0x10
    I8042 = 0x11
    XTKBD = 0x12
    RS232 = 0x13
    GAMEPORT = 0x14
    PARPORT = 0x15
    AMIGA = 0x16
    ADB = 0x17
    I2C = 0x18
    HOST = 0x19
    GSC = 0x1A
    ATARI = 0x1B
    SPI = 0x1C
    RMI = 0x1D
    CEC = 0x1E
    INTEL_ISHTP = 0x1F
    AMD_SFH = 0x20


def twos_comp(val, bits):
    """compute the 2's complement of val.

    :param int val:
        the value to compute the two's complement for

    :param int bits:
        size of val in bits
    """
    if bits and (val & (1 << (bits - 1))) != 0:
        val = val - (1 << bits)
    return val


def to_twos_comp(val, bits):
    return val & ((1 << bits) - 1)
