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

from pathlib import Path
from re import Match
import parse
import functools
import sys

from collections import abc
from typing import (
    Annotated,
    Any,
    Hashable,
    NamedTuple,
    Optional,
    Type,
    Union,
)

if sys.version_info >= (3, 10):
    from typing import TypeAlias
else:
    from typing_extensions import TypeAlias

DATA_DIRNAME = "data"
SCRIPT_DIR = Path(__file__).resolve().parent
DATA_DIR = SCRIPT_DIR / DATA_DIRNAME


class ValueRange(NamedTuple):
    min: int
    max: int


U8 = Annotated[int, ValueRange(0, 0xFF)]
U16 = Annotated[int, ValueRange(0, 0xFFFF)]
U32 = Annotated[int, ValueRange(0, 0xFFFFFFFF)]

dict_items_usage: TypeAlias = abc.ItemsView[U16, "HidUsage"]
dict_items_usagePage: TypeAlias = abc.ItemsView[U16, "HidUsagePage"]


@functools.total_ordering
class HidUsage(Hashable):
    """
    A HID Usage entry as defined in the HID Usage Tablets. ::

        > usage_page = hidtools.hut.HUT[0x01]  # Generic Desktop
        > usage = usage_page[0x02]
        > print(usage.usage)
        2
        > print(usage)
        Mouse
        > print(usage.name)
        Mouse

    :param HidUsagePage usage_page: the Usage Page this Usage belongs to
    :param int usage: the 16-bit Usage assigned by the HID Usage Tables
    :param str name: the usage_name

    .. attribute:: usage

        the 16-bit Usage assigned by the HId Usage Tables

    .. attribute:: name

        the semantic name for this Usage

    .. attribute:: usage_page

        the :class:`HidUsagePage` this Usage belongs to

    """

    def __init__(self, usage_page: "HidUsagePage", usage: U16, name: str) -> None:
        self.usage_page = usage_page
        self.usage = usage
        self.name = name

    # Route everything down to the name, this way we basically behave like a
    # string
    def __getattr__(self, attr: str) -> Any:
        return getattr(self.name, attr)

    def __repr__(self) -> str:
        return self.name

    def __hash__(self) -> int:
        return hash(self.name)

    def __str__(self) -> str:
        return self.name

    def __eq__(self, other: object) -> bool:
        if isinstance(other, HidUsage):
            return self.name == other.name
        elif not isinstance(other, str):
            return NotImplemented
        return self.name == other

    def __lt__(self, other: object) -> bool:
        if isinstance(other, HidUsage):
            return self.name < other.name
        elif not isinstance(other, str):
            return NotImplemented
        return self.name < other


class HidUsagePage(dict[U16, HidUsage]):
    """
    A dictionary of HID Usages in the form ``{usage: usage_name}``,
    representing all Usages in this Usage Page.

    A HID Usage is named semantical identifier that describe how a given
    field in a HID report is to be used. A Usage Page is a logical grouping
    of those identifiers, e.g. "Generic Desktop", "Telephony Devices", or
    "Digitizers".  ::

        > print(usage_page.page_name)
        Generic Desktop
        > print(usage_page.page_id)
        1
        > print(usage_page[0x02])
        Mouse
        > print(usage_page['Mouse'])
        Mouse
        > usage = usage_page.from_name["Mouse"]
        > print(usage.usage)
        2
        > print(usage.name)
        Mouse
        > print(usage)
        Mouse

    .. attribute:: page_id

        The Page ID for this Usage Page, e.g. ``01`` (Generic Desktop)

    .. attribute:: page_name

        The assigned name for this usage Page, e.g. "Generic Desktop"
    """

    def __getitem__(self, key: Union[str, U16, U32]) -> HidUsage:
        if isinstance(key, str):
            return self.from_name[key]

        # extract the usage if we have a 32-bit usage and the page ID
        # matches
        if key > 0xFFFF and key & 0xFFFF0000 == self.page_id << 16:
            key &= 0xFFFF
        return super().__getitem__(key)

    def __str__(self) -> str:
        return self.page_name

    def __repr__(self) -> str:
        return self.page_name

    @property
    def page_id(self) -> U16:
        """
        The numerical page ID for this usage page
        """
        return self._page_id

    @page_id.setter
    def page_id(self, page_id: U16) -> None:
        self._page_id = page_id

    @property
    def page_name(self) -> str:
        """
        The assigned name for this Usage Page
        """
        return self._name

    @page_name.setter
    def page_name(self, name: str) -> None:
        self._name = name

    @property
    def from_name(self) -> dict[str, HidUsage]:
        """
        A dictionary using ``{ name: usage }`` mapping, to look up the
        :class:`HidUsage` based on a name.
        """
        try:
            return self._inverted
        except AttributeError:
            self._inverted: dict[str, HidUsage] = {}
            for _, v in self.items():
                self._inverted[v.name] = v
            return self._inverted

    @property
    def from_usage(self) -> dict[U16, HidUsage]:
        """
        A dictionary using ``{ usage: name }`` mapping, to look up the name
        based on a page ID . This is the same as using the object itself.
        """
        return self


class HidUsageTable(dict[U16, HidUsagePage]):
    """
    This effectively a dictionary of all HID Usages known to man. Or to this
    module at least. This object is a singleton, it is available as
    ``hidtools.hut.HUT``.

    Elements of this dictionary are :class:`HidUsagePage` objects.

    This object is a dictionary, use like this: ::

        > hut = hidtools.hut.HUT
        > print(hut[0x01].page_name)
        Generic Desktop
        > print(hut['Generic Desktop'].page_name)
        Generic Desktop
        > print(hut.usage_pages[0x01].page_name)
        Generic Desktop
        > print(hut.usage_page_names['Generic Desktop'].page_name)
        Generic Desktop
        > print(hut[0x01].page_id)
        1
        > print(hut.usage_page_from_name('Generic Desktop').page_id)
        1
        > print(hut.usage_page_from_page_id(0x01).page_name)
        Generic Desktop
    """

    def __getitem__(self, key: Union[str, U16]) -> HidUsagePage:
        if isinstance(key, str):
            return self.usage_page_names[key]

        # shift the usage page bits down if we have a 32-bit usage
        if key & 0xFFFF0000 == key:
            key >>= 16
        return super().__getitem__(key)

    @property
    def usage_pages(self) -> dict[U16, HidUsagePage]:
        """
        A dictionary mapping ``{page_id : object}``. These two are
        equivalent calls: ::

            HUT[0x1]
            HUT.usage_pages[0x1]

        """
        return self

    @property
    def usage_page_names(self) -> dict[str, HidUsagePage]:
        """
        A dictionary mapping ``{page_name : object}``. These two are
        equivalent calls: ::

            HUT['Generic Desktop']
            HUT.usage_page_names['Generic Desktop']

        """
        return {v.page_name: v for _, v in self.items()}

    def usage_page_from_name(self, page_name: str) -> Optional[HidUsagePage]:
        """
        Look up the usage page based on the page name (e.g. "Generic
        Desktop"). This is identical to ::

            self.usage_page_names[page_name]

        except that this function returns ``None`` if the page name is
        unknown.

        :return: the :meth:`HidUsagePage` or None
        """
        try:
            return self[page_name]
        except KeyError:
            return None

    def usage_page_from_page_id(self, page_id: U16) -> Optional[HidUsagePage]:
        """
        Look up the usage page based on the page ID. This is identical to ::

                self.usage_pages[page_id]

        except that this function returns ``None`` if the page ID is unknown.

        :return: the :meth:`HidUsagePage` or None
        """
        try:
            return self[page_id]
        except KeyError:
            return None

    @classmethod
    def _parse_usages(cls: Type["HidUsageTable"], f: abc.Iterable[str]) -> HidUsagePage:
        """
        Parse a single HUT file. The file format is a set of lines in three
        formats: ::

            (01)<tab>Usage Page name
            A0<tab>Name
            F0-FF<tab>Reserved for somerange

        All numbers in hex.

        Only one Usage Page per file

        Usages are parsed into a dictionary[number] = name.

        The return value is a single HidUsagePage where page[idx] = idx-name.
        """
        usage_page = None
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue

            r: Match[str]

            # Usage Page, e.g. '(01)	Generic Desktop'
            if line.startswith("("):
                assert usage_page is None

                r = parse.parse("({idx:x})\t{page_name}", line)  # type: ignore
                assert r is not None
                usage_page = HidUsagePage()
                usage_page.page_id = r["idx"]  # type: ignore
                usage_page.page_name = r["page_name"]
                continue

            assert usage_page is not None

            # Reserved ranges, e.g  '0B-1F	Reserved'
            r = parse.parse("{:x}-{:x}\t{name}", line)  # type: ignore
            if r:
                if "reserved" not in r["name"].lower():
                    print(line)
                continue

            # Single usage, e.g. 36	Slider
            # we can not use {usage:x} or the value '0B' will be converted to 0
            # See https://github.com/r1chardj0n3s/parse/issues/65
            # fixed in parse 1.8.4 (May 2018)
            r = parse.parse("{usage}\t{name}", line)  # type: ignore
            assert r is not None
            if "reserved" in r["name"].lower():
                continue

            u = int(r["usage"], 16)
            usage = HidUsage(usage_page, u, r["name"])

            usage_page[u] = usage

        if usage_page is None:
            raise Exception

        return usage_page

    @classmethod
    def _from_hut_data(cls: Type["HidUsageTable"]) -> "HidUsageTable":
        """
        Return the HID Usage Tables, the keys are the numeric Usage Page and
        the values are the respective :class:`hidtools.HidUsagePage` object.

        ::

            > usages = hidtools.hut.HUT()
            > print(usages[0x01].page_name)
            Generic Desktop
            > print(usages.usage_pages[0x01].page_name)
            Generic Desktop
            > print(usages[0x01].page_id)
            1

        :return: a :class:`hidtools.HidUsageTable` object
        """
        hut = HidUsageTable()
        for filepath in DATA_DIR.glob("*.hut"):
            with filepath.open("r", encoding="utf-8") as f:
                try:
                    usage_page = cls._parse_usages(f)
                    hut[usage_page.page_id] = usage_page
                except Exception:
                    print(filepath.name)
                    raise

        return hut


HUT = HidUsageTable._from_hut_data()
"""
The HID Usage Tables as a :class:`hidtools.HidUsageTable` object,
a dictionary where the keys are the numeric Usage Page and the values are
the respective :class:`hidtools.HidUsagePage` object. ::

    > usages = hidtools.hut.HUT()
    > print(usages[0x01].page_name)
    Generic Desktop
    > print(usages.usage_pages[0x01].page_name)
    Generic Desktop
    > print(usages[0x01].page_id)
    1
"""
