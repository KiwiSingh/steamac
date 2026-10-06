import random
import struct
import zlib

from hidtools.device.base_gamepad import AxisMapping, BaseGamepad, JoystickGamepad
from hidtools.util import BusType

import logging

logging.basicConfig(format="%(levelname)s: %(name)s: %(message)s", level=logging.INFO)
base_logger = logging.getLogger("hidtools")
logger = logging.getLogger("hidtools.device.sony_gamepad")


class InvalidHIDCommunication(Exception):
    pass


class GamepadData(object):
    pass


class PSBattery(object):
    """Represents a battery in a PlayStation controller."""

    def __init__(self) -> None:
        self.cable_connected = True
        self.capacity = 100  # capacity level %
        self.full = True  # battery full or not. Note: 100% doesn't guarantee 'full'.

    @property
    def capacity(self) -> int:
        return self._capacity

    @capacity.setter
    def capacity(self, value: int) -> None:
        if value < 0 or value > 100:
            raise ValueError("Invalid capacity")

        self._capacity = value

        # Set full to False when not at 100%. A user will explicitly
        # need to mark a 100% capacity battery as full by manually
        # toggling 'full'.
        if value != 100:
            self.full = False


class PS3Rumble(object):
    def __init__(self):
        self.right_duration = 0  # Right motor duration (0xff means forever)
        self.right_motor_on = (
            0  # Right (small) motor on/off, only supports values of 0 or 1 (off/on)
        )
        self.left_duration = 0  # Left motor duration (0xff means forever)
        self.left_motor_force = (
            0  # left (large) motor, supports force values from 0 to 255
        )
        self.offset = 1

    def parse(self, buf):
        (
            padding,
            self.right_duration,
            self.right_motor_on,
            self.left_duration,
            self.left_motor_force,
        ) = struct.unpack_from("< B B B B B", buf, self.offset)


class PS3LED(object):
    def __init__(self, idx):
        self.idx = idx
        self.offset = 11 + idx * 5
        self.time_enabled = 0  # the total time the led is active (0xff means forever)
        self.duty_length = (
            0  # how long a cycle is in deciseconds (0 means "really fast")
        )
        self.enabled = 0
        self.duty_off = 0  # % of duty_length the led is off (0xff means 100%)
        self.duty_on = 0  # % of duty_length the led is on (0xff mean 100%)

    def parse(self, buf):
        (
            self.time_enabled,
            self.duty_length,
            self.enabled,
            self.duty_off,
            self.duty_on,
        ) = struct.unpack_from("< B B B B B", buf, self.offset)


class PS3LEDs(object):
    def __init__(self):
        self.offset = 10
        self.leds_bitmap = 0
        self.leds = [PS3LED(i) for i in range(4)]

    def parse(self, buf):
        (self.leds_bitmap,) = struct.unpack_from("< B", buf, self.offset)
        for led in self.leds:
            led.parse(buf)

    def get_led(self, idx):
        return bool(self.leds_bitmap & (1 << idx + 1)), self.leds[idx]


class PS3Controller(JoystickGamepad):
    buttons_map = {
        1: "BTN_SELECT",
        2: "BTN_THUMBL",  # L3
        3: "BTN_THUMBR",  # R3
        4: "BTN_START",
        5: "BTN_DPAD_UP",
        6: "BTN_DPAD_RIGHT",
        7: "BTN_DPAD_DOWN",
        8: "BTN_DPAD_LEFT",
        9: "BTN_TL2",  # L2
        10: "BTN_TR2",  # R2 */
        11: "BTN_TL",  # L1 */
        12: "BTN_TR",  # R1 */
        13: "BTN_NORTH",  # options/triangle */
        14: "BTN_EAST",  # back/circle */
        15: "BTN_SOUTH",  # cross */
        16: "BTN_WEST",  # view/square */
        17: "BTN_MODE",  # PS button */
    }

    axes_map = {
        "left_stick": {
            "x": AxisMapping("x"),
            "y": AxisMapping("y"),
        },
        "right_stick": {
            "x": AxisMapping("z", "ABS_RX"),
            "y": AxisMapping("Rz", "ABS_RY"),
        },
    }

    # fmt: off
    report_descriptor = [
        0x05, 0x01,                    # Usage Page (Generic Desktop)        0
        0x09, 0x04,                    # Usage (Joystick)                    2
        0xa1, 0x01,                    # Collection (Application)            4
        0xa1, 0x02,                    # .Collection (Logical)               6
        0x85, 0x01,                    # ..Report ID (1)                     8
        0x75, 0x08,                    # ..Report Size (8)                   10
        0x95, 0x01,                    # ..Report Count (1)                  12
        0x15, 0x00,                    # ..Logical Minimum (0)               14
        0x26, 0xff, 0x00,              # ..Logical Maximum (255)             16
        0x81, 0x03,                    # ..Input (Cnst,Var,Abs)              19
        0x75, 0x01,                    # ..Report Size (1)                   21
        0x95, 0x13,                    # ..Report Count (19)                 23
        0x15, 0x00,                    # ..Logical Minimum (0)               25
        0x25, 0x01,                    # ..Logical Maximum (1)               27
        0x35, 0x00,                    # ..Physical Minimum (0)              29
        0x45, 0x01,                    # ..Physical Maximum (1)              31
        0x05, 0x09,                    # ..Usage Page (Button)               33
        0x19, 0x01,                    # ..Usage Minimum (1)                 35
        0x29, 0x13,                    # ..Usage Maximum (19)                37
        0x81, 0x02,                    # ..Input (Data,Var,Abs)              39
        0x75, 0x01,                    # ..Report Size (1)                   41
        0x95, 0x0d,                    # ..Report Count (13)                 43
        0x06, 0x00, 0xff,              # ..Usage Page (Vendor Defined Page 1) 45
        0x81, 0x03,                    # ..Input (Cnst,Var,Abs)              48
        0x15, 0x00,                    # ..Logical Minimum (0)               50
        0x26, 0xff, 0x00,              # ..Logical Maximum (255)             52
        0x05, 0x01,                    # ..Usage Page (Generic Desktop)      55
        0x09, 0x01,                    # ..Usage (Pointer)                   57
        0xa1, 0x00,                    # ..Collection (Physical)             59
        0x75, 0x08,                    # ...Report Size (8)                  61
        0x95, 0x04,                    # ...Report Count (4)                 63
        0x35, 0x00,                    # ...Physical Minimum (0)             65
        0x46, 0xff, 0x00,              # ...Physical Maximum (255)           67
        0x09, 0x30,                    # ...Usage (X)                        70
        0x09, 0x31,                    # ...Usage (Y)                        72
        0x09, 0x32,                    # ...Usage (Z)                        74
        0x09, 0x35,                    # ...Usage (Rz)                       76
        0x81, 0x02,                    # ...Input (Data,Var,Abs)             78
        0xc0,                          # ..End Collection                    80
        0x05, 0x01,                    # ..Usage Page (Generic Desktop)      81
        0x75, 0x08,                    # ..Report Size (8)                   83
        0x95, 0x27,                    # ..Report Count (39)                 85
        0x09, 0x01,                    # ..Usage (Pointer)                   87
        0x81, 0x02,                    # ..Input (Data,Var,Abs)              89
        0x75, 0x08,                    # ..Report Size (8)                   91
        0x95, 0x30,                    # ..Report Count (48)                 93
        0x09, 0x01,                    # ..Usage (Pointer)                   95
        0x91, 0x02,                    # ..Output (Data,Var,Abs)             97
        0x75, 0x08,                    # ..Report Size (8)                   99
        0x95, 0x30,                    # ..Report Count (48)                 101
        0x09, 0x01,                    # ..Usage (Pointer)                   103
        0xb1, 0x02,                    # ..Feature (Data,Var,Abs)            105
        0xc0,                          # .End Collection                     107
        0xa1, 0x02,                    # .Collection (Logical)               108
        0x85, 0x02,                    # ..Report ID (2)                     110
        0x75, 0x08,                    # ..Report Size (8)                   112
        0x95, 0x30,                    # ..Report Count (48)                 114
        0x09, 0x01,                    # ..Usage (Pointer)                   116
        0xb1, 0x02,                    # ..Feature (Data,Var,Abs)            118
        0xc0,                          # .End Collection                     120
        0xa1, 0x02,                    # .Collection (Logical)               121
        0x85, 0xee,                    # ..Report ID (238)                   123
        0x75, 0x08,                    # ..Report Size (8)                   125
        0x95, 0x30,                    # ..Report Count (48)                 127
        0x09, 0x01,                    # ..Usage (Pointer)                   129
        0xb1, 0x02,                    # ..Feature (Data,Var,Abs)            131
        0xc0,                          # .End Collection                     133
        0xa1, 0x02,                    # .Collection (Logical)               134
        0x85, 0xef,                    # ..Report ID (239)                   136
        0x75, 0x08,                    # ..Report Size (8)                   138
        0x95, 0x30,                    # ..Report Count (48)                 140
        0x09, 0x01,                    # ..Usage (Pointer)                   142
        0xb1, 0x02,                    # ..Feature (Data,Var,Abs)            144
        0xc0,                          # .End Collection                     146
        0xc0,                          # End Collection                      147
    ]
    # fmt: on

    def __init__(self, rdesc=report_descriptor, name="Sony PLAYSTATION(R)3 Controller"):
        super().__init__(rdesc, name=name, input_info=(BusType.USB, 0x054C, 0x0268))
        self.uniq = ":".join([f"{random.randint(0, 0xFF):02x}" for i in range(6)])
        self.buttons = tuple(range(1, 18))
        self.current_mode = "plugged-in"
        self.rumble = PS3Rumble()
        self.hw_leds = PS3LEDs()

    def is_ready(self):
        return super().is_ready() and len(self.led_classes) == 4

    def get_report(self, req, rnum, rtype):
        rdesc = None
        assert self.parsed_rdesc is not None
        for v in self.parsed_rdesc.feature_reports.values():
            if v.report_ID == rnum:
                rdesc = v

        logger.debug(f"get_report {rdesc}, {req}, {rnum}, {rtype}")

        if rnum == 0xF2:
            # undocumented report in the HID report descriptor:
            # the MAC address of the device is stored in the bytes 4-9
            # rest has been dumped on a Sixaxis controller
            # fmt: off
            r = [0xf2, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0x40, 0x80, 0x18, 0x01, 0x8a]
            # fmt: on

            # store the uniq value in the report
            for id, v in enumerate(self.uniq.split(":")):
                r[4 + id] = int(v, 16)

            # change the mode to operational
            self.current_mode = "operational"
            return (0, r)

        if rnum == 0xF5:
            return (0, [0x01, 0x00, 0x18, 0x5E, 0x0F, 0x71, 0xA4, 0xBB])

        if rdesc is None:
            return (1, [])

        return (1, [])

    def set_report(self, req, rnum, rtype, data):
        rdesc = None
        assert self.parsed_rdesc is not None
        for v in self.parsed_rdesc.feature_reports.values():
            if v.report_ID == rnum:
                rdesc = v

        logger.debug(f"set_report {bool(rdesc)}, {req}, {rnum}, {rtype}, {data}")

        if rdesc is None:
            return 1

        if rnum != 1:
            return 1

        # we have an output report to set the rumbles and LEDs
        buf = struct.pack(f"< {len(data)}B", *data)
        self.rumble.parse(buf)
        self.hw_leds.parse(buf)

        return 0

    def output_report(self, data, size, rtype):
        logger.debug(f"output_report {data[: size + 1]}, {size}, {rtype}")

    def create_report(
        self,
        *,
        left=(None, None),
        right=(None, None),
        hat_switch=None,
        buttons=None,
        reportID=None,
    ):
        """
        Return an input report for this device.

        :param left: a tuple of absolute (x, y) value of the left joypad
            where ``None`` is "leave unchanged"
        :param right: a tuple of absolute (x, y) value of the right joypad
            where ``None`` is "leave unchanged"
        :param hat_switch: an absolute angular value of the hat switch
            where ``None`` is "leave unchanged"
        :param buttons: a dict of index/bool for the button states,
            where ``None`` is "leave unchanged"
        :param reportID: the numeric report ID for this report, if needed
        """
        if self.current_mode != "operational":
            raise InvalidHIDCommunication(
                f"controller in incorrect mode: {self.current_mode}"
            )

        return super().create_report(
            left=left,
            right=right,
            hat_switch=hat_switch,
            buttons=buttons,
            reportID=reportID,
            application="Joystick",
        )


class PSSensor(object):
    """Represents a PlayStation accelerometer or gyroscope."""

    def __init__(self, calibration_data):
        self.calibration_data = calibration_data
        self.x = 0
        self.y = 0
        self.z = 0

    def uncalibrate(self, value, calibration_data):
        """Convert calibrated sensor data to raw 'uncalibrated' data."""

        # Perform inverse of calibration logic performed by hid-sony driver.
        # It performs: (raw_value - bias) * numer / denom.
        # Below we use the same variable names e.g. denom, numer and bias, though
        # they are used in reverse, so "denom" is actually now a numerator.
        return int(
            value * calibration_data["denom"] / calibration_data["numer"]
            + calibration_data["bias"]
        )

    @property
    def raw_x(self) -> int:
        return self._raw_x

    @property
    def raw_y(self) -> int:
        return self._raw_y

    @property
    def raw_z(self) -> int:
        return self._raw_z

    @property
    def x(self) -> int:
        return self._x

    @x.setter
    def x(self, value: int) -> None:
        self._x = value
        self._raw_x = self.uncalibrate(value, self.calibration_data["x"])

    @property
    def y(self) -> int:
        return self._y

    @y.setter
    def y(self, value: int) -> None:
        self._y = value
        self._raw_y = self.uncalibrate(value, self.calibration_data["y"])

    @property
    def z(self) -> int:
        return self._z

    @z.setter
    def z(self, value: int) -> None:
        self._z = value
        self._raw_z = self.uncalibrate(value, self.calibration_data["z"])


class PSTouchPoint(object):
    """Represents a touch point on a PlayStation gamepad."""

    def __init__(self, id, x, y):
        self.contactid = id
        self.tipswitch = True
        self.x = x
        self.y = y


class PSTouchReport(object):
    """Represents a single touch report within a PlayStation gamepad input report.
    A PSTouchReport consists of a timestamp and upto two touch points.
    """

    def __init__(self, points, timestamp=0):
        self.timestamp = timestamp
        self.contact_ids = []

        if len(points) > 2:
            raise ValueError(
                "Invalid number of touch points provided for PSTouchReport."
            )

        # convert the list of points to a dict
        self.points = {p.contactid: p for p in points}

        # Always ensure we store 2 touch points.
        if len(points) == 0:
            self.contact_ids = [None, None]
        elif len(points) == 1:
            self.contact_ids = [points[0].contactid, None]
        else:
            self.contact_ids = [p.contactid for p in points]

    def _update_contact_ids(self, last_touch_report):
        # ensure we keep the previous order of points
        if last_touch_report is not None:
            # first pass, copy the last_touch_report list, and remove all ids
            # that are not valid anymore
            contact_ids = last_touch_report.contact_ids[:]
            for pos, i in enumerate(last_touch_report.contact_ids):
                if i not in self.contact_ids:
                    contact_ids[pos] = None

            # second pass, fill the holes
            for i in self.contact_ids:
                if i not in contact_ids:
                    contact_ids[contact_ids.index(None)] = i

            # store the result
            self.contact_ids = contact_ids

    def fill_values(self, last_touch_report, report, offset):
        """Fill touch report data into main input report."""

        self._update_contact_ids(last_touch_report)

        report[offset] = self.timestamp

        for i in self.contact_ids:
            if i is None:
                report[offset + 1] = 0x80  # Mark inactive.
            else:
                p = self.points[i]
                report[offset + 1] = (p.contactid & 0x7F) | (
                    0x0 if p.tipswitch else 0x80
                )
                report[offset + 2] = p.x & 0xFF
                report[offset + 3] = (p.x >> 8) & 0xF | ((p.y & 0xF) << 4)
                report[offset + 4] = (p.y >> 4) & 0xFF
            offset += 4


class PS4Controller(BaseGamepad):
    buttons_map = {
        1: "BTN_WEST",  # square
        2: "BTN_SOUTH",  # cross
        3: "BTN_EAST",  # circle
        4: "BTN_NORTH",  # triangle
        5: "BTN_TL",  # L1
        6: "BTN_TR",  # R1
        7: "BTN_TL2",  # L2
        8: "BTN_TR2",  # R2
        9: "BTN_SELECT",  # share
        10: "BTN_START",  # options
        11: "BTN_THUMBL",  # L3
        12: "BTN_THUMBR",  # R3
        13: "BTN_MODE",  # PS button
    }

    axes_map = {
        "left_stick": {
            "x": AxisMapping("x"),
            "y": AxisMapping("y"),
        },
        "right_stick": {
            "x": AxisMapping("z", "ABS_RX"),
            "y": AxisMapping("Rz", "ABS_RY"),
        },
    }

    # DS4 reports uncalibrated sensor data. Calibration coefficients
    # can be retrieved using a feature report (0x2 USB / 0x5 BT).
    # The values below are the processed calibration values for the
    # DS4s matching the feature reports of PS4ControllerBluetooth/USB
    # as dumped from hid-sony 'ds4_get_calibration_data'.
    accelerometer_calibration_data = {
        "x": {"bias": -73, "numer": 16384, "denom": 16472},
        "y": {"bias": -352, "numer": 16384, "denom": 16344},
        "z": {"bias": 81, "numer": 16384, "denom": 16319},
    }
    gyroscope_calibration_data = {
        "x": {"bias": 0, "numer": 1105920, "denom": 17827},
        "y": {"bias": 0, "numer": 1105920, "denom": 17777},
        "z": {"bias": 0, "numer": 1105920, "denom": 17748},
    }

    def __init__(self, rdesc, name, input_info):
        super().__init__(rdesc, name=name, input_info=input_info)
        self.uniq = ":".join([f"{random.randint(0, 0xFF):02x}" for i in range(6)])
        self.buttons = tuple(range(1, 13))
        self.battery = PSBattery()

        # The PS4 touchpad has its own section within the PS4 controller's main input report.
        # It contains data for multiple "touch reports", the latest and older ones.
        # The size and location for the Touchpad report depends on the bus type USB or BT, where
        # the USB size 28 bytes and BT has 37 bytes.
        # In USB-mode the gamepad reports touch data in reportID 1 and for BT in the undocumented
        # reportID 17.
        if self.bus == BusType.USB:
            self.max_touch_reports = 3
            self.accelerometer_offset = 19
            self.battery_offset = 30
            self.gyroscope_offset = 13
            self.touchpad_offset = (
                33  # Touchpad section starts at byte 33 for USB-mode.
            )
        elif self.bus == BusType.BLUETOOTH:
            self.max_touch_reports = 4
            self.accelerometer_offset = 21
            self.battery_offset = 32
            self.gyroscope_offset = 15
            self.touchpad_offset = 35  # Touchpad section starts at byte 35 for BT-mode.

        self.accelerometer = PSSensor(self.accelerometer_calibration_data)
        self.gyroscope = PSSensor(self.gyroscope_calibration_data)

        # Used for book keeping
        self.touch_reports = []
        self.last_touch_report = None

    def is_ready(self):
        return (
            super().is_ready()
            and len(self.input_nodes) == 3
            and len(self.led_classes) == 4
            and self.power_supply_class is not None
        )

    def fill_accelerometer_values(self, report):
        """Fill accelerometer section of main input report with raw accelerometer data."""
        offset = self.accelerometer_offset

        report[offset] = self.accelerometer.raw_x & 0xFF
        report[offset + 1] = (self.accelerometer.raw_x >> 8) & 0xFF
        report[offset + 2] = self.accelerometer.raw_y & 0xFF
        report[offset + 3] = (self.accelerometer.raw_y >> 8) & 0xFF
        report[offset + 4] = self.accelerometer.raw_z & 0xFF
        report[offset + 5] = (self.accelerometer.raw_z >> 8) & 0xFF

    def fill_battery_values(self, report):
        """Fill battery section of main input report with battery status."""

        # Battery capacity and charging status is stored in 1 byte.
        # Lower 3-bit of contains battery capacity:
        # - 0 to 10 corresponds to 0-100%
        # - 11 battery full (for some reason different than 100%)
        # Bit 4 contains cable connection status.

        if self.battery.full:
            battery_capacity = 11
        else:
            battery_capacity = int(self.battery.capacity / 10) & 0xF

        # Cable connected
        cable_connected = (
            1 if self.battery.cable_connected or self.bus == BusType.USB else 0
        )

        report[self.battery_offset] = (cable_connected << 4) | battery_capacity

    def fill_gyroscope_values(self, report):
        """Fill gyroscope section of main input report with raw gyroscope data."""
        offset = self.gyroscope_offset

        report[offset] = self.gyroscope.raw_x & 0xFF
        report[offset + 1] = (self.gyroscope.raw_x >> 8) & 0xFF
        report[offset + 2] = self.gyroscope.raw_y & 0xFF
        report[offset + 3] = (self.gyroscope.raw_y >> 8) & 0xFF
        report[offset + 4] = self.gyroscope.raw_z & 0xFF
        report[offset + 5] = (self.gyroscope.raw_z >> 8) & 0xFF

    def fill_touchpad_values(self, report):
        """Fill touchpad "sub-report" section of main input report with touch data."""

        # Layout of PS4Touchpad report:
        # +0 valid report count (max 3 for USB and 4 for BT)
        # +1-10 TouchReport0 (latest data)
        # +11-19 TouchReport1
        # +20-28 TouchReport2
        # +29-37 TouchReport3, but only in BT-mode.
        #
        # TouchReport layout
        # +0 timestamp count = 682.7μs
        # +1-4 TouchPoint0
        # +5-9 TouchPoint1
        #
        # TouchPoint layout
        # +0 bit7 active/inactive, bit6:0 touch id
        # +1 lower 8-bit of x-axis
        # +2 7:4 lower 4-bit of y-axis, 3:0 highest 4-bits of x-axis
        # +3 higher 8-bit of y-axis

        offset = self.touchpad_offset  # Byte 0 of touchpad report.
        report[offset] = len(self.touch_reports)

        offset += 1 + 9 * (self.max_touch_reports - 1)  # Move to last touchpad report
        for i in range(self.max_touch_reports - 1, -1, -1):
            if i < len(self.touch_reports):
                self.touch_reports[i].fill_values(
                    self.last_touch_report, report, offset
                )
                self.last_touch_report = self.touch_reports[i]
            else:
                # Inactive touch reports need to have points marked as inactive.
                report[offset + 1] = 0x80
                report[offset + 5] = 0x80

            offset -= 9

    def store_accelerometer_state(self, accel):
        if accel[0] is not None:
            self.accelerometer.x = accel[0]
        if accel[1] is not None:
            self.accelerometer.y = accel[1]
        if accel[2] is not None:
            self.accelerometer.z = accel[2]

    def store_gyroscope_state(self, gyro):
        if gyro[0] is not None:
            self.gyroscope.x = gyro[0]
        if gyro[1] is not None:
            self.gyroscope.y = gyro[1]
        if gyro[2] is not None:
            self.gyroscope.z = gyro[2]

    def store_touchpad_state(self, touch):
        if touch is None:
            return
        elif touch is not None and len(touch) > 2:
            raise ValueError("More points provided than hardware supports.")
        elif len(touch) == 0:
            self.touch_reports = None
            self.last_touch_report = None
        else:
            # clean up already sent data
            if self.touch_reports and self.last_touch_report == self.touch_reports[-1]:
                self.touch_reports = self.touch_reports[:-1]
            touch_report = PSTouchReport(touch)
            # PS4 controller stores history newest to oldest, so do the same.
            self.touch_reports.insert(0, touch_report)
            # Remove oldest reports out of hardware limits.
            self.touch_reports = self.touch_reports[0 : self.max_touch_reports - 1]

    def event(
        self,
        *,
        left=(None, None),
        right=(None, None),
        hat_switch=None,
        buttons=None,
        touch=None,
        accel=(None, None, None),
        gyro=(None, None, None),
        inject=True,
    ):
        """
        Send an input event on the default report ID.

        :param left: a tuple of absolute (x, y) value of the left joypad
            where ``None`` is "leave unchanged"
        :param right: a tuple of absolute (x, y) value of the right joypad
            where ``None`` is "leave unchanged"
        :param hat_switch: an absolute angular value of the hat switch
            where ``None`` is "leave unchanged"
        :param buttons: a dict of index/bool for the button states,
            where ``None`` is "leave unchanged"
        :param touch: a list of up to two touch points :class:`PSTouchPoint`,
            where ``None`` is "leave unchanged and '[]' is release all fingers.
        :param accel: a tuple of absolute (x, y, z) values for the accelerometer
            where ``None`` is "leave unchanged"
        :param gyro: a tuple of absolute (x, y, z) values for the gyroscope
            where ``None`` is "leave unchanged"
        :param inject: bool whether to inject new event into the kernel.
            When set to False this can be used to build up touch history.
        """

        r = self.create_report(
            left=left,
            right=right,
            hat_switch=hat_switch,
            buttons=buttons,
            touch=touch,
            accel=accel,
            gyro=gyro,
        )

        if inject:
            self.call_input_event(r)

            # We allow history to accumulate when inject is False. After injecting,
            # clear all state.
            if len(self.touch_reports) > 1:
                self.touch_reports = [self.touch_reports[0]]

        return [r]


class PS4ControllerBluetooth(PS4Controller):
    # fmt: off
    report_descriptor = [
        0x05, 0x01,                    # Usage Page (Generic Desktop)        0
        0x09, 0x05,                    # Usage (Game Pad)                    2
        0xa1, 0x01,                    # Collection (Application)            4
        0x85, 0x01,                    # .Report ID (1)                      6
        0x09, 0x30,                    # .Usage (X)                          8
        0x09, 0x31,                    # .Usage (Y)                          10
        0x09, 0x32,                    # .Usage (Z)                          12
        0x09, 0x35,                    # .Usage (Rz)                         14
        0x15, 0x00,                    # .Logical Minimum (0)                16
        0x26, 0xff, 0x00,              # .Logical Maximum (255)              18
        0x75, 0x08,                    # .Report Size (8)                    21
        0x95, 0x04,                    # .Report Count (4)                   23
        0x81, 0x02,                    # .Input (Data,Var,Abs)               25
        0x09, 0x39,                    # .Usage (Hat switch)                 27
        0x15, 0x00,                    # .Logical Minimum (0)                29
        0x25, 0x07,                    # .Logical Maximum (7)                31
        0x75, 0x04,                    # .Report Size (4)                    33
        0x95, 0x01,                    # .Report Count (1)                   35
        0x81, 0x42,                    # .Input (Data,Var,Abs,Null)          37
        0x05, 0x09,                    # .Usage Page (Button)                39
        0x19, 0x01,                    # .Usage Minimum (1)                  41
        0x29, 0x0e,                    # .Usage Maximum (14)                 43
        0x15, 0x00,                    # .Logical Minimum (0)                45
        0x25, 0x01,                    # .Logical Maximum (1)                47
        0x75, 0x01,                    # .Report Size (1)                    49
        0x95, 0x0e,                    # .Report Count (14)                  51
        0x81, 0x02,                    # .Input (Data,Var,Abs)               53
        0x75, 0x06,                    # .Report Size (6)                    55
        0x95, 0x01,                    # .Report Count (1)                   57
        0x81, 0x01,                    # .Input (Cnst,Arr,Abs)               59
        0x05, 0x01,                    # .Usage Page (Generic Desktop)       61
        0x09, 0x33,                    # .Usage (Rx)                         63
        0x09, 0x34,                    # .Usage (Ry)                         65
        0x15, 0x00,                    # .Logical Minimum (0)                67
        0x26, 0xff, 0x00,              # .Logical Maximum (255)              69
        0x75, 0x08,                    # .Report Size (8)                    72
        0x95, 0x02,                    # .Report Count (2)                   74
        0x81, 0x02,                    # .Input (Data,Var,Abs)               76
        0x06, 0x04, 0xff,              # .Usage Page (Vendor Usage Page 0xff04) 78
        0x85, 0x02,                    # .Report ID (2)                      81
        0x09, 0x24,                    # .Usage (Vendor Usage 0x24)          83
        0x95, 0x24,                    # .Report Count (36)                  85
        0xb1, 0x02,                    # .Feature (Data,Var,Abs)             87
        0x85, 0xa3,                    # .Report ID (163)                    89
        0x09, 0x25,                    # .Usage (Vendor Usage 0x25)          91
        0x95, 0x30,                    # .Report Count (48)                  93
        0xb1, 0x02,                    # .Feature (Data,Var,Abs)             95
        0x85, 0x05,                    # .Report ID (5)                      97
        0x09, 0x26,                    # .Usage (Vendor Usage 0x26)          99
        0x95, 0x28,                    # .Report Count (40)                  101
        0xb1, 0x02,                    # .Feature (Data,Var,Abs)             103
        0x85, 0x06,                    # .Report ID (6)                      105
        0x09, 0x27,                    # .Usage (Vendor Usage 0x27)          107
        0x95, 0x34,                    # .Report Count (52)                  109
        0xb1, 0x02,                    # .Feature (Data,Var,Abs)             111
        0x85, 0x07,                    # .Report ID (7)                      113
        0x09, 0x28,                    # .Usage (Vendor Usage 0x28)          115
        0x95, 0x30,                    # .Report Count (48)                  117
        0xb1, 0x02,                    # .Feature (Data,Var,Abs)             119
        0x85, 0x08,                    # .Report ID (8)                      121
        0x09, 0x29,                    # .Usage (Vendor Usage 0x29)          123
        0x95, 0x2f,                    # .Report Count (47)                  125
        0xb1, 0x02,                    # .Feature (Data,Var,Abs)             127
        0x85, 0x09,                    # .Report ID (9)                      129
        0x09, 0x2a,                    # .Usage (Vendor Usage 0x2a)          131
        0x95, 0x13,                    # .Report Count (19)                  133
        0xb1, 0x02,                    # .Feature (Data,Var,Abs)             135
        0x06, 0x03, 0xff,              # .Usage Page (Vendor Usage Page 0xff03) 137
        0x85, 0x03,                    # .Report ID (3)                      140
        0x09, 0x21,                    # .Usage (Vendor Usage 0x21)          142
        0x95, 0x26,                    # .Report Count (38)                  144
        0xb1, 0x02,                    # .Feature (Data,Var,Abs)             146
        0x85, 0x04,                    # .Report ID (4)                      148
        0x09, 0x22,                    # .Usage (Vendor Usage 0x22)          150
        0x95, 0x2e,                    # .Report Count (46)                  152
        0xb1, 0x02,                    # .Feature (Data,Var,Abs)             154
        0x85, 0xf0,                    # .Report ID (240)                    156
        0x09, 0x47,                    # .Usage (Vendor Usage 0x47)          158
        0x95, 0x3f,                    # .Report Count (63)                  160
        0xb1, 0x02,                    # .Feature (Data,Var,Abs)             162
        0x85, 0xf1,                    # .Report ID (241)                    164
        0x09, 0x48,                    # .Usage (Vendor Usage 0x48)          166
        0x95, 0x3f,                    # .Report Count (63)                  168
        0xb1, 0x02,                    # .Feature (Data,Var,Abs)             170
        0x85, 0xf2,                    # .Report ID (242)                    172
        0x09, 0x49,                    # .Usage (Vendor Usage 0x49)          174
        0x95, 0x0f,                    # .Report Count (15)                  176
        0xb1, 0x02,                    # .Feature (Data,Var,Abs)             178
        0x06, 0x00, 0xff,              # .Usage Page (Vendor Defined Page 1) 180
        0x85, 0x11,                    # .Report ID (17)                     183
        0x09, 0x20,                    # .Usage (Vendor Usage 0x20)          185
        0x15, 0x00,                    # .Logical Minimum (0)                187
        0x26, 0xff, 0x00,              # .Logical Maximum (255)              189
        0x75, 0x08,                    # .Report Size (8)                    192
        0x95, 0x4d,                    # .Report Count (77)                  194
        0x81, 0x02,                    # .Input (Data,Var,Abs)               196
        0x09, 0x21,                    # .Usage (Vendor Usage 0x21)          198
        0x91, 0x02,                    # .Output (Data,Var,Abs)              200
        0x85, 0x12,                    # .Report ID (18)                     202
        0x09, 0x22,                    # .Usage (Vendor Usage 0x22)          204
        0x95, 0x8d,                    # .Report Count (141)                 206
        0x81, 0x02,                    # .Input (Data,Var,Abs)               208
        0x09, 0x23,                    # .Usage (Vendor Usage 0x23)          210
        0x91, 0x02,                    # .Output (Data,Var,Abs)              212
        0x85, 0x13,                    # .Report ID (19)                     214
        0x09, 0x24,                    # .Usage (Vendor Usage 0x24)          216
        0x95, 0xcd,                    # .Report Count (205)                 218
        0x81, 0x02,                    # .Input (Data,Var,Abs)               220
        0x09, 0x25,                    # .Usage (Vendor Usage 0x25)          222
        0x91, 0x02,                    # .Output (Data,Var,Abs)              224
        0x85, 0x14,                    # .Report ID (20)                     226
        0x09, 0x26,                    # .Usage (Vendor Usage 0x26)          228
        0x96, 0x0d, 0x01,              # .Report Count (269)                 230
        0x81, 0x02,                    # .Input (Data,Var,Abs)               233
        0x09, 0x27,                    # .Usage (Vendor Usage 0x27)          235
        0x91, 0x02,                    # .Output (Data,Var,Abs)              237
        0x85, 0x15,                    # .Report ID (21)                     239
        0x09, 0x28,                    # .Usage (Vendor Usage 0x28)          241
        0x96, 0x4d, 0x01,              # .Report Count (333)                 243
        0x81, 0x02,                    # .Input (Data,Var,Abs)               246
        0x09, 0x29,                    # .Usage (Vendor Usage 0x29)          248
        0x91, 0x02,                    # .Output (Data,Var,Abs)              250
        0x85, 0x16,                    # .Report ID (22)                     252
        0x09, 0x2a,                    # .Usage (Vendor Usage 0x2a)          254
        0x96, 0x8d, 0x01,              # .Report Count (397)                 256
        0x81, 0x02,                    # .Input (Data,Var,Abs)               259
        0x09, 0x2b,                    # .Usage (Vendor Usage 0x2b)          261
        0x91, 0x02,                    # .Output (Data,Var,Abs)              263
        0x85, 0x17,                    # .Report ID (23)                     265
        0x09, 0x2c,                    # .Usage (Vendor Usage 0x2c)          267
        0x96, 0xcd, 0x01,              # .Report Count (461)                 269
        0x81, 0x02,                    # .Input (Data,Var,Abs)               272
        0x09, 0x2d,                    # .Usage (Vendor Usage 0x2d)          274
        0x91, 0x02,                    # .Output (Data,Var,Abs)              276
        0x85, 0x18,                    # .Report ID (24)                     278
        0x09, 0x2e,                    # .Usage (Vendor Usage 0x2e)          280
        0x96, 0x0d, 0x02,              # .Report Count (525)                 282
        0x81, 0x02,                    # .Input (Data,Var,Abs)               285
        0x09, 0x2f,                    # .Usage (Vendor Usage 0x2f)          287
        0x91, 0x02,                    # .Output (Data,Var,Abs)              289
        0x85, 0x19,                    # .Report ID (25)                     291
        0x09, 0x30,                    # .Usage (Vendor Usage 0x30)          293
        0x96, 0x22, 0x02,              # .Report Count (546)                 295
        0x81, 0x02,                    # .Input (Data,Var,Abs)               298
        0x09, 0x31,                    # .Usage (Vendor Usage 0x31)          300
        0x91, 0x02,                    # .Output (Data,Var,Abs)              302
        0x06, 0x80, 0xff,              # .Usage Page (Vendor Usage Page 0xff80) 304
        0x85, 0x82,                    # .Report ID (130)                    307
        0x09, 0x22,                    # .Usage (Vendor Usage 0x22)          309
        0x95, 0x3f,                    # .Report Count (63)                  311
        0xb1, 0x02,                    # .Feature (Data,Var,Abs)             313
        0x85, 0x83,                    # .Report ID (131)                    315
        0x09, 0x23,                    # .Usage (Vendor Usage 0x23)          317
        0xb1, 0x02,                    # .Feature (Data,Var,Abs)             319
        0x85, 0x84,                    # .Report ID (132)                    321
        0x09, 0x24,                    # .Usage (Vendor Usage 0x24)          323
        0xb1, 0x02,                    # .Feature (Data,Var,Abs)             325
        0x85, 0x90,                    # .Report ID (144)                    327
        0x09, 0x30,                    # .Usage (Vendor Usage 0x30)          329
        0xb1, 0x02,                    # .Feature (Data,Var,Abs)             331
        0x85, 0x91,                    # .Report ID (145)                    333
        0x09, 0x31,                    # .Usage (Vendor Usage 0x31)          335
        0xb1, 0x02,                    # .Feature (Data,Var,Abs)             337
        0x85, 0x92,                    # .Report ID (146)                    339
        0x09, 0x32,                    # .Usage (Vendor Usage 0x32)          341
        0xb1, 0x02,                    # .Feature (Data,Var,Abs)             343
        0x85, 0x93,                    # .Report ID (147)                    345
        0x09, 0x33,                    # .Usage (Vendor Usage 0x33)          347
        0xb1, 0x02,                    # .Feature (Data,Var,Abs)             349
        0x85, 0xa0,                    # .Report ID (160)                    351
        0x09, 0x40,                    # .Usage (Vendor Usage 0x40)          353
        0xb1, 0x02,                    # .Feature (Data,Var,Abs)             355
        0x85, 0xa4,                    # .Report ID (164)                    357
        0x09, 0x44,                    # .Usage (Vendor Usage 0x44)          359
        0xb1, 0x02,                    # .Feature (Data,Var,Abs)             361
        0xc0,                          # End Collection                      363
    ]
    # fmt: on

    def __init__(self, rdesc=report_descriptor, name="Wireless Controller"):
        super().__init__(rdesc, name, (BusType.BLUETOOTH, 0x054C, 0x05C4))

    def get_report(self, req, rnum, rtype):
        rdesc = None
        assert self.parsed_rdesc is not None
        for v in self.parsed_rdesc.feature_reports.values():
            if v.report_ID == rnum:
                rdesc = v

        logger.debug(f"get_report {rdesc}, {req}, {rnum}, {rtype}")

        if rnum == 0x05:
            # Report to retrieve motion sensor calibration data.
            # fmt: off
            r = [0x05, 0x1e, 0x00, 0x05, 0x00, 0xe2, 0xff, 0xf2, 0x22, 0xbe, 0x22, 0x8d, 0x22, 0x4f,
                 0xdd, 0x4d, 0xdd, 0x39, 0xdd, 0x1c, 0x02, 0x1c, 0x02, 0xe3, 0x1f, 0x8b, 0xdf, 0x8c, 0x1e,
                 0xb4, 0xde, 0x30, 0x20, 0x71, 0xe0, 0x10, 0x00, 0xca, 0xfc, 0x64, 0x4d]
            # fmt: on
            return (0, r)

        elif rnum == 0xA3:
            # Report to retrieve hardware and firmware version.
            # fmt: off
            r = [0xa3, 0x41, 0x70, 0x72, 0x20, 0x20, 0x38, 0x20, 0x32, 0x30, 0x31, 0x34, 0x00, 0x00,
                 0x00, 0x00, 0x00, 0x30, 0x39, 0x3a, 0x34, 0x36, 0x3a, 0x30, 0x36, 0x00, 0x00, 0x00, 0x00,
                 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x43, 0x03, 0x00, 0x00, 0x00, 0x51, 0x00, 0x05,
                 0x00, 0x00, 0x80, 0x03, 0x00]
            # fmt: on
            return (0, r)

        if rdesc is None:
            return (1, [])

        return (1, [])

    def create_report(
        self,
        *,
        left=(None, None),
        right=(None, None),
        hat_switch=None,
        buttons=None,
        touch=None,
        accel=(None, None, None),
        gyro=(None, None, None),
        reportID=None,
    ):
        """
        Return an input report for this device.

        :param left: a tuple of absolute (x, y) value of the left joypad
            where ``None`` is "leave unchanged"
        :param right: a tuple of absolute (x, y) value of the right joypad
            where ``None`` is "leave unchanged"
        :param hat_switch: an absolute angular value of the hat switch
            where ``None`` is "leave unchanged"
        :param buttons: a dict of index/bool for the button states,
            where ``None`` is "leave unchanged"
        :param touch: a list of up to two touch points :class:`PSTouchPoint`,
            where ``None`` is "leave unchanged and '[]' is release all fingers.
        :param accel: a tuple of absolute (x, y, z) values for the accelerometer
            where ``None`` is "leave unchanged"
        :param gyro: a tuple of absolute (x, y, z) values for the gyroscope
            where ``None`` is "leave unchanged"
        :param reportID: the numeric report ID for this report, if needed
        """

        # Layout of Report 17:
        # +0 reportID (17)
        # +1 ??
        # +2 ??
        # +3-5 X/Y/RX/RY
        # +6-8 buttons
        # +9-10 Z 'L2'/ RZ 'R2'
        # +32 battery info: bit4 cable connected/disconnected, bit3:0 capacity
        # +37-73 touch report
        # +74-77 crc32

        report = [0] * 78
        report[0] = 17  # Report ID

        # The full Bluetooth HID report (17) is vendor specific and the HID parser has
        # no clue on how to interpret the data. However it knows how to parse HID report 1,
        # which is a subset of report 17. Leverage this report as a base to build the full report.
        base_report = super().create_report(
            left=left,
            right=right,
            hat_switch=hat_switch,
            buttons=buttons,
            reportID=reportID,
            application="Game Pad",
        )
        for i in range(len(base_report) - 1):
            # Start of data is 3 bytes shifted relative to Report 1.
            report[3 + i] = base_report[1 + i]

        self.store_accelerometer_state(accel)
        self.fill_accelerometer_values(report)

        self.store_gyroscope_state(gyro)
        self.fill_gyroscope_values(report)

        self.fill_battery_values(report)

        if touch:
            self.store_touchpad_state(touch)

        self.fill_touchpad_values(report)

        # CRC is calculated over the first 74 bytes.
        seed = zlib.crc32(bytes([0xA1]))
        crc = zlib.crc32(bytes(report[0:74]), seed)

        report[74] = crc & 0xFF
        report[75] = (crc >> 8) & 0xFF
        report[76] = (crc >> 16) & 0xFF
        report[77] = (crc >> 24) & 0xFF

        return report


class PS4ControllerUSB(PS4Controller):
    # fmt: off
    report_descriptor = [
        0x05, 0x01,                    # Usage Page (Generic Desktop)        0
        0x09, 0x05,                    # Usage (Game Pad)                    2
        0xa1, 0x01,                    # Collection (Application)            4
        0x85, 0x01,                    # .Report ID (1)                      6
        0x09, 0x30,                    # .Usage (X)                          8
        0x09, 0x31,                    # .Usage (Y)                          10
        0x09, 0x32,                    # .Usage (Z)                          12
        0x09, 0x35,                    # .Usage (Rz)                         14
        0x15, 0x00,                    # .Logical Minimum (0)                16
        0x26, 0xff, 0x00,              # .Logical Maximum (255)              18
        0x75, 0x08,                    # .Report Size (8)                    21
        0x95, 0x04,                    # .Report Count (4)                   23
        0x81, 0x02,                    # .Input (Data,Var,Abs)               25
        0x09, 0x39,                    # .Usage (Hat switch)                 27
        0x15, 0x00,                    # .Logical Minimum (0)                29
        0x25, 0x07,                    # .Logical Maximum (7)                31
        0x35, 0x00,                    # .Physical Minimum (0)               33
        0x46, 0x3b, 0x01,              # .Physical Maximum (315)             35
        0x65, 0x14,                    # .Unit (Degrees,EngRotation)         38
        0x75, 0x04,                    # .Report Size (4)                    40
        0x95, 0x01,                    # .Report Count (1)                   42
        0x81, 0x42,                    # .Input (Data,Var,Abs,Null)          44
        0x65, 0x00,                    # .Unit (None)                        46
        0x05, 0x09,                    # .Usage Page (Button)                48
        0x19, 0x01,                    # .Usage Minimum (1)                  50
        0x29, 0x0e,                    # .Usage Maximum (14)                 52
        0x15, 0x00,                    # .Logical Minimum (0)                54
        0x25, 0x01,                    # .Logical Maximum (1)                56
        0x75, 0x01,                    # .Report Size (1)                    58
        0x95, 0x0e,                    # .Report Count (14)                  60
        0x81, 0x02,                    # .Input (Data,Var,Abs)               62
        0x06, 0x00, 0xff,              # .Usage Page (Vendor Defined Page 1) 64
        0x09, 0x20,                    # .Usage (Vendor Usage 0x20)          67
        0x75, 0x06,                    # .Report Size (6)                    69
        0x95, 0x01,                    # .Report Count (1)                   71
        0x15, 0x00,                    # .Logical Minimum (0)                73
        0x25, 0x7f,                    # .Logical Maximum (127)              75
        0x81, 0x02,                    # .Input (Data,Var,Abs)               77
        0x05, 0x01,                    # .Usage Page (Generic Desktop)       79
        0x09, 0x33,                    # .Usage (Rx)                         81
        0x09, 0x34,                    # .Usage (Ry)                         83
        0x15, 0x00,                    # .Logical Minimum (0)                85
        0x26, 0xff, 0x00,              # .Logical Maximum (255)              87
        0x75, 0x08,                    # .Report Size (8)                    90
        0x95, 0x02,                    # .Report Count (2)                   92
        0x81, 0x02,                    # .Input (Data,Var,Abs)               94
        0x06, 0x00, 0xff,              # .Usage Page (Vendor Defined Page 1) 96
        0x09, 0x21,                    # .Usage (Vendor Usage 0x21)          99
        0x95, 0x36,                    # .Report Count (54)                  101
        0x81, 0x02,                    # .Input (Data,Var,Abs)               103
        0x85, 0x05,                    # .Report ID (5)                      105
        0x09, 0x22,                    # .Usage (Vendor Usage 0x22)          107
        0x95, 0x1f,                    # .Report Count (31)                  109
        0x91, 0x02,                    # .Output (Data,Var,Abs)              111
        0x85, 0x04,                    # .Report ID (4)                      113
        0x09, 0x23,                    # .Usage (Vendor Usage 0x23)          115
        0x95, 0x24,                    # .Report Count (36)                  117
        0xb1, 0x02,                    # .Feature (Data,Var,Abs)             119
        0x85, 0x02,                    # .Report ID (2)                      121
        0x09, 0x24,                    # .Usage (Vendor Usage 0x24)          123
        0x95, 0x24,                    # .Report Count (36)                  125
        0xb1, 0x02,                    # .Feature (Data,Var,Abs)             127
        0x85, 0x08,                    # .Report ID (8)                      129
        0x09, 0x25,                    # .Usage (Vendor Usage 0x25)          131
        0x95, 0x03,                    # .Report Count (3)                   133
        0xb1, 0x02,                    # .Feature (Data,Var,Abs)             135
        0x85, 0x10,                    # .Report ID (16)                     137
        0x09, 0x26,                    # .Usage (Vendor Usage 0x26)          139
        0x95, 0x04,                    # .Report Count (4)                   141
        0xb1, 0x02,                    # .Feature (Data,Var,Abs)             143
        0x85, 0x11,                    # .Report ID (17)                     145
        0x09, 0x27,                    # .Usage (Vendor Usage 0x27)          147
        0x95, 0x02,                    # .Report Count (2)                   149
        0xb1, 0x02,                    # .Feature (Data,Var,Abs)             151
        0x85, 0x12,                    # .Report ID (18)                     153
        0x06, 0x02, 0xff,              # .Usage Page (Vendor Usage Page 0xff02) 155
        0x09, 0x21,                    # .Usage (Vendor Usage 0x21)          158
        0x95, 0x0f,                    # .Report Count (15)                  160
        0xb1, 0x02,                    # .Feature (Data,Var,Abs)             162
        0x85, 0x13,                    # .Report ID (19)                     164
        0x09, 0x22,                    # .Usage (Vendor Usage 0x22)          166
        0x95, 0x16,                    # .Report Count (22)                  168
        0xb1, 0x02,                    # .Feature (Data,Var,Abs)             170
        0x85, 0x14,                    # .Report ID (20)                     172
        0x06, 0x05, 0xff,              # .Usage Page (Vendor Usage Page 0xff05) 174
        0x09, 0x20,                    # .Usage (Vendor Usage 0x20)          177
        0x95, 0x10,                    # .Report Count (16)                  179
        0xb1, 0x02,                    # .Feature (Data,Var,Abs)             181
        0x85, 0x15,                    # .Report ID (21)                     183
        0x09, 0x21,                    # .Usage (Vendor Usage 0x21)          185
        0x95, 0x2c,                    # .Report Count (44)                  187
        0xb1, 0x02,                    # .Feature (Data,Var,Abs)             189
        0x06, 0x80, 0xff,              # .Usage Page (Vendor Usage Page 0xff80) 191
        0x85, 0x80,                    # .Report ID (128)                    194
        0x09, 0x20,                    # .Usage (Vendor Usage 0x20)          196
        0x95, 0x06,                    # .Report Count (6)                   198
        0xb1, 0x02,                    # .Feature (Data,Var,Abs)             200
        0x85, 0x81,                    # .Report ID (129)                    202
        0x09, 0x21,                    # .Usage (Vendor Usage 0x21)          204
        0x95, 0x06,                    # .Report Count (6)                   206
        0xb1, 0x02,                    # .Feature (Data,Var,Abs)             208
        0x85, 0x82,                    # .Report ID (130)                    210
        0x09, 0x22,                    # .Usage (Vendor Usage 0x22)          212
        0x95, 0x05,                    # .Report Count (5)                   214
        0xb1, 0x02,                    # .Feature (Data,Var,Abs)             216
        0x85, 0x83,                    # .Report ID (131)                    218
        0x09, 0x23,                    # .Usage (Vendor Usage 0x23)          220
        0x95, 0x01,                    # .Report Count (1)                   222
        0xb1, 0x02,                    # .Feature (Data,Var,Abs)             224
        0x85, 0x84,                    # .Report ID (132)                    226
        0x09, 0x24,                    # .Usage (Vendor Usage 0x24)          228
        0x95, 0x04,                    # .Report Count (4)                   230
        0xb1, 0x02,                    # .Feature (Data,Var,Abs)             232
        0x85, 0x85,                    # .Report ID (133)                    234
        0x09, 0x25,                    # .Usage (Vendor Usage 0x25)          236
        0x95, 0x06,                    # .Report Count (6)                   238
        0xb1, 0x02,                    # .Feature (Data,Var,Abs)             240
        0x85, 0x86,                    # .Report ID (134)                    242
        0x09, 0x26,                    # .Usage (Vendor Usage 0x26)          244
        0x95, 0x06,                    # .Report Count (6)                   246
        0xb1, 0x02,                    # .Feature (Data,Var,Abs)             248
        0x85, 0x87,                    # .Report ID (135)                    250
        0x09, 0x27,                    # .Usage (Vendor Usage 0x27)          252
        0x95, 0x23,                    # .Report Count (35)                  254
        0xb1, 0x02,                    # .Feature (Data,Var,Abs)             256
        0x85, 0x88,                    # .Report ID (136)                    258
        0x09, 0x28,                    # .Usage (Vendor Usage 0x28)          260
        0x95, 0x3f,                    # .Report Count (63)                  262
        0xb1, 0x02,                    # .Feature (Data,Var,Abs)             264
        0x85, 0x89,                    # .Report ID (137)                    266
        0x09, 0x29,                    # .Usage (Vendor Usage 0x29)          268
        0x95, 0x02,                    # .Report Count (2)                   270
        0xb1, 0x02,                    # .Feature (Data,Var,Abs)             272
        0x85, 0x90,                    # .Report ID (144)                    274
        0x09, 0x30,                    # .Usage (Vendor Usage 0x30)          276
        0x95, 0x05,                    # .Report Count (5)                   278
        0xb1, 0x02,                    # .Feature (Data,Var,Abs)             280
        0x85, 0x91,                    # .Report ID (145)                    282
        0x09, 0x31,                    # .Usage (Vendor Usage 0x31)          284
        0x95, 0x03,                    # .Report Count (3)                   286
        0xb1, 0x02,                    # .Feature (Data,Var,Abs)             288
        0x85, 0x92,                    # .Report ID (146)                    290
        0x09, 0x32,                    # .Usage (Vendor Usage 0x32)          292
        0x95, 0x03,                    # .Report Count (3)                   294
        0xb1, 0x02,                    # .Feature (Data,Var,Abs)             296
        0x85, 0x93,                    # .Report ID (147)                    298
        0x09, 0x33,                    # .Usage (Vendor Usage 0x33)          300
        0x95, 0x0c,                    # .Report Count (12)                  302
        0xb1, 0x02,                    # .Feature (Data,Var,Abs)             304
        0x85, 0x94,                    # .Report ID (148)                    306
        0x09, 0x34,                    # .Usage (Vendor Usage 0x34)          308
        0x95, 0x3f,                    # .Report Count (63)                  310
        0xb1, 0x02,                    # .Feature (Data,Var,Abs)             312
        0x85, 0xa0,                    # .Report ID (160)                    314
        0x09, 0x40,                    # .Usage (Vendor Usage 0x40)          316
        0x95, 0x06,                    # .Report Count (6)                   318
        0xb1, 0x02,                    # .Feature (Data,Var,Abs)             320
        0x85, 0xa1,                    # .Report ID (161)                    322
        0x09, 0x41,                    # .Usage (Vendor Usage 0x41)          324
        0x95, 0x01,                    # .Report Count (1)                   326
        0xb1, 0x02,                    # .Feature (Data,Var,Abs)             328
        0x85, 0xa2,                    # .Report ID (162)                    330
        0x09, 0x42,                    # .Usage (Vendor Usage 0x42)          332
        0x95, 0x01,                    # .Report Count (1)                   334
        0xb1, 0x02,                    # .Feature (Data,Var,Abs)             336
        0x85, 0xa3,                    # .Report ID (163)                    338
        0x09, 0x43,                    # .Usage (Vendor Usage 0x43)          340
        0x95, 0x30,                    # .Report Count (48)                  342
        0xb1, 0x02,                    # .Feature (Data,Var,Abs)             344
        0x85, 0xa4,                    # .Report ID (164)                    346
        0x09, 0x44,                    # .Usage (Vendor Usage 0x44)          348
        0x95, 0x0d,                    # .Report Count (13)                  350
        0xb1, 0x02,                    # .Feature (Data,Var,Abs)             352
        0x85, 0xf0,                    # .Report ID (240)                    354
        0x09, 0x47,                    # .Usage (Vendor Usage 0x47)          356
        0x95, 0x3f,                    # .Report Count (63)                  358
        0xb1, 0x02,                    # .Feature (Data,Var,Abs)             360
        0x85, 0xf1,                    # .Report ID (241)                    362
        0x09, 0x48,                    # .Usage (Vendor Usage 0x48)          364
        0x95, 0x3f,                    # .Report Count (63)                  366
        0xb1, 0x02,                    # .Feature (Data,Var,Abs)             368
        0x85, 0xf2,                    # .Report ID (242)                    370
        0x09, 0x49,                    # .Usage (Vendor Usage 0x49)          372
        0x95, 0x0f,                    # .Report Count (15)                  374
        0xb1, 0x02,                    # .Feature (Data,Var,Abs)             376
        0x85, 0xa7,                    # .Report ID (167)                    378
        0x09, 0x4a,                    # .Usage (Vendor Usage 0x4a)          380
        0x95, 0x01,                    # .Report Count (1)                   382
        0xb1, 0x02,                    # .Feature (Data,Var,Abs)             384
        0x85, 0xa8,                    # .Report ID (168)                    386
        0x09, 0x4b,                    # .Usage (Vendor Usage 0x4b)          388
        0x95, 0x01,                    # .Report Count (1)                   390
        0xb1, 0x02,                    # .Feature (Data,Var,Abs)             392
        0x85, 0xa9,                    # .Report ID (169)                    394
        0x09, 0x4c,                    # .Usage (Vendor Usage 0x4c)          396
        0x95, 0x08,                    # .Report Count (8)                   398
        0xb1, 0x02,                    # .Feature (Data,Var,Abs)             400
        0x85, 0xaa,                    # .Report ID (170)                    402
        0x09, 0x4e,                    # .Usage (Vendor Usage 0x4e)          404
        0x95, 0x01,                    # .Report Count (1)                   406
        0xb1, 0x02,                    # .Feature (Data,Var,Abs)             408
        0x85, 0xab,                    # .Report ID (171)                    410
        0x09, 0x4f,                    # .Usage (Vendor Usage 0x4f)          412
        0x95, 0x39,                    # .Report Count (57)                  414
        0xb1, 0x02,                    # .Feature (Data,Var,Abs)             416
        0x85, 0xac,                    # .Report ID (172)                    418
        0x09, 0x50,                    # .Usage (Vendor Usage 0x50)          420
        0x95, 0x39,                    # .Report Count (57)                  422
        0xb1, 0x02,                    # .Feature (Data,Var,Abs)             424
        0x85, 0xad,                    # .Report ID (173)                    426
        0x09, 0x51,                    # .Usage (Vendor Usage 0x51)          428
        0x95, 0x0b,                    # .Report Count (11)                  430
        0xb1, 0x02,                    # .Feature (Data,Var,Abs)             432
        0x85, 0xae,                    # .Report ID (174)                    434
        0x09, 0x52,                    # .Usage (Vendor Usage 0x52)          436
        0x95, 0x01,                    # .Report Count (1)                   438
        0xb1, 0x02,                    # .Feature (Data,Var,Abs)             440
        0x85, 0xaf,                    # .Report ID (175)                    442
        0x09, 0x53,                    # .Usage (Vendor Usage 0x53)          444
        0x95, 0x02,                    # .Report Count (2)                   446
        0xb1, 0x02,                    # .Feature (Data,Var,Abs)             448
        0x85, 0xb0,                    # .Report ID (176)                    450
        0x09, 0x54,                    # .Usage (Vendor Usage 0x54)          452
        0x95, 0x3f,                    # .Report Count (63)                  454
        0xb1, 0x02,                    # .Feature (Data,Var,Abs)             456
        0x85, 0xe0,                    # .Report ID (224)                    458
        0x09, 0x57,                    # .Usage (Vendor Usage 0x57)          460
        0x95, 0x02,                    # .Report Count (2)                   462
        0xb1, 0x02,                    # .Feature (Data,Var,Abs)             464
        0x85, 0xb3,                    # .Report ID (179)                    466
        0x09, 0x55,                    # .Usage (Vendor Usage 0x55)          468
        0x95, 0x3f,                    # .Report Count (63)                  470
        0xb1, 0x02,                    # .Feature (Data,Var,Abs)             472
        0x85, 0xb4,                    # .Report ID (180)                    474
        0x09, 0x55,                    # .Usage (Vendor Usage 0x55)          476
        0x95, 0x3f,                    # .Report Count (63)                  478
        0xb1, 0x02,                    # .Feature (Data,Var,Abs)             480
        0x85, 0xb5,                    # .Report ID (181)                    482
        0x09, 0x56,                    # .Usage (Vendor Usage 0x56)          484
        0x95, 0x3f,                    # .Report Count (63)                  486
        0xb1, 0x02,                    # .Feature (Data,Var,Abs)             488
        0x85, 0xd0,                    # .Report ID (208)                    490
        0x09, 0x58,                    # .Usage (Vendor Usage 0x58)          492
        0x95, 0x3f,                    # .Report Count (63)                  494
        0xb1, 0x02,                    # .Feature (Data,Var,Abs)             496
        0x85, 0xd4,                    # .Report ID (212)                    498
        0x09, 0x59,                    # .Usage (Vendor Usage 0x59)          500
        0x95, 0x3f,                    # .Report Count (63)                  502
        0xb1, 0x02,                    # .Feature (Data,Var,Abs)             504
        0xc0,                          # End Collection                      506
    ]
    # fmt: on

    def __init__(self, rdesc=report_descriptor):
        super().__init__(
            rdesc,
            "Sony Computer Entertainment Wireless Controller",
            (BusType.USB, 0x054C, 0x05C4),
        )

    def get_report(self, req, rnum, rtype):
        rdesc = None
        assert self.parsed_rdesc is not None
        for v in self.parsed_rdesc.feature_reports.values():
            if v.report_ID == rnum:
                rdesc = v

        logger.debug(f"get_report {rdesc}, {req}, {rnum}, {rtype}")

        if rnum == 0x02:
            # Report to retrieve motion sensor calibration data.
            # fmt: off
            r = [0x02, 0x1e, 0x00, 0x05, 0x00, 0xe2, 0xff, 0xf2, 0x22, 0x4f, 0xdd, 0xbe, 0x22, 0x4d,
                 0xdd, 0x8d, 0x22, 0x39, 0xdd, 0x1c, 0x02, 0x1c, 0x02, 0xe3, 0x1f, 0x8b, 0xdf, 0x8c,
                 0x1e, 0xb4, 0xde, 0x30, 0x20, 0x71, 0xe0, 0x10, 0x00]
            # fmt: on
            return (0, r)

        elif rnum == 0x12:
            # Recommended report to retrieve MAC address of DS4.
            # Clone devices tend to support this one as well.
            # MAC address is stored in byte 1-7
            # fmt: off
            r = [0x12, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
            # fmt: on

            # store the uniq value in the report
            for id, v in enumerate(self.uniq.split(":")):
                # store in little endian
                r[6 - id] = int(v, 16)

            return (0, r)

        elif rnum == 0x81:
            # Anoter report to retrieve MAC address of DS4.
            # MAC address is stored in byte 1-7
            r = [0x81, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]

            # store the uniq value in the report
            for id, v in enumerate(self.uniq.split(":")):
                # store in little endian
                r[6 - id] = int(v, 16)

            return (0, r)

        elif rnum == 0xA3:
            # Report to retrieve hardware and firmware version.
            # fmt: off
            r = [0xa3, 0x41, 0x70, 0x72, 0x20, 0x20, 0x38, 0x20, 0x32, 0x30, 0x31, 0x34, 0x00, 0x00,
                 0x00, 0x00, 0x00, 0x30, 0x39, 0x3a, 0x34, 0x36, 0x3a, 0x30, 0x36, 0x00, 0x00, 0x00, 0x00,
                 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x43, 0x03, 0x00, 0x00, 0x00, 0x51, 0x00, 0x05,
                 0x00, 0x00, 0x80, 0x03, 0x00]
            # fmt: on
            return (0, r)

        if rdesc is None:
            return (1, [])

        return (1, [])

    def create_report(
        self,
        *,
        left=(None, None),
        right=(None, None),
        hat_switch=None,
        buttons=None,
        touch=None,
        accel=(None, None, None),
        gyro=(None, None, None),
        reportID=None,
    ):
        """
        Return an input report for this device.

        :param left: a tuple of absolute (x, y) value of the left joypad
            where ``None`` is "leave unchanged"
        :param right: a tuple of absolute (x, y) value of the right joypad
            where ``None`` is "leave unchanged"
        :param hat_switch: an absolute angular value of the hat switch
            where ``None`` is "leave unchanged"
        :param buttons: a dict of index/bool for the button states,
            where ``None`` is "leave unchanged"
        :param touch: a list of up to two touch points :class:`PSTouchPoint`,
            where ``None`` is "leave unchanged and '[]' is release all fingers.
        :param accel: a tuple of absolute (x, y, z) values for the accelerometer
            where ``None`` is "leave unchanged"
        :param gyro: a tuple of absolute (x, y, z) values for the gyroscope
            where ``None`` is "leave unchanged"
        :param reportID: the numeric report ID for this report, if needed
        """

        report = super().create_report(
            left=left,
            right=right,
            hat_switch=hat_switch,
            buttons=buttons,
            reportID=reportID,
            application="Game Pad",
        )

        self.store_accelerometer_state(accel)
        self.fill_accelerometer_values(report)

        self.store_gyroscope_state(gyro)
        self.fill_gyroscope_values(report)

        self.fill_battery_values(report)

        if touch:
            self.store_touchpad_state(touch)

        self.fill_touchpad_values(report)
        return report


class PS5TouchReport(PSTouchReport):
    def fill_values(self, last_touch_report, report, offset):
        self._update_contact_ids(last_touch_report)

        for i in self.contact_ids:
            if i is None:
                report[offset] = 0x80  # Mark inactive.
            else:
                p = self.points[i]
                report[offset] = (p.contactid & 0x7F) | (0x0 if p.tipswitch else 0x80)
                report[offset + 1] = p.x & 0xFF
                report[offset + 2] = (p.x >> 8) & 0xF | ((p.y & 0xF) << 4)
                report[offset + 3] = (p.y >> 4) & 0xFF
            offset += 4

        report[offset + 8] = self.timestamp


class PS5Controller(BaseGamepad):
    buttons_map = {
        1: "BTN_WEST",  # square
        2: "BTN_SOUTH",  # cross
        3: "BTN_EAST",  # circle
        4: "BTN_NORTH",  # triangle
        5: "BTN_TL",  # L1
        6: "BTN_TR",  # R1
        7: "BTN_TL2",  # L2
        8: "BTN_TR2",  # R2
        9: "BTN_SELECT",  # create
        10: "BTN_START",  # options
        11: "BTN_THUMBL",  # L3
        12: "BTN_THUMBR",  # R3
        13: "BTN_MODE",  # PS button
    }

    axes_map = {
        "left_stick": {
            "x": AxisMapping("x"),
            "y": AxisMapping("y"),
        },
        "right_stick": {
            "x": AxisMapping("z", "ABS_RX"),
            "y": AxisMapping("Rz", "ABS_RY"),
        },
    }

    # DualSense reports uncalibrated sensor data. Calibration coefficients
    # can be retrieved using feature report 0x09.
    # The values below are the processed calibration values for the
    # DualSene matching the feature reports of PS5ControllerBluetooth/USB
    # as dumped from hid-playstation 'dualsense_get_calibration_data'.
    accelerometer_calibration_data = {
        "x": {"bias": 0, "numer": 16384, "denom": 16374},
        "y": {"bias": -114, "numer": 16384, "denom": 16362},
        "z": {"bias": 2, "numer": 16384, "denom": 16395},
    }
    gyroscope_calibration_data = {
        "x": {"bias": 0, "numer": 1105920, "denom": 17727},
        "y": {"bias": 0, "numer": 1105920, "denom": 17728},
        "z": {"bias": 0, "numer": 1105920, "denom": 17769},
    }

    def __init__(self, rdesc, name, input_info):
        super().__init__(rdesc, name=name, input_info=input_info)
        self.uniq = ":".join([f"{random.randint(0, 0xFF):02x}" for i in range(6)])
        self.buttons = tuple(range(1, 13))
        self.battery = PSBattery()

        if self.bus == BusType.USB:
            self.accelerometer_offset = 22
            self.battery_offset = 53
            self.gyroscope_offset = 16
            self.touchpad_offset = (
                33  # Touchpad section starts at byte 33 for USB-mode.
            )
        elif self.bus == BusType.BLUETOOTH:
            self.accelerometer_offset = 23
            self.battery_offset = 54
            self.gyroscope_offset = 17
            self.touchpad_offset = 34  # Touchpad section starts at byte 34 for BT-mode.

        self.accelerometer = PSSensor(self.accelerometer_calibration_data)
        self.gyroscope = PSSensor(self.gyroscope_calibration_data)

        # Used for book keeping
        self.touch_report = None
        self.last_touch_report = None

    def is_ready(self):
        return (
            super().is_ready()
            and len(self.input_nodes) == 3
            and self.power_supply_class is not None
        )

    def fill_accelerometer_values(self, report):
        """Fill accelerometer section of main input report with raw accelerometer data."""
        offset = self.accelerometer_offset

        report[offset] = self.accelerometer.raw_x & 0xFF
        report[offset + 1] = (self.accelerometer.raw_x >> 8) & 0xFF
        report[offset + 2] = self.accelerometer.raw_y & 0xFF
        report[offset + 3] = (self.accelerometer.raw_y >> 8) & 0xFF
        report[offset + 4] = self.accelerometer.raw_z & 0xFF
        report[offset + 5] = (self.accelerometer.raw_z >> 8) & 0xFF

    def fill_battery_values(self, report):
        """Fill battery section of main input report with battery status."""

        # Battery capacity and charging status is stored in 1 byte.
        # Lower 4-bit contains battery capacity:
        # - 0 to 10 corresponds to 0-100%
        # Highest 4-bit contains charging status:
        # - 0 = discharging
        # - 1 = charging
        # - 2 = charging complete
        # - 10 = charging prohibited (voltage or temperature out of range)
        # - 11 = charging temperature error
        # - 15 = charging error

        if self.battery.full:
            battery_capacity = 10
            charging_status = 2  # charging complete
        else:
            battery_capacity = int(self.battery.capacity / 10) & 0xF
            if self.battery.cable_connected or self.bus == BusType.USB:
                charging_status = 1  # charging
            else:
                charging_status = 0  # discharging

        report[self.battery_offset] = (charging_status << 4) | battery_capacity

    def fill_gyroscope_values(self, report):
        """Fill gyroscope section of main input report with raw gyroscope data."""
        offset = self.gyroscope_offset

        report[offset] = self.gyroscope.raw_x & 0xFF
        report[offset + 1] = (self.gyroscope.raw_x >> 8) & 0xFF
        report[offset + 2] = self.gyroscope.raw_y & 0xFF
        report[offset + 3] = (self.gyroscope.raw_y >> 8) & 0xFF
        report[offset + 4] = self.gyroscope.raw_z & 0xFF
        report[offset + 5] = (self.gyroscope.raw_z >> 8) & 0xFF

    def fill_touchpad_values(self, report):
        """Fill touchpad "sub-report" section of main input report with touch data."""

        # Layout of PS5Touchpad report:
        # 1x TouchReport
        #
        # TouchReport layout
        # +0-3 TouchPoint0
        # +4-7 TouchPoint1
        # +8 timestamp count = 682.7μs
        #
        # TouchPoint layout
        # +0 bit7 active/inactive, bit6:0 touch id
        # +1 lower 8-bit of x-axis
        # +2 7:4 lower 4-bit of y-axis, 3:0 highest 4-bits of x-axis
        # +3 higher 8-bit of y-axis

        offset = self.touchpad_offset  # Byte 0 of touchpad report.

        if self.touch_report:
            self.touch_report.fill_values(self.last_touch_report, report, offset)
            self.last_touch_report = self.touch_report
        else:
            # Inactive touch reports need to have points marked as inactive.
            report[offset] = 0x80
            report[offset + 4] = 0x80

    def store_accelerometer_state(self, accel):
        if accel[0] is not None:
            self.accelerometer.x = accel[0]
        if accel[1] is not None:
            self.accelerometer.y = accel[1]
        if accel[2] is not None:
            self.accelerometer.z = accel[2]

    def store_gyroscope_state(self, gyro):
        if gyro[0] is not None:
            self.gyroscope.x = gyro[0]
        if gyro[1] is not None:
            self.gyroscope.y = gyro[1]
        if gyro[2] is not None:
            self.gyroscope.z = gyro[2]

    def store_touchpad_state(self, touch):
        if touch is None:
            return
        elif touch is not None and len(touch) > 2:
            raise ValueError("More points provided than hardware supports.")
        elif len(touch) == 0:
            self.touch_report = None
            self.last_touch_report = None
        else:
            self.touch_report = PS5TouchReport(touch)

    def get_report(self, req, rnum, rtype):
        rdesc = None
        assert self.parsed_rdesc is not None
        for v in self.parsed_rdesc.feature_reports.values():
            if v.report_ID == rnum:
                rdesc = v

        logger.debug(f"get_report {rdesc}, {req}, {rnum}, {rtype}")

        if rnum == 0x05:  # Calibration info
            # fmt: off
            r = [0x05, 0xff, 0xff, 0xf2, 0xff, 0x04, 0x00, 0x9d, 0x22, 0x5e, 0xdd, 0x92,
                 0x22, 0x52, 0xdd, 0xba, 0x22, 0x51, 0xdd, 0x1c, 0x02, 0x1c, 0x02, 0xfb,
                 0x1f, 0x05, 0xe0, 0x83, 0x1f, 0x99, 0xdf, 0x07, 0x20, 0xfc, 0xdf, 0x05,
                 0x00, 0x00, 0x00, 0x00, 0x00]
            # fmt: on
            return (0, r)

        elif rnum == 0x09:  # Pairing info
            # Report to retrieve MAC address of DualSense.
            # MAC address is stored in byte 1-7
            # fmt: off
            r = [0x09, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
            # fmt: on

            # store the uniq value in the report
            for id, v in enumerate(self.uniq.split(":")):
                # store in little endian
                r[6 - id] = int(v, 16)

            return (0, r)

        elif rnum == 0x20:  # Firmware info
            # fmt: off
            r = [0x20, 0x41, 0x75, 0x67, 0x20, 0x31, 0x38, 0x20, 0x32, 0x30, 0x32, 0x30,
                 0x30, 0x36, 0x3a, 0x32, 0x30, 0x3a, 0x32, 0x39, 0x03, 0x00, 0x04, 0x00,
                 0x13, 0x03, 0x00, 0x00, 0x1e, 0x00, 0x00, 0x01, 0x41, 0x0a, 0x00, 0x00,
                 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x02, 0x00, 0x00,
                 0x2a, 0x00, 0x01, 0x00, 0x06, 0x00, 0x01, 0x00, 0x06, 0x00, 0x00, 0x00,
                 0x98, 0xd8, 0xb3, 0xb7]
            # fmt: on
            return (0, r)

        if rdesc is None:
            return (1, [])

        return (1, [])

    def event(
        self,
        *,
        left=(None, None),
        right=(None, None),
        hat_switch=None,
        buttons=None,
        touch=None,
        accel=(None, None, None),
        gyro=(None, None, None),
    ):
        """
        Send an input event on the default report ID.

        :param left: a tuple of absolute (x, y) value of the left joypad
            where ``None`` is "leave unchanged"
        :param right: a tuple of absolute (x, y) value of the right joypad
            where ``None`` is "leave unchanged"
        :param hat_switch: an absolute angular value of the hat switch
            where ``None`` is "leave unchanged"
        :param buttons: a dict of index/bool for the button states,
            where ``None`` is "leave unchanged"
        :param touch: a list of up to two touch points :class:`PSTouchPoint`,
            where ``None`` is "leave unchanged and '[]' is release all fingers.
        """

        r = self.create_report(
            left=left,
            right=right,
            hat_switch=hat_switch,
            buttons=buttons,
            touch=touch,
            accel=accel,
            gyro=gyro,
        )
        self.call_input_event(r)
        return [r]


class PS5ControllerBluetooth(PS5Controller):
    # fmt: off
    report_descriptor = [
        0x05, 0x01,                    # Usage Page (Generic Desktop)        0
        0x09, 0x05,                    # Usage (Game Pad)                    2
        0xa1, 0x01,                    # Collection (Application)            4
        0x85, 0x01,                    # .Report ID (1)                      6
        0x09, 0x30,                    # .Usage (X)                          8
        0x09, 0x31,                    # .Usage (Y)                          10
        0x09, 0x32,                    # .Usage (Z)                          12
        0x09, 0x35,                    # .Usage (Rz)                         14
        0x15, 0x00,                    # .Logical Minimum (0)                16
        0x26, 0xff, 0x00,              # .Logical Maximum (255)              18
        0x75, 0x08,                    # .Report Size (8)                    21
        0x95, 0x04,                    # .Report Count (4)                   23
        0x81, 0x02,                    # .Input (Data,Var,Abs)               25
        0x09, 0x39,                    # .Usage (Hat switch)                 27
        0x15, 0x00,                    # .Logical Minimum (0)                29
        0x25, 0x07,                    # .Logical Maximum (7)                31
        0x35, 0x00,                    # .Physical Minimum (0)               33
        0x46, 0x3b, 0x01,              # .Physical Maximum (315)             35
        0x65, 0x14,                    # .Unit (Degrees,EngRotation)         38
        0x75, 0x04,                    # .Report Size (4)                    40
        0x95, 0x01,                    # .Report Count (1)                   42
        0x81, 0x42,                    # .Input (Data,Var,Abs,Null)          44
        0x65, 0x00,                    # .Unit (None)                        46
        0x05, 0x09,                    # .Usage Page (Button)                48
        0x19, 0x01,                    # .Usage Minimum (1)                  50
        0x29, 0x0e,                    # .Usage Maximum (14)                 52
        0x15, 0x00,                    # .Logical Minimum (0)                54
        0x25, 0x01,                    # .Logical Maximum (1)                56
        0x75, 0x01,                    # .Report Size (1)                    58
        0x95, 0x0e,                    # .Report Count (14)                  60
        0x81, 0x02,                    # .Input (Data,Var,Abs)               62
        0x75, 0x06,                    # .Report Size (6)                    64
        0x95, 0x01,                    # .Report Count (1)                   66
        0x81, 0x01,                    # .Input (Cnst,Arr,Abs)               68
        0x05, 0x01,                    # .Usage Page (Generic Desktop)       70
        0x09, 0x33,                    # .Usage (Rx)                         72
        0x09, 0x34,                    # .Usage (Ry)                         74
        0x15, 0x00,                    # .Logical Minimum (0)                76
        0x26, 0xff, 0x00,              # .Logical Maximum (255)              78
        0x75, 0x08,                    # .Report Size (8)                    81
        0x95, 0x02,                    # .Report Count (2)                   83
        0x81, 0x02,                    # .Input (Data,Var,Abs)               85
        0x06, 0x00, 0xff,              # .Usage Page (Vendor Defined Page 1) 87
        0x15, 0x00,                    # .Logical Minimum (0)                90
        0x26, 0xff, 0x00,              # .Logical Maximum (255)              92
        0x75, 0x08,                    # .Report Size (8)                    95
        0x95, 0x4d,                    # .Report Count (77)                  97
        0x85, 0x31,                    # .Report ID (49)                     99
        0x09, 0x31,                    # .Usage (Vendor Usage 0x31)          101
        0x91, 0x02,                    # .Output (Data,Var,Abs)              103
        0x09, 0x3b,                    # .Usage (Vendor Usage 0x3b)          105
        0x81, 0x02,                    # .Input (Data,Var,Abs)               107
        0x85, 0x32,                    # .Report ID (50)                     109
        0x09, 0x32,                    # .Usage (Vendor Usage 0x32)          111
        0x95, 0x8d,                    # .Report Count (141)                 113
        0x91, 0x02,                    # .Output (Data,Var,Abs)              115
        0x85, 0x33,                    # .Report ID (51)                     117
        0x09, 0x33,                    # .Usage (Vendor Usage 0x33)          119
        0x95, 0xcd,                    # .Report Count (205)                 121
        0x91, 0x02,                    # .Output (Data,Var,Abs)              123
        0x85, 0x34,                    # .Report ID (52)                     125
        0x09, 0x34,                    # .Usage (Vendor Usage 0x34)          127
        0x96, 0x0d, 0x01,              # .Report Count (269)                 129
        0x91, 0x02,                    # .Output (Data,Var,Abs)              132
        0x85, 0x35,                    # .Report ID (53)                     134
        0x09, 0x35,                    # .Usage (Vendor Usage 0x35)          136
        0x96, 0x4d, 0x01,              # .Report Count (333)                 138
        0x91, 0x02,                    # .Output (Data,Var,Abs)              141
        0x85, 0x36,                    # .Report ID (54)                     143
        0x09, 0x36,                    # .Usage (Vendor Usage 0x36)          145
        0x96, 0x8d, 0x01,              # .Report Count (397)                 147
        0x91, 0x02,                    # .Output (Data,Var,Abs)              150
        0x85, 0x37,                    # .Report ID (55)                     152
        0x09, 0x37,                    # .Usage (Vendor Usage 0x37)          154
        0x96, 0xcd, 0x01,              # .Report Count (461)                 156
        0x91, 0x02,                    # .Output (Data,Var,Abs)              159
        0x85, 0x38,                    # .Report ID (56)                     161
        0x09, 0x38,                    # .Usage (Vendor Usage 0x38)          163
        0x96, 0x0d, 0x02,              # .Report Count (525)                 165
        0x91, 0x02,                    # .Output (Data,Var,Abs)              168
        0x85, 0x39,                    # .Report ID (57)                     170
        0x09, 0x39,                    # .Usage (Vendor Usage 0x39)          172
        0x96, 0x22, 0x02,              # .Report Count (546)                 174
        0x91, 0x02,                    # .Output (Data,Var,Abs)              177
        0x06, 0x80, 0xff,              # .Usage Page (Vendor Usage Page 0xff80) 179
        0x85, 0x05,                    # .Report ID (5)                      182
        0x09, 0x33,                    # .Usage (Vendor Usage 0x33)          184
        0x95, 0x28,                    # .Report Count (40)                  186
        0xb1, 0x02,                    # .Feature (Data,Var,Abs)             188
        0x85, 0x08,                    # .Report ID (8)                      190
        0x09, 0x34,                    # .Usage (Vendor Usage 0x34)          192
        0x95, 0x2f,                    # .Report Count (47)                  194
        0xb1, 0x02,                    # .Feature (Data,Var,Abs)             196
        0x85, 0x09,                    # .Report ID (9)                      198
        0x09, 0x24,                    # .Usage (Vendor Usage 0x24)          200
        0x95, 0x13,                    # .Report Count (19)                  202
        0xb1, 0x02,                    # .Feature (Data,Var,Abs)             204
        0x85, 0x20,                    # .Report ID (32)                     206
        0x09, 0x26,                    # .Usage (Vendor Usage 0x26)          208
        0x95, 0x3f,                    # .Report Count (63)                  210
        0xb1, 0x02,                    # .Feature (Data,Var,Abs)             212
        0x85, 0x22,                    # .Report ID (34)                     214
        0x09, 0x40,                    # .Usage (Vendor Usage 0x40)          216
        0x95, 0x3f,                    # .Report Count (63)                  218
        0xb1, 0x02,                    # .Feature (Data,Var,Abs)             220
        0x85, 0x80,                    # .Report ID (128)                    222
        0x09, 0x28,                    # .Usage (Vendor Usage 0x28)          224
        0x95, 0x3f,                    # .Report Count (63)                  226
        0xb1, 0x02,                    # .Feature (Data,Var,Abs)             228
        0x85, 0x81,                    # .Report ID (129)                    230
        0x09, 0x29,                    # .Usage (Vendor Usage 0x29)          232
        0x95, 0x3f,                    # .Report Count (63)                  234
        0xb1, 0x02,                    # .Feature (Data,Var,Abs)             236
        0x85, 0x82,                    # .Report ID (130)                    238
        0x09, 0x2a,                    # .Usage (Vendor Usage 0x2a)          240
        0x95, 0x09,                    # .Report Count (9)                   242
        0xb1, 0x02,                    # .Feature (Data,Var,Abs)             244
        0x85, 0x83,                    # .Report ID (131)                    246
        0x09, 0x2b,                    # .Usage (Vendor Usage 0x2b)          248
        0x95, 0x3f,                    # .Report Count (63)                  250
        0xb1, 0x02,                    # .Feature (Data,Var,Abs)             252
        0x85, 0xf1,                    # .Report ID (241)                    254
        0x09, 0x31,                    # .Usage (Vendor Usage 0x31)          256
        0x95, 0x3f,                    # .Report Count (63)                  258
        0xb1, 0x02,                    # .Feature (Data,Var,Abs)             260
        0x85, 0xf2,                    # .Report ID (242)                    262
        0x09, 0x32,                    # .Usage (Vendor Usage 0x32)          264
        0x95, 0x0f,                    # .Report Count (15)                  266
        0xb1, 0x02,                    # .Feature (Data,Var,Abs)             268
        0x85, 0xf0,                    # .Report ID (240)                    270
        0x09, 0x30,                    # .Usage (Vendor Usage 0x30)          272
        0x95, 0x3f,                    # .Report Count (63)                  274
        0xb1, 0x02,                    # .Feature (Data,Var,Abs)             276
        0xc0,                          # End Collection                      278
    ]
    # fmt: on

    def __init__(self, rdesc=report_descriptor):
        super().__init__(
            rdesc,
            "Sony Interactive Entertainment Wireless Controller",
            (BusType.BLUETOOTH, 0x054C, 0x0CE6),
        )

    def _sign_report(self, report, seed, count):
        """Helper function to sign DualSense reports with CRC32 at the end of a report."""
        seed = zlib.crc32(bytes([seed]))
        crc = zlib.crc32(bytes(report[0:count]), seed)

        # CRC is stored directly after the payload at the last 4 bytes of a report.
        report[count] = crc & 0xFF
        report[count + 1] = (crc >> 8) & 0xFF
        report[count + 2] = (crc >> 16) & 0xFF
        report[count + 3] = (crc >> 24) & 0xFF

    def create_report(
        self,
        *,
        left=(None, None),
        right=(None, None),
        hat_switch=None,
        buttons=None,
        touch=None,
        accel=(None, None, None),
        gyro=(None, None, None),
        reportID=None,
    ):
        """
        Return an input report for this device.

        :param left: a tuple of absolute (x, y) value of the left joypad
            where ``None`` is "leave unchanged"
        :param right: a tuple of absolute (x, y) value of the right joypad
            where ``None`` is "leave unchanged"
        :param hat_switch: an absolute angular value of the hat switch
            where ``None`` is "leave unchanged"
        :param buttons: a dict of index/bool for the button states,
            where ``None`` is "leave unchanged"
        :param touch: a list of up to two touch points :class:`PSTouchPoint`,
            where ``None`` is "leave unchanged and '[]' is release all fingers.
        :param accel: a tuple of absolute (x, y, z) values for the accelerometer
            where ``None`` is "leave unchanged"
        :param gyro: a tuple of absolute (x, y, z) values for the gyroscope
            where ``None`` is "leave unchanged"
        :param reportID: the numeric report ID for this report, if needed
        """

        report = [0] * 78
        report[0] = 49  # Report ID

        # The full Bluetooth HID report (49) is vendor specific and the HID parser has
        # no clue on how to interpret the data. However it knows how to parse HID report 1,
        # which contains button, hat and stick data. Leverage this report as a base to build
        # the full report.
        base_report = super().create_report(
            left=left,
            right=right,
            hat_switch=hat_switch,
            buttons=buttons,
            reportID=reportID,
            application="Game Pad",
        )

        report[2] = base_report[1]  # X
        report[3] = base_report[2]  # Y
        report[4] = base_report[3]  # RX
        report[5] = base_report[4]  # RY
        report[6] = base_report[8]  # Z
        report[7] = base_report[9]  # RZ
        report[8] = 0  # sequence number between packets, can be kept 0.
        report[9] = base_report[5]  # buttons
        report[10] = base_report[6]  # buttons
        report[11] = base_report[7]  # buttons

        self.store_accelerometer_state(accel)
        self.fill_accelerometer_values(report)

        self.store_gyroscope_state(gyro)
        self.fill_gyroscope_values(report)

        if touch:
            self.store_touchpad_state(touch)

        self.fill_touchpad_values(report)

        self.fill_battery_values(report)

        # CRC is calculated over the first 74 bytes.
        self._sign_report(report, 0xA1, 74)

        return report

    def get_report(self, req, rnum, rtype):
        report = super().get_report(req, rnum, rtype)

        # DualSense feature reports are signed with a CRC at the end of the report.
        if rnum == 0x05:
            self._sign_report(report[1], 0xA3, 37)
        elif rnum == 0x09:
            self._sign_report(report[1], 0xA3, 16)

        return report


class PS5ControllerUSB(PS5Controller):
    # fmt: off
    report_descriptor = [
        0x05, 0x01,                    # Usage Page (Generic Desktop)        0
        0x09, 0x05,                    # Usage (Game Pad)                    2
        0xa1, 0x01,                    # Collection (Application)            4
        0x85, 0x01,                    # .Report ID (1)                      6
        0x09, 0x30,                    # .Usage (X)                          8
        0x09, 0x31,                    # .Usage (Y)                          10
        0x09, 0x32,                    # .Usage (Z)                          12
        0x09, 0x35,                    # .Usage (Rz)                         14
        0x09, 0x33,                    # .Usage (Rx)                         16
        0x09, 0x34,                    # .Usage (Ry)                         18
        0x15, 0x00,                    # .Logical Minimum (0)                20
        0x26, 0xff, 0x00,              # .Logical Maximum (255)              22
        0x75, 0x08,                    # .Report Size (8)                    25
        0x95, 0x06,                    # .Report Count (6)                   27
        0x81, 0x02,                    # .Input (Data,Var,Abs)               29
        0x06, 0x00, 0xff,              # .Usage Page (Vendor Defined Page 1) 31
        0x09, 0x20,                    # .Usage (Vendor Usage 0x20)          34
        0x95, 0x01,                    # .Report Count (1)                   36
        0x81, 0x02,                    # .Input (Data,Var,Abs)               38
        0x05, 0x01,                    # .Usage Page (Generic Desktop)       40
        0x09, 0x39,                    # .Usage (Hat switch)                 42
        0x15, 0x00,                    # .Logical Minimum (0)                44
        0x25, 0x07,                    # .Logical Maximum (7)                46
        0x35, 0x00,                    # .Physical Minimum (0)               48
        0x46, 0x3b, 0x01,              # .Physical Maximum (315)             50
        0x65, 0x14,                    # .Unit (Degrees,EngRotation)         53
        0x75, 0x04,                    # .Report Size (4)                    55
        0x95, 0x01,                    # .Report Count (1)                   57
        0x81, 0x42,                    # .Input (Data,Var,Abs,Null)          59
        0x65, 0x00,                    # .Unit (None)                        61
        0x05, 0x09,                    # .Usage Page (Button)                63
        0x19, 0x01,                    # .Usage Minimum (1)                  65
        0x29, 0x0f,                    # .Usage Maximum (15)                 67
        0x15, 0x00,                    # .Logical Minimum (0)                69
        0x25, 0x01,                    # .Logical Maximum (1)                71
        0x75, 0x01,                    # .Report Size (1)                    73
        0x95, 0x0f,                    # .Report Count (15)                  75
        0x81, 0x02,                    # .Input (Data,Var,Abs)               77
        0x06, 0x00, 0xff,              # .Usage Page (Vendor Defined Page 1) 79
        0x09, 0x21,                    # .Usage (Vendor Usage 0x21)          82
        0x95, 0x0d,                    # .Report Count (13)                  84
        0x81, 0x02,                    # .Input (Data,Var,Abs)               86
        0x06, 0x00, 0xff,              # .Usage Page (Vendor Defined Page 1) 88
        0x09, 0x22,                    # .Usage (Vendor Usage 0x22)          91
        0x15, 0x00,                    # .Logical Minimum (0)                93
        0x26, 0xff, 0x00,              # .Logical Maximum (255)              95
        0x75, 0x08,                    # .Report Size (8)                    98
        0x95, 0x34,                    # .Report Count (52)                  100
        0x81, 0x02,                    # .Input (Data,Var,Abs)               102
        0x85, 0x02,                    # .Report ID (2)                      104
        0x09, 0x23,                    # .Usage (Vendor Usage 0x23)          106
        0x95, 0x2f,                    # .Report Count (47)                  108
        0x91, 0x02,                    # .Output (Data,Var,Abs)              110
        0x85, 0x05,                    # .Report ID (5)                      112
        0x09, 0x23,                    # .Usage (Vendor Usage 0x23)          114
        0x95, 0x28,                    # .Report Count (40)                  116
        0xb1, 0x02,                    # .Feature (Data,Var,Abs)             118
        0x85, 0x08,                    # .Report ID (8)                      120
        0x09, 0x24,                    # .Usage (Vendor Usage 0x24)          122
        0x95, 0x2f,                    # .Report Count (47)                  124
        0xb1, 0x02,                    # .Feature (Data,Var,Abs)             126
        0x85, 0x09,                    # .Report ID (9)                      128
        0x09, 0x24,                    # .Usage (Vendor Usage 0x24)          130
        0x95, 0x13,                    # .Report Count (19)                  132
        0xb1, 0x02,                    # .Feature (Data,Var,Abs)             134
        0x85, 0x0a,                    # .Report ID (10)                     136
        0x09, 0x25,                    # .Usage (Vendor Usage 0x25)          138
        0x95, 0x1a,                    # .Report Count (26)                  140
        0xb1, 0x02,                    # .Feature (Data,Var,Abs)             142
        0x85, 0x20,                    # .Report ID (32)                     144
        0x09, 0x26,                    # .Usage (Vendor Usage 0x26)          146
        0x95, 0x3f,                    # .Report Count (63)                  148
        0xb1, 0x02,                    # .Feature (Data,Var,Abs)             150
        0x85, 0x21,                    # .Report ID (33)                     152
        0x09, 0x27,                    # .Usage (Vendor Usage 0x27)          154
        0x95, 0x04,                    # .Report Count (4)                   156
        0xb1, 0x02,                    # .Feature (Data,Var,Abs)             158
        0x85, 0x22,                    # .Report ID (34)                     160
        0x09, 0x40,                    # .Usage (Vendor Usage 0x40)          162
        0x95, 0x3f,                    # .Report Count (63)                  164
        0xb1, 0x02,                    # .Feature (Data,Var,Abs)             166
        0x85, 0x80,                    # .Report ID (128)                    168
        0x09, 0x28,                    # .Usage (Vendor Usage 0x28)          170
        0x95, 0x3f,                    # .Report Count (63)                  172
        0xb1, 0x02,                    # .Feature (Data,Var,Abs)             174
        0x85, 0x81,                    # .Report ID (129)                    176
        0x09, 0x29,                    # .Usage (Vendor Usage 0x29)          178
        0x95, 0x3f,                    # .Report Count (63)                  180
        0xb1, 0x02,                    # .Feature (Data,Var,Abs)             182
        0x85, 0x82,                    # .Report ID (130)                    184
        0x09, 0x2a,                    # .Usage (Vendor Usage 0x2a)          186
        0x95, 0x09,                    # .Report Count (9)                   188
        0xb1, 0x02,                    # .Feature (Data,Var,Abs)             190
        0x85, 0x83,                    # .Report ID (131)                    192
        0x09, 0x2b,                    # .Usage (Vendor Usage 0x2b)          194
        0x95, 0x3f,                    # .Report Count (63)                  196
        0xb1, 0x02,                    # .Feature (Data,Var,Abs)             198
        0x85, 0x84,                    # .Report ID (132)                    200
        0x09, 0x2c,                    # .Usage (Vendor Usage 0x2c)          202
        0x95, 0x3f,                    # .Report Count (63)                  204
        0xb1, 0x02,                    # .Feature (Data,Var,Abs)             206
        0x85, 0x85,                    # .Report ID (133)                    208
        0x09, 0x2d,                    # .Usage (Vendor Usage 0x2d)          210
        0x95, 0x02,                    # .Report Count (2)                   212
        0xb1, 0x02,                    # .Feature (Data,Var,Abs)             214
        0x85, 0xa0,                    # .Report ID (160)                    216
        0x09, 0x2e,                    # .Usage (Vendor Usage 0x2e)          218
        0x95, 0x01,                    # .Report Count (1)                   220
        0xb1, 0x02,                    # .Feature (Data,Var,Abs)             222
        0x85, 0xe0,                    # .Report ID (224)                    224
        0x09, 0x2f,                    # .Usage (Vendor Usage 0x2f)          226
        0x95, 0x3f,                    # .Report Count (63)                  228
        0xb1, 0x02,                    # .Feature (Data,Var,Abs)             230
        0x85, 0xf0,                    # .Report ID (240)                    232
        0x09, 0x30,                    # .Usage (Vendor Usage 0x30)          234
        0x95, 0x3f,                    # .Report Count (63)                  236
        0xb1, 0x02,                    # .Feature (Data,Var,Abs)             238
        0x85, 0xf1,                    # .Report ID (241)                    240
        0x09, 0x31,                    # .Usage (Vendor Usage 0x31)          242
        0x95, 0x3f,                    # .Report Count (63)                  244
        0xb1, 0x02,                    # .Feature (Data,Var,Abs)             246
        0x85, 0xf2,                    # .Report ID (242)                    248
        0x09, 0x32,                    # .Usage (Vendor Usage 0x32)          250
        0x95, 0x0f,                    # .Report Count (15)                  252
        0xb1, 0x02,                    # .Feature (Data,Var,Abs)             254
        0xc0,                          # End Collection                      256
    ]
    # fmt: on

    def __init__(self, rdesc=report_descriptor):
        super().__init__(
            rdesc,
            "Sony Interactive Entertainment Wireless Controller",
            (BusType.USB, 0x054C, 0x0CE6),
        )

    def create_report(
        self,
        *,
        left=(None, None),
        right=(None, None),
        hat_switch=None,
        buttons=None,
        touch=None,
        accel=(None, None, None),
        gyro=(None, None, None),
        reportID=None,
    ):
        """
        Return an input report for this device.

        :param left: a tuple of absolute (x, y) value of the left joypad
            where ``None`` is "leave unchanged"
        :param right: a tuple of absolute (x, y) value of the right joypad
            where ``None`` is "leave unchanged"
        :param hat_switch: an absolute angular value of the hat switch
            where ``None`` is "leave unchanged"
        :param buttons: a dict of index/bool for the button states,
            where ``None`` is "leave unchanged"
        :param touch: a list of up to two touch points :class:`PSTouchPoint`,
            where ``None`` is "leave unchanged and '[]' is release all fingers.
        :param accel: a tuple of absolute (x, y, z) values for the accelerometer
            where ``None`` is "leave unchanged"
        :param gyro: a tuple of absolute (x, y, z) values for the gyroscope
            where ``None`` is "leave unchanged"
        :param reportID: the numeric report ID for this report, if needed
        """

        report = super().create_report(
            left=left,
            right=right,
            hat_switch=hat_switch,
            buttons=buttons,
            reportID=reportID,
            application="Game Pad",
        )

        self.store_accelerometer_state(accel)
        self.fill_accelerometer_values(report)

        self.store_gyroscope_state(gyro)
        self.fill_gyroscope_values(report)

        if touch:
            self.store_touchpad_state(touch)

        self.fill_touchpad_values(report)

        self.fill_battery_values(report)

        return report
