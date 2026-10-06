# Copyright © 2017 Red Hat, Inc.
#
# Permission is hereby granted, free of charge, to any person obtaining a
# copy of this software and associated documentation files (the "Software"),
# to deal in the Software without restriction, including without limitation
# the rights to use, copy, modify, merge, publish, distribute, sublicense,
# and/or sell copies of the Software, and to permit persons to whom the
# Software is furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice (including the next
# paragraph) shall be included in all copies or substantial portions of the
# Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL
# THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
# FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
# DEALINGS IN THE SOFTWARE.

from __future__ import annotations

import time
import os
from typing import BinaryIO, Iterator
from dataclasses import dataclass

import libevdev
from ._clib import Libevdev, UinputDevice
from ._clib import (
    READ_FLAG_SYNC,
    READ_FLAG_NORMAL,
    READ_FLAG_FORCE_SYNC,
    READ_FLAG_BLOCKING,
)
from .event import InputEvent
from .const import InputProperty, EventCode, EventType


class InvalidFileError(Exception):
    """
    A file provided is not a valid file descriptor for libevdev or this
    device must not have a file descriptor
    """

    ...


class InvalidArgumentException(Exception):
    """
    A function was called with an invalid argument. This indicates a bug in
    the calling program.

    .. attribute:: message

        A human-readable error message
    """

    def __init__(self, msg: str | None = None):
        self.message = msg

    def __repr__(self):
        return self.message


class DeviceGrabError(Exception):
    """
    A device grab failed to be issued. A caller must not assume that it has
    exclusive access to the events on the device.
    """


class EventsDroppedException(Exception):
    """
    Notification that the device has dropped events, raised in response to a
    EV_SYN SYN_DROPPED event.

    This exception is raised AFTER the EV_SYN, SYN_DROPPED event has been
    passed on. If SYN_DROPPED events are processed manually, then this
    exception can be ignored.

    Once received (or in response to a SYN_DROPPED event) a caller should
    call device.sync() and process the events accordingly (if any).

    Example::

            fd = open("/dev/input/event0", "rb")
            ctx = libevdev.Device(fd)

            while True:
                try:
                    for e in ctx.events():
                        print(e):
                except EventsDroppedException:
                    print('State lost, re-synching:')
                    for e in ctx.sync():
                        print(e)
    """

    ...


@dataclass
class InputAbsInfo:
    """
    A class representing the struct input_absinfo for a given EV_ABS code.

    Any of the attributes may be set to None, those that are None are simply
    ignored by libevdev.

    :property minimum: the minimum value for this axis
    :property maximum: the maximum value for this axis
    :property fuzz: the fuzz value for this axis
    :property flat: the flat value for this axis
    :property resolution: the resolution for this axis
    :property value: the current value of this axis
    """

    minimum: int | None = None
    maximum: int | None = None
    fuzz: int | None = None
    flat: int | None = None
    resolution: int | None = None
    value: int | None = None

    def __repr__(self) -> str:
        return f"min:{self.minimum} max:{self.maximum} fuzz:{self.fuzz} flat:{self.flat} resolution:{self.resolution} value:{self.value}"

    def __eq__(self, other: object) -> bool:
        if not isinstance(other, InputAbsInfo):
            return NotImplemented
        return (
            self.minimum == other.minimum
            and self.maximum == other.maximum
            and self.value == other.value
            and self.resolution == other.resolution
            and self.fuzz == other.fuzz
            and self.flat == other.flat
        )


class Device:
    """
    This class represents an evdev device backed by libevdev. The device may
    represent a real device in the system or a constructed device where the
    caller supplies all properties of the device.

    If a file is given, the device initializes from that file, otherwise the
    device is uninitialized and needs to be set up by the caller::

            fd = open("/dev/input/event0", "rb")
            l = libevdev.Device(fd)
            # l now represents the device on event0

            l2 = libevdev.Device()
            l2.name = "test device"
            l2.enable(libevdev.EV_REL.REL_X)
            # l2 is an unbound device with the REL_X bit set

    Note that if a device is constructed manually, the fd of the device
    is always None.

    .. note:: The device is always set to CLOCK_MONOTONIC.

    :param fd: fd pointing to a ``/dev/input/eventX`` event node
    :type fd: A file-like object

    """

    class _EventValueSet:
        def __init__(self, parent_device: "Device") -> None:
            self._device = parent_device

        def __getitem__(self, code: EventCode) -> int | None:
            # calling device.value[slot axis] is a bug on MT devices
            if (
                code.type == libevdev.EV_ABS
                and code >= libevdev.ABS_MT_SLOT
                and self._device.num_slots is not None
            ):
                raise InvalidArgumentException("Cannot fetch value for MT axes")
            return self._device._libevdev.event_value(code.type.value, code.value)

    class _InputAbsInfoSet:
        def __init__(self, parent_device: "Device") -> None:
            self._device = parent_device

        def __getitem__(self, code: EventCode) -> InputAbsInfo | None:
            assert code.type == libevdev.EV_ABS

            r = self._device._libevdev.absinfo(code.value)
            if r is None:
                return r

            return InputAbsInfo(
                r["minimum"],
                r["maximum"],
                r["fuzz"],
                r["flat"],
                r["resolution"],
                r["value"],
            )

        def __setitem__(self, code: EventCode, absinfo: InputAbsInfo) -> None:
            assert code.type == libevdev.EV_ABS

            if not self._device.has(code):
                raise InvalidArgumentException("Device does not have event code")

            data = {}
            if absinfo.minimum is not None:
                data["minimum"] = absinfo.minimum
            if absinfo.maximum is not None:
                data["maximum"] = absinfo.maximum
            if absinfo.fuzz is not None:
                data["fuzz"] = absinfo.fuzz
            if absinfo.flat is not None:
                data["flat"] = absinfo.flat
            if absinfo.resolution is not None:
                data["resolution"] = absinfo.resolution
            if absinfo.value is not None:
                data["value"] = absinfo.value

            self._device._libevdev.absinfo(code.value, data)

    class _SlotValue:
        def __init__(self, device: "Device", slot: int) -> None:
            self._device = device
            self._slot = slot

        def __getitem__(self, code: EventCode) -> int | None:
            if code.type != libevdev.EV_ABS or code <= libevdev.ABS_MT_SLOT:
                raise InvalidArgumentException(
                    "Event code must be one of EV_ABS.ABS_MT_*"
                )

            if not self._device.has(code):
                return None

            return self._device._libevdev.slot_value(self._slot, code.value)

        def __setitem__(self, code: EventCode, value: int) -> None:
            if code.type != libevdev.EV_ABS or code <= libevdev.ABS_MT_SLOT:
                raise InvalidArgumentException(
                    "Event code must be one of EV_ABS.ABS_MT_*"
                )

            if not self._device.has(code):
                raise InvalidArgumentException("Event code does not exist")

            self._device._libevdev.slot_value(self._slot, code.value, new_value=value)

    def __init__(self, fd: BinaryIO | None = None) -> None:
        self._libevdev = Libevdev(fd)
        self._uinput: UinputDevice | None = None
        self._is_grabbed = False
        self._values = Device._EventValueSet(self)
        self._absinfos = Device._InputAbsInfoSet(self)

        if fd is not None:
            try:
                self._libevdev.set_clock_id(time.CLOCK_MONOTONIC)
            except AttributeError:
                self._libevdev.set_clock_id(1)

    @property
    def name(self) -> str:
        """
        :returns: the device name
        """
        return self._libevdev.name

    @name.setter
    def name(self, name: str):
        self._libevdev.name = name

    @property
    def phys(self) -> str | None:
        """
        :returns: the device's kernel phys or None.
        """
        return self._libevdev.phys

    @phys.setter
    def phys(self, phys: str | None):
        self._libevdev.phys = phys

    @property
    def uniq(self) -> str | None:
        """
        :returns: the device's uniq string or None
        """
        return self._libevdev.uniq

    @uniq.setter
    def uniq(self, uniq: str | None):
        self._libevdev.uniq = uniq

    @property
    def driver_version(self) -> int:
        """
        :returns: the device's driver version
        """
        return self._libevdev.driver_version

    @property
    def id(self) -> dict[str, int]:
        """
        :returns: A dict with the keys ``'bustype'``, ``'vendor'``,
                  ``'product'``, ``'version'``.

        When used as a setter, only existing keys are applied to the
        device. For example, to update the product ID only::

                ctx = Device()
                ids = {'product' : 1234}
                ctx.id = ids

        You must assign a new dictionary to ``id``. Technical limitations
        prohibit accessing the ``id`` dictionary itself for write access.
        See this example: ::

                $ ctx = Device()
                $ ctx.id['vendor'] = 1234
                $ print(ctx.id['vendor'])
                0
                $ ctx.id = {'vendor': 1234}
                $ print(ctx.id['vendor'])
                1234

        """
        return self._libevdev.id

    @id.setter
    def id(self, vals: dict[str, int]):
        self._libevdev.id = vals

    @property
    def fd(self) -> BinaryIO | None:
        """
        This fd represents the file descriptor to this device, if any. If no
        fd was provided in the constructor, None is returned. If the device
        was used to create a uinput device, None is returned.

        The fd may only be changed if it was not initially None and then it
        overwrites the file object provided in the constructor (or a
        previous call to this function). The new file object becomes the
        object referencing this device, further events are polled from that
        file.

        .. warning::

            A device initialized without a file descriptor may not change
            its fd.

        Note that libevdev does not synchronize the device and relies on the
        caller to ensure that the new file object points to the same device
        as this context. If the underlying device changes, the behavior
        is undefined.

        :raises: InvalidFileError - the file is invalid or this device does
            not allow a file to be set

        """
        return self._libevdev.fd

    @fd.setter
    def fd(self, fileobj: BinaryIO):
        if self._libevdev.fd is None:
            raise InvalidFileError()
        self._libevdev.fd = fileobj
        try:
            self._libevdev.set_clock_id(time.CLOCK_MONOTONIC)
        except AttributeError:
            self._libevdev.set_clock_id(1)
        if self._is_grabbed:
            self.grab()

    @property
    def evbits(self) -> dict[EventType, list[EventCode]]:
        """
        Returns a dict with all supported event types and event codes, in
        the form of::

            {
              libevdev.EV_ABS: [libevdev.EV_ABS.ABS_X, ...],
              libevdev.EV_KEY: [libevdev.EV_KEY.BTN_LEFT, ...],
            }
        """
        types = {}
        for t in libevdev.types:
            if not self.has(t):
                continue

            codes = []
            for c in t.codes:
                if not self.has(c):
                    continue
                codes.append(c)
            types[t] = codes

        return types

    @property
    def properties(self) -> list[InputProperty]:
        """
        Returns a list of all supported input properties
        """
        return [p for p in libevdev.props if self.has_property(p)]

    def has_property(self, prop: InputProperty) -> bool:
        """
        :param prop: a property
        :returns: True if the device has the property, False otherwise
        """
        return self._libevdev.has_property(prop.value)

    def has(self, evcode: EventType | EventCode) -> bool:
        """
        :param evcode: the event type or event code
        :type evcode: EventType or EventCode
        :returns: True if the device has the type and/or code, False otherwise
        """
        if isinstance(evcode, EventCode):
            return self._libevdev.has_event(evcode.type.value, evcode.value)
        else:
            return self._libevdev.has_event(evcode.value)

    @property
    def num_slots(self) -> int | None:
        """
        :returns: the number of slots on this device or ``None`` if this device
                 does not support slots

        :note: Read-only
        """
        return self._libevdev.num_slots

    @property
    def current_slot(self) -> int | None:
        """
        :returns: the current slot on this device or ``None`` if this device
                 does not support slots

        :note: Read-only
        """
        return self._libevdev.current_slot

    @property
    def absinfo(self) -> "Device._InputAbsInfoSet":
        """
        Query the device's absinfo for the given event code. This attribute
        can both query and modify the :class:`InputAbsInfo` values of this
        device::

            >>> ai = d.absinfo[libevdev.EV_ABS.ABS_X]
            >>> print(f'Resolution is {ai.resolution}')
            Resolution is 33
            >>> ai = d.absinfo[libevdev.EV_ABS.ABS_Z]
            >>> print(ai)
            None

        The returned object is a dict-like object that only accepts event
        codes of type `EV_ABS` as keys. No other operation than key-based
        access is supported.

        When used as a setter, the provided :class:`InputAbsInfo` becomes
        the new absinfo of this axis::

            >>> ai = d.absinfo[libevdev.EV_ABS.ABS_X]
            >>> print(f'Resolution is {ai.resolution}')
            Resolution is 33
            >>> ai.resolution = 45
            >>> d.absinfo[libevdev.EV_ABS.ABS_X] = ai
            >>> ai = d.absinfo[libevdev.EV_ABS.ABS_X]
            >>> print(f'Resolution is now {ai.resolution}')
            Resolution is now 45

        When used as a setter, any attribute of :class:`InputAbsInfo` that
        is ``None`` is ignored::

            >>> ai = InputAbsInfo(resolution=72)
            >>> d.absinfo[libevdev.EV_ABS.ABS_X] = ai
            >>> ai = d.absinfo[libevdev.EV_ABS.ABS_X]
            >>> print(f'Resolution is now {ai.resolution}')
            Resolution is now 72

        .. warning::

            Setting the absinfo for a non-existing EV_ABS code is invalid.
            Use :func:`enable()` instead.

        :returns: an class:`InputAbsInfo` struct or None if the device does
                  not have the event code
        :raises: :class:`InvalidArgumentException` when trying to set an
                 axis that is not enabled.
        """
        return self._absinfos

    def sync_absinfo_to_kernel(self, code: EventCode) -> None:
        """
        Synchronizes our view of an absinfo axis to the kernel, thus
        updating the the device for every other client. This function should
        be used with care. Not only does it change the kernel device and
        thus may affect the behavior of other processes but it is racy: any
        client that has this device node open already may never see the
        updates.

        To use this function, update the absinfo for the desired axis
        first::

            >>> fd = open('/dev/input/event0', 'rb')
            >>> d = libevdev.Device(fd)
            >>> ai = InputAbsInfo(resolution=72)
            >>> d.absinfo[libevdev.EV_ABS.ABS_X] = ai
            >>> d.sync_absinfo_to_kernel(libevdev.EV_ABS.ABS_X)
        """
        a = self.absinfo[code]
        assert a is not None
        assert a.minimum is not None
        assert a.maximum is not None
        assert a.resolution is not None
        assert a.fuzz is not None
        assert a.flat is not None
        data = {
            "minimum": a.minimum,
            "maximum": a.maximum,
            "fuzz": a.fuzz,
            "flat": a.flat,
            "resolution": a.resolution,
        }
        self._libevdev.absinfo(code.value, new_values=data, kernel=True)

    def events(self) -> Iterator[InputEvent]:
        """
        Returns an iterable with currently pending events.

        Event processing should look like this::

            fd = open("/dev/input/event0", "rb")
            fcntl.fcntl(fd, fcntl.F_SETFL, os.O_NONBLOCK)  # optional
            ctx = libevdev.Device(fd)

            while True:
                for e in ctx.events():
                    print(e):

                ... other mainloop code ...

        This function detects if the file descriptor is in blocking or
        non-blocking mode and adjusts its behavior accordingly. If the file
        descriptor is in nonblocking mode and no events are available, this
        function returns immediately. If the file descriptor is blocking,
        this function blocks if there are no events available.

        :returns: an iterable with the currently pending events
        """
        if self._libevdev.fd is None:
            return iter(())

        if os.get_blocking(self._libevdev.fd.fileno()):
            flags = READ_FLAG_BLOCKING
        else:
            flags = READ_FLAG_NORMAL

        ev = self._libevdev.next_event(flags)
        while ev is not None:
            code = libevdev.evbit(ev.type, ev.code)
            assert code is not None
            yield InputEvent(code, ev.value, ev.sec, ev.usec)
            if code == libevdev.SYN_DROPPED:
                raise EventsDroppedException()
            ev = self._libevdev.next_event(flags)

    def sync(self, force: bool = False) -> Iterator[InputEvent]:
        """
        Returns an iterator with events pending to re-sync the caller's
        view of the device with the one from libevdev.

        :param force: if set, the device forces an internal sync. This is
            required after changing the fd of the device when the device state
            may have changed while libevdev was not processing events.
        """
        if self._libevdev.fd is None:
            return iter(())

        if force:
            flags = READ_FLAG_FORCE_SYNC
        else:
            flags = READ_FLAG_SYNC

        ev = self._libevdev.next_event(flags)
        while ev is not None:
            code = libevdev.evbit(ev.type, ev.code)
            assert code is not None
            yield InputEvent(code, ev.value, ev.sec, ev.usec)
            ev = self._libevdev.next_event(flags)

    @property
    def value(self) -> "Device._EventValueSet":
        """
        Returns the current value for a given event code or None where the
        event code does not exist on the device::

            >>> d = libevdev.Device(fd)
            >>> print(d.value[libevdev.EV_ABS.ABS_X])
            1024
            >>> print(d.value[libevdev.EV_ABS.ABS_Y])
            512
            >>> print(d.value[libevdev.EV_ABS.ABS_Z])
            None

        The returned object is a dict-like object that only accepts event
        codes as keys. No other operation than key-based access is
        supported.

        The default value for all codes is 0. State-less axes like the
        ``EV_REL`` range always return 0 for all supported event codes.
        """
        return self._values

    @property
    def slots(self) -> tuple["Device._SlotValue", ...]:
        """
        Returns a tuple with the available slots, each of which contains a
        wrapper object to access a slot value::

           >>> d = libevdev.Device(fd)
           >>> print(d.slots[0][libevdev.EV_ABS.ABS_MT_POSITION_X])
           1000
           >>> print(d.slots[0][libevdev.EV_ABS.ABS_MT_POSITION_Y])
           500
           >>> print(d.slots[1][libevdev.EV_ABS.ABS_MT_POSITION_X])
           200
           >>> print(d.slots[1][libevdev.EV_ABS.ABS_MT_POSITION_Y])
           300

        Alternatively, the tuple can be iterated on::

           xcode = libevdev.EV_ABS.ABS_MT_POSITION_X
           ycode = libevdev.EV_ABS.ABS_MT_POSITION_Y

           for s in d.slots:
                position = (s[xcode], s[ycode])

        The only values available for each slot are the ones in the
        ``libevdev.EV_ABS.ABS_MT_*`` range (but not
        ``libevdev.EV_ABS.ABS_MT_SLOT``).
        """

        if self.num_slots is None:
            raise InvalidArgumentException("Device has no slots")

        return tuple(Device._SlotValue(self, slot) for slot in range(self.num_slots))

    def enable(
        self,
        event_code: EventCode | EventType | InputProperty,
        data: InputAbsInfo | int | None = None,
    ) -> None:
        """
        Enable an event type or event code on this device, even if not
        supported by this device.
        If event_code is an :class:`EventType`, that type is enabled and data
        is ignored.

        If event_code is one of ``libevdev.EV_ABS.ABS_*``, then data must be
        a :class:`InputAbsInfo`. Any unset fields of the
        :class:`InputAbsInfo` are replaced with
        0, i.e. the following example is valid and results in a
        fuzz/flat/resolution of zero::

                ctx = libevdev.Device()
                abs = InputAbsInfo(minimum=0, maximum=100)
                ctx.enable(libevdev.EV_ABS.ABS_X, data)

        If event_code is one of ``libevdev.EV_REP.REP_``, then data must be
        an integer.

        If event_code is one of ``libevdev.INPUT_PROP_``, then the given
        input property is enabled.

        :param event_code: the event code
        :type event_code: EventCode or EventType
        :param data: if event_code is not ``None``, data points to the
                     code-specific information.

        """
        if isinstance(event_code, InputProperty):
            self._libevdev.enable_property(event_code.value)
            return

        if isinstance(event_code, EventCode):
            raw_data = None
            if event_code.type == libevdev.EV_ABS:
                if data is None or not isinstance(data, InputAbsInfo):
                    raise InvalidArgumentException(
                        "enabling EV_ABS codes requires an InputAbsInfo"
                    )

                raw_data = {
                    "minimum": data.minimum or 0,
                    "maximum": data.maximum or 0,
                    "fuzz": data.fuzz or 0,
                    "flat": data.flat or 0,
                    "resolution": data.resolution or 0,
                }
            elif event_code.type == libevdev.EV_REP:
                if data is None or not isinstance(data, int):
                    raise InvalidArgumentException(
                        "enabling EV_REP codes requires an integer"
                    )
                raw_data = data

            self._libevdev.enable(event_code.type.value, event_code.value, raw_data)
        elif isinstance(event_code, EventType):
            self._libevdev.enable(event_code.value)

    def disable(self, event_code: EventCode | EventType) -> None:
        """
        Disable the given event type or event code on this device. If the
        device does not support this type or code, this function does
        nothing. Otherwise, all future events from this device that match
        this type or code will be discarded::

            >>> d.disable(libevdev.EV_ABS)
            # All EV_ABS events are filtered now
            >>> d.disable(libevdev.EV_KEY.BTN_LEFT)
            # All BTN_LEFt events are filtered now

        To re-enable an event type or code, use :func:`enable()`

        :param event_code: the event type or code
        :type event_code: EventType or EventCode
        """
        if isinstance(event_code, InputProperty):
            raise NotImplementedError()
        elif isinstance(event_code, EventCode):
            self._libevdev.disable(event_code.type.value, event_code.value)
        elif isinstance(event_code, EventType):
            self._libevdev.disable(event_code.value)

    @property
    def devnode(self) -> str | None:
        """
        Returns the device node for this device. The device node is None if
        this device has not been created as uinput device.
        """
        if not self._uinput:
            return None
        return self._uinput.devnode

    @property
    def syspath(self) -> str | None:
        """
        Returns the syspath for this device. The syspath is None if this
        device has not been created as uinput device.
        """
        if not self._uinput:
            return None
        return self._uinput.syspath

    def create_uinput_device(self, uinput_fd: BinaryIO | None = None) -> "Device":
        """
        Creates and returns a new :class:`Device` based on this libevdev
        device. The new device is equivalent to one created with
        ``libevdev.Device()``, i.e. it is one that does not have a file
        descriptor associated.

        To create a uinput device from an existing device::

            fd = open('/dev/input/event0', 'rb')
            d = libevdev.Device(fd)
            d.name = 'duplicated device'
            d.create_uinput_device()
            # d is now a duplicate of the event0 device with a custom name
            fd.close()

        Or to create a new device from scratch::

            d = libevdev.Device()
            d.name = 'test device'
            d.enable(libevdev.EV_KEY.BTN_LEFT)
            d.create_uinput_device()
            # d is now a device with a single button

        :param uinput_fd: A file descriptor to the /dev/input/uinput device. If None, the device is opened and closed automatically.
        :raises: OSError
        """
        d = Device()
        d.name = self.name
        d.id = self.id

        for t, cs in self.evbits.items():
            for c in cs:
                data: InputAbsInfo | int | None
                if t == libevdev.EV_ABS:
                    data = self.absinfo[c]
                elif t == libevdev.EV_REP:
                    data = self.value[c]
                else:
                    data = None
                d.enable(c, data)

        for p in self.properties:
            d.enable(p)

        d._uinput = UinputDevice(self._libevdev, uinput_fd)
        return d

    def send_events(self, events: list[InputEvent]) -> None:
        """
        Send the list of :class:`InputEvent` events through this device. All
        events must have a valid :class:`EventCode` and value, the timestamp
        in the event is ignored and the kernel fills in its own timestamp.

        This function may only be called on a uinput device, not on a normal
        device.

        .. warning::

            an event list must always be terminated with a
            ``libevdev.EV_SYN.SYN_REPORT`` event or the kernel may delay
            processing.

        :param events: a list of :class:`InputEvent` events
        """

        if not self._uinput:
            raise InvalidFileError()

        if any(e.type is None or e.code is None for e in events):
            raise InvalidArgumentException(
                "All events must have an event type and code"
            )

        if any(e.code.value is None for e in events):  # type: ignore
            raise InvalidArgumentException("All events must have a value")

        for e in events:
            assert (
                e.code is not None and e.code.value is not None and e.value is not None
            )
            self._uinput.write_event(e.type.value, e.code.value, e.value)

    def grab(self) -> None:
        """
        Exclusively grabs the device, preventing events from being seen by
        anyone else. This includes in-kernel consumers of the events (e.g.
        for rfkill) and should be used with care.

        A grab is valid until the file descriptor is closed or until
        :func:`ungrab` is called, whichever happens earlier. libevdev
        re-issues the grab on the device after changing the fd. If the
        original file descriptor is still open when changing the fd on the
        device, re-issuing the grab will fail silently::

            fd1 = open("/dev/input/event0", "rb")
            d = libevdev.Device(fd1)
            d.grab()
            # device is now exclusively grabbed

            fd1.close()
            fd2 = open("/dev/input/event0", "rb")
            d.fd = fd2
            # device is now exclusively grabbed

            fd3 = open("/dev/input/event0", "rb")
            d.fd = fd3
            # ERROR: fd2 is still open and the grab fails

        """
        try:
            self._libevdev.grab()
        except OSError:
            raise DeviceGrabError()

        self._is_grabbed = True

    def ungrab(self) -> None:
        """
        Removes an exclusive grabs on the device, see :func:`grab`.
        """
        self._libevdev.grab(False)
        self._is_grabbed = False

    def set_leds(self, leds: list[tuple[EventCode, int]]) -> None:
        """
        Write the LEDs to the device::

             >>> fd = open(path, 'r+b', buffering=0)
             >>> d = libevdev.Device(fd)
             >>> d.set_leds([(libevdev.EV_LED.LED_NUML, 0),
                             (libevdev.EV_LED.LED_SCROLLL, 1)])

        Updating LED states require the fd to be in write-mode.
        """
        for led in leds:
            if led[0].type is not libevdev.EV_LED:
                raise InvalidArgumentException("Event code must be one of EV_LED.*")

        for led in leds:
            self._libevdev.set_led(led[0].value, led[1] != 0)
