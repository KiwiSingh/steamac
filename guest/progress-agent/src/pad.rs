//! `fx-progress-agent pad`: root system service (fx-pad.service, started by udev when the
//! launcher's virtio-console port `fx.pad` appears) that owns the guest's gamepad as a uinput
//! device. The launcher reads the Mac's controller (GameController) and drives this device; the
//! device's force feedback (FF_RUMBLE, what SDL and Steam use for rumble) goes back to the
//! launcher, which plays it on the controller. Unlike a virtio-input device, the pad can come and
//! go and change its identity while the VM runs.
//!
//! Protocol on fx.pad, one message per line:
//!   host -> guest  `create <bus> <vendor> <product> <version> <keys> <axes> <name>`
//!                    ids as 4-digit hex; keys `code,code,...`; axes `code:min:max:fuzz:flat,...`;
//!                    the name is the rest of the line. Replaces the current pad, if any.
//!                  `remove`
//!                  `ev <type>:<code>:<value> ...`   one input frame (EV_KEY / EV_ABS), then SYN_REPORT
//!   guest -> host  `hello`                    at start: no pad exists; the host sends `create` again
//!                  `rumble <strong> <weak>`   the pad's combined rumble, 0..65535 each, on every change
//!
//! uinput leaves force-feedback playback to its user-space driver: uploads and erases arrive as
//! EV_UINPUT requests on the device fd, plays and stops as EV_FF events. `Rumble` implements the
//! kernel's ff-memless semantics for FF_RUMBLE (start after replay.delay, stop after
//! replay.length, 0 = until stopped, `value` repetitions, re-uploading a playing effect restarts
//! it, concurrent effects add up and saturate) on a millisecond clock, testable without a device.
//!
//! Environment overrides (testing): FX_PAD_PORT=<path>, FX_PAD_UINPUT=<path>.

use std::collections::BTreeMap;
use std::ffi::CString;
use std::io;
use std::mem::size_of;
use std::time::Instant;

use crate::port::Port;

const DEFAULT_PORT: &str = "/dev/virtio-ports/fx.pad";
const DEFAULT_UINPUT: &str = "/dev/uinput";
const DEFAULT_UHID: &str = "/dev/uhid";

// Private fx.pad transport code. This is not exposed as a Linux key by the
// DualSense backend; it becomes the physical touchpad-click bit in report 0x01.
const BTN_SOUTH: u16 = 0x130;
const BTN_EAST: u16 = 0x131;
const BTN_NORTH: u16 = 0x133;
const BTN_WEST: u16 = 0x134;
const BTN_TL: u16 = 0x136;
const BTN_TR: u16 = 0x137;
const BTN_TL2: u16 = 0x138;
const BTN_TR2: u16 = 0x139;
const BTN_SELECT: u16 = 0x13a;
const BTN_START: u16 = 0x13b;
const BTN_MODE: u16 = 0x13c;
const BTN_THUMBL: u16 = 0x13d;
const BTN_THUMBR: u16 = 0x13e;

// Private fx.pad transport code; not a Linux input-event button code.
const SONY_TOUCHPAD_CLICK: u16 = 0x2c0;

const SONY_VENDOR: u16 = 0x054c;
const DUALSENSE_PRODUCT: u16 = 0x0ce6;
const DUALSENSE_EDGE_PRODUCT: u16 = 0x0df2;
const DUALSHOCK4_PRODUCT: u16 = 0x09cc;

// linux/uhid.h
const UHID_DESTROY: u32 = 1;
const UHID_OUTPUT: u32 = 6;
const UHID_GET_REPORT: u32 = 9;
const UHID_GET_REPORT_REPLY: u32 = 10;
const UHID_CREATE2: u32 = 11;
const UHID_INPUT2: u32 = 12;
const UHID_SET_REPORT: u32 = 13;
const UHID_SET_REPORT_REPLY: u32 = 14;

const EV_SYN: u16 = 0x00;
const EV_KEY: u16 = 0x01;
const EV_ABS: u16 = 0x03;
const EV_FF: u16 = 0x15;
const EV_UINPUT: u16 = 0x0101;
const SYN_REPORT: u16 = 0;
const UI_FF_UPLOAD: u16 = 1;
const UI_FF_ERASE: u16 = 2;
const FF_RUMBLE: u16 = 0x50;
const KEY_MAX: u16 = 0x2ff;
const ABS_MAX: u16 = 0x3f;
/// Effect slots per pad (ids 0..15); EV_FF codes at or above it are FF_GAIN and the like.
const FF_EFFECTS_MAX: u16 = 16;

// <asm-generic/ioctl.h>: dir << 30 | size << 16 | type << 8 | nr; <linux/uinput.h> numbers.
const fn ioc(dir: u32, nr: u32, size: usize) -> u32 {
    (dir << 30) | ((size as u32) << 16) | ((b'U' as u32) << 8) | nr
}
const W: u32 = 1;
const R: u32 = 2;
const UI_DEV_CREATE: u32 = ioc(0, 1, 0);
const UI_DEV_DESTROY: u32 = ioc(0, 2, 0);
const UI_DEV_SETUP: u32 = ioc(W, 3, size_of::<libc::uinput_setup>());
const UI_ABS_SETUP: u32 = ioc(W, 4, size_of::<libc::uinput_abs_setup>());
const UI_SET_EVBIT: u32 = ioc(W, 100, size_of::<libc::c_int>());
const UI_SET_KEYBIT: u32 = ioc(W, 101, size_of::<libc::c_int>());
const UI_SET_ABSBIT: u32 = ioc(W, 103, size_of::<libc::c_int>());
const UI_SET_FFBIT: u32 = ioc(W, 107, size_of::<libc::c_int>());
const UI_BEGIN_FF_UPLOAD: u32 = ioc(R | W, 200, size_of::<libc::uinput_ff_upload>());
const UI_END_FF_UPLOAD: u32 = ioc(W, 201, size_of::<libc::uinput_ff_upload>());
const UI_BEGIN_FF_ERASE: u32 = ioc(R | W, 202, size_of::<libc::uinput_ff_erase>());
const UI_END_FF_ERASE: u32 = ioc(W, 203, size_of::<libc::uinput_ff_erase>());

// MARK: protocol

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Axis {
    pub code: u16,
    pub min: i32,
    pub max: i32,
    pub fuzz: i32,
    pub flat: i32,
}

/// What `create` asks for: the identity and capabilities of the real controller's kernel driver.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Spec {
    pub bus: u16,
    pub vendor: u16,
    pub product: u16,
    pub version: u16,
    pub keys: Vec<u16>,
    pub axes: Vec<Axis>,
    pub name: String,
}

#[derive(Debug, PartialEq, Eq)]
pub enum Command {
    Create(Spec),
    Remove,
    Frame(Vec<(u16, u16, i32)>),
    Battery(u8, BatteryState),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BatteryState {
    Unknown,
    Discharging,
    Charging,
    Full,
}

/// One host line; None for anything malformed.
pub fn parse(line: &str) -> Option<Command> {
    let line = line.trim_end_matches(['\r', '\n']);
    let (verb, rest) = line.split_once(' ').unwrap_or((line, ""));
    match verb {
        "remove" if rest.trim().is_empty() => Some(Command::Remove),
        "battery" => {
            let mut f = rest.split_whitespace();
            let percent = f.next()?.parse::<u8>().ok().filter(|&v| v <= 100)?;
            let state = match f.next()? {
                "discharging" => BatteryState::Discharging,
                "charging" => BatteryState::Charging,
                "full" => BatteryState::Full,
                "unknown" => BatteryState::Unknown,
                _ => return None,
            };
            if f.next().is_some() {
                return None;
            }
            Some(Command::Battery(percent, state))
        }
        "ev" => {
            let mut events = Vec::new();
            for e in rest.split_whitespace() {
                let mut f = e.split(':');
                let (t, c, v) = (f.next()?.parse().ok()?, f.next()?.parse().ok()?, f.next()?.parse().ok()?);
                if f.next().is_some() || !matches!(t, EV_KEY | EV_ABS) {
                    return None;
                }
                events.push((t, c, v));
            }
            (!events.is_empty()).then_some(Command::Frame(events))
        }
        "create" => {
            let f: Vec<&str> = rest.splitn(7, ' ').collect();
            if f.len() != 7 {
                return None;
            }
            let hex = |s: &str| u16::from_str_radix(s, 16).ok();
            let keys = if f[4] == "-" {
                Vec::new()
            } else {
                f[4].split(',').map(|k| k.parse().ok().filter(|&k: &u16| k <= KEY_MAX)).collect::<Option<Vec<u16>>>()?
            };
            let axes = if f[5] == "-" {
                Vec::new()
            } else {
                f[5].split(',')
                    .map(|a| {
                        let v: Vec<&str> = a.split(':').collect();
                        let n = |i: usize| v.get(i).and_then(|s| s.parse::<i32>().ok());
                        let code = v.first()?.parse::<u16>().ok().filter(|&c| c <= ABS_MAX)?;
                        (v.len() == 5).then_some(())?;
                        Some(Axis { code, min: n(1)?, max: n(2)?, fuzz: n(3)?, flat: n(4)? })
                    })
                    .collect::<Option<Vec<Axis>>>()?
            };
            let name = f[6].trim();
            if name.is_empty() || (keys.is_empty() && axes.is_empty()) {
                return None;
            }
            Some(Command::Create(Spec {
                bus: hex(f[0])?,
                vendor: hex(f[1])?,
                product: hex(f[2])?,
                version: hex(f[3])?,
                keys,
                axes,
                name: name.to_string(),
            }))
        }
        _ => None,
    }
}

// MARK: force feedback

/// An uploaded FF_RUMBLE effect.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Effect {
    pub strong: u16,
    pub weak: u16,
    /// ms; 0 = until stopped.
    pub length: u16,
    /// ms before each play.
    pub delay: u16,
}

#[derive(Clone, Copy, Debug)]
struct Play {
    /// When the current play's rumble starts (ms).
    start: u64,
    /// Plays left, this one included.
    left: i32,
}

struct Slot {
    effect: Effect,
    play: Option<Play>,
}

/// Playback of the pad's FF_RUMBLE effects (ff-memless semantics, see the module doc).
#[derive(Default)]
pub struct Rumble {
    slots: BTreeMap<i16, Slot>,
}

impl Rumble {
    /// New or updated effect `id`; a playing effect restarts with the new parameters.
    pub fn upload(&mut self, id: i16, effect: Effect, now: u64) {
        let play = self.slots.get(&id).and_then(|s| s.play).map(|p| Play { start: now + effect.delay as u64, left: p.left });
        self.slots.insert(id, Slot { effect, play });
    }

    /// EV_FF `id` with `count`: play it that many times (0 = stop).
    pub fn play(&mut self, id: i16, count: i32, now: u64) {
        if let Some(s) = self.slots.get_mut(&id) {
            s.play = (count > 0).then(|| Play { start: now + s.effect.delay as u64, left: count });
        }
    }

    pub fn erase(&mut self, id: i16) {
        self.slots.remove(&id);
    }

    /// Finish plays that ended by `now`, starting the next repetition (after its delay).
    fn advance(&mut self, now: u64) {
        for s in self.slots.values_mut() {
            while let Some(p) = s.play {
                if s.effect.length == 0 {
                    break;
                }
                let end = p.start + s.effect.length as u64;
                if now < end {
                    break;
                }
                s.play = (p.left > 1).then(|| Play { start: end + s.effect.delay as u64, left: p.left - 1 });
            }
        }
    }

    /// Combined (strong, weak) at `now`: the sum of all effects in their rumble phase, saturated.
    pub fn level(&mut self, now: u64) -> (u16, u16) {
        self.advance(now);
        let (mut strong, mut weak) = (0u32, 0u32);
        for s in self.slots.values() {
            if s.play.is_some_and(|p| p.start <= now) {
                strong += s.effect.strong as u32;
                weak += s.effect.weak as u32;
            }
        }
        (strong.min(0xffff) as u16, weak.min(0xffff) as u16)
    }

    /// When `level` can change next without new requests (a play starting or ending).
    pub fn next_change(&mut self, now: u64) -> Option<u64> {
        self.advance(now);
        self.slots
            .values()
            .filter_map(|s| {
                let p = s.play?;
                if now < p.start {
                    Some(p.start)
                } else {
                    (s.effect.length > 0).then(|| p.start + s.effect.length as u64)
                }
            })
            .min()
    }
}

// MARK: uinput

fn ioctl<T>(fd: libc::c_int, request: u32, arg: *mut T) -> io::Result<()> {
    if unsafe { libc::ioctl(fd, request as libc::Ioctl, arg) } < 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(())
    }
}

fn ioctl_int(fd: libc::c_int, request: u32, value: u16) -> io::Result<()> {
    if unsafe { libc::ioctl(fd, request as libc::Ioctl, value as libc::c_int) } < 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(())
    }
}

/// The uinput device; destroyed on drop (closing the fd would do it too).
struct Device {
    fd: libc::c_int,
}

impl Device {
    fn create(path: &str, spec: &Spec) -> io::Result<Device> {
        let c = CString::new(path).map_err(|_| io::Error::from(io::ErrorKind::InvalidInput))?;
        let fd = unsafe { libc::open(c.as_ptr(), libc::O_RDWR | libc::O_NONBLOCK | libc::O_CLOEXEC) };
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        let d = Device { fd };
        if !spec.keys.is_empty() {
            ioctl_int(fd, UI_SET_EVBIT, EV_KEY)?;
            for &k in &spec.keys {
                ioctl_int(fd, UI_SET_KEYBIT, k)?;
            }
        }
        if !spec.axes.is_empty() {
            ioctl_int(fd, UI_SET_EVBIT, EV_ABS)?;
            for a in &spec.axes {
                ioctl_int(fd, UI_SET_ABSBIT, a.code)?;
                let mut s: libc::uinput_abs_setup = unsafe { std::mem::zeroed() };
                s.code = a.code;
                s.absinfo.minimum = a.min;
                s.absinfo.maximum = a.max;
                s.absinfo.fuzz = a.fuzz;
                s.absinfo.flat = a.flat;
                ioctl(fd, UI_ABS_SETUP, &mut s)?;
            }
        }
        ioctl_int(fd, UI_SET_EVBIT, EV_FF)?;
        ioctl_int(fd, UI_SET_FFBIT, FF_RUMBLE)?;
        let mut setup: libc::uinput_setup = unsafe { std::mem::zeroed() };
        setup.id.bustype = spec.bus;
        setup.id.vendor = spec.vendor;
        setup.id.product = spec.product;
        setup.id.version = spec.version;
        for (dst, &b) in setup.name.iter_mut().zip(spec.name.as_bytes().iter().take(libc::UINPUT_MAX_NAME_SIZE - 1)) {
            *dst = b as libc::c_char;
        }
        setup.ff_effects_max = FF_EFFECTS_MAX as u32;
        ioctl(fd, UI_DEV_SETUP, &mut setup)?;
        ioctl::<libc::c_void>(fd, UI_DEV_CREATE, std::ptr::null_mut())?;
        Ok(d)
    }

    /// The events and a SYN_REPORT in one write (the kernel takes whole input_event structs).
    fn write_frame(&self, events: &[(u16, u16, i32)]) -> io::Result<()> {
        let mut buf: Vec<libc::input_event> = Vec::with_capacity(events.len() + 1);
        for &(t, c, v) in events.iter().chain(std::iter::once(&(EV_SYN, SYN_REPORT, 0))) {
            let mut e: libc::input_event = unsafe { std::mem::zeroed() };
            e.type_ = t;
            e.code = c;
            e.value = v;
            buf.push(e);
        }
        let bytes = buf.len() * size_of::<libc::input_event>();
        let n = unsafe { libc::write(self.fd, buf.as_ptr() as *const libc::c_void, bytes) };
        if n < 0 {
            Err(io::Error::last_os_error())
        } else {
            Ok(())
        }
    }

    /// Pending requests and FF events; never blocks.
    fn read_events(&self) -> Vec<libc::input_event> {
        let mut out = Vec::new();
        loop {
            let mut e: libc::input_event = unsafe { std::mem::zeroed() };
            let n = unsafe { libc::read(self.fd, &mut e as *mut _ as *mut libc::c_void, size_of::<libc::input_event>()) };
            if n == size_of::<libc::input_event>() as isize {
                out.push(e);
            } else if n < 0 && io::Error::last_os_error().kind() == io::ErrorKind::Interrupted {
                continue;
            } else {
                return out;
            }
        }
    }

    /// Answer an EV_UINPUT request; the kernel's EVIOCSFF / EVIOCRMFF caller waits for it.
    fn serve(&self, code: u16, request_id: u32, rumble: &mut Rumble, now: u64) -> io::Result<()> {
        match code {
            UI_FF_UPLOAD => {
                let mut up: libc::uinput_ff_upload = unsafe { std::mem::zeroed() };
                up.request_id = request_id;
                ioctl(self.fd, UI_BEGIN_FF_UPLOAD, &mut up)?;
                let e = &up.effect;
                up.retval = if e.type_ == FF_RUMBLE {
                    // ff_effect.u is a union; ff_rumble_effect is its first two u16s.
                    let b = e.u[0].to_ne_bytes();
                    let effect = Effect {
                        strong: u16::from_ne_bytes([b[0], b[1]]),
                        weak: u16::from_ne_bytes([b[2], b[3]]),
                        length: e.replay.length,
                        delay: e.replay.delay,
                    };
                    rumble.upload(e.id, effect, now);
                    0
                } else {
                    -libc::EINVAL
                };
                ioctl(self.fd, UI_END_FF_UPLOAD, &mut up)
            }
            UI_FF_ERASE => {
                let mut er: libc::uinput_ff_erase = unsafe { std::mem::zeroed() };
                er.request_id = request_id;
                ioctl(self.fd, UI_BEGIN_FF_ERASE, &mut er)?;
                rumble.erase(er.effect_id as i16);
                er.retval = 0;
                ioctl(self.fd, UI_END_FF_ERASE, &mut er)
            }
            _ => Ok(()),
        }
    }
}

impl Drop for Device {
    fn drop(&mut self) {
        let _ = ioctl::<libc::c_void>(self.fd, UI_DEV_DESTROY, std::ptr::null_mut());
        unsafe { libc::close(self.fd) };
    }
}


// MARK: DualSense UHID

// USB DualShock 4 descriptor from hidtools PS4ControllerUSB.
const DUALSHOCK4_RDESC: &[u8] = &[
    0x05, 0x01, 0x09, 0x05, 0xa1, 0x01, 0x85, 0x01, 0x09, 0x30, 0x09, 0x31,
    0x09, 0x32, 0x09, 0x35, 0x15, 0x00, 0x26, 0xff, 0x00, 0x75, 0x08, 0x95,
    0x04, 0x81, 0x02, 0x09, 0x39, 0x15, 0x00, 0x25, 0x07, 0x35, 0x00, 0x46,
    0x3b, 0x01, 0x65, 0x14, 0x75, 0x04, 0x95, 0x01, 0x81, 0x42, 0x65, 0x00,
    0x05, 0x09, 0x19, 0x01, 0x29, 0x0e, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01,
    0x95, 0x0e, 0x81, 0x02, 0x06, 0x00, 0xff, 0x09, 0x20, 0x75, 0x06, 0x95,
    0x01, 0x15, 0x00, 0x25, 0x7f, 0x81, 0x02, 0x05, 0x01, 0x09, 0x33, 0x09,
    0x34, 0x15, 0x00, 0x26, 0xff, 0x00, 0x75, 0x08, 0x95, 0x02, 0x81, 0x02,
    0x06, 0x00, 0xff, 0x09, 0x21, 0x95, 0x36, 0x81, 0x02, 0x85, 0x05, 0x09,
    0x22, 0x95, 0x1f, 0x91, 0x02, 0x85, 0x04, 0x09, 0x23, 0x95, 0x24, 0xb1,
    0x02, 0x85, 0x02, 0x09, 0x24, 0x95, 0x24, 0xb1, 0x02, 0x85, 0x08, 0x09,
    0x25, 0x95, 0x03, 0xb1, 0x02, 0x85, 0x10, 0x09, 0x26, 0x95, 0x04, 0xb1,
    0x02, 0x85, 0x11, 0x09, 0x27, 0x95, 0x02, 0xb1, 0x02, 0x85, 0x12, 0x06,
    0x02, 0xff, 0x09, 0x21, 0x95, 0x0f, 0xb1, 0x02, 0x85, 0x13, 0x09, 0x22,
    0x95, 0x16, 0xb1, 0x02, 0x85, 0x14, 0x06, 0x05, 0xff, 0x09, 0x20, 0x95,
    0x10, 0xb1, 0x02, 0x85, 0x15, 0x09, 0x21, 0x95, 0x2c, 0xb1, 0x02, 0x06,
    0x80, 0xff, 0x85, 0x80, 0x09, 0x20, 0x95, 0x06, 0xb1, 0x02, 0x85, 0x81,
    0x09, 0x21, 0x95, 0x06, 0xb1, 0x02, 0x85, 0x82, 0x09, 0x22, 0x95, 0x05,
    0xb1, 0x02, 0x85, 0x83, 0x09, 0x23, 0x95, 0x01, 0xb1, 0x02, 0x85, 0x84,
    0x09, 0x24, 0x95, 0x04, 0xb1, 0x02, 0x85, 0x85, 0x09, 0x25, 0x95, 0x06,
    0xb1, 0x02, 0x85, 0x86, 0x09, 0x26, 0x95, 0x06, 0xb1, 0x02, 0x85, 0x87,
    0x09, 0x27, 0x95, 0x23, 0xb1, 0x02, 0x85, 0x88, 0x09, 0x28, 0x95, 0x3f,
    0xb1, 0x02, 0x85, 0x89, 0x09, 0x29, 0x95, 0x02, 0xb1, 0x02, 0x85, 0x90,
    0x09, 0x30, 0x95, 0x05, 0xb1, 0x02, 0x85, 0x91, 0x09, 0x31, 0x95, 0x03,
    0xb1, 0x02, 0x85, 0x92, 0x09, 0x32, 0x95, 0x03, 0xb1, 0x02, 0x85, 0x93,
    0x09, 0x33, 0x95, 0x0c, 0xb1, 0x02, 0x85, 0x94, 0x09, 0x34, 0x95, 0x3f,
    0xb1, 0x02, 0x85, 0xa0, 0x09, 0x40, 0x95, 0x06, 0xb1, 0x02, 0x85, 0xa1,
    0x09, 0x41, 0x95, 0x01, 0xb1, 0x02, 0x85, 0xa2, 0x09, 0x42, 0x95, 0x01,
    0xb1, 0x02, 0x85, 0xa3, 0x09, 0x43, 0x95, 0x30, 0xb1, 0x02, 0x85, 0xa4,
    0x09, 0x44, 0x95, 0x0d, 0xb1, 0x02, 0x85, 0xf0, 0x09, 0x47, 0x95, 0x3f,
    0xb1, 0x02, 0x85, 0xf1, 0x09, 0x48, 0x95, 0x3f, 0xb1, 0x02, 0x85, 0xf2,
    0x09, 0x49, 0x95, 0x0f, 0xb1, 0x02, 0x85, 0xa7, 0x09, 0x4a, 0x95, 0x01,
    0xb1, 0x02, 0x85, 0xa8, 0x09, 0x4b, 0x95, 0x01, 0xb1, 0x02, 0x85, 0xa9,
    0x09, 0x4c, 0x95, 0x08, 0xb1, 0x02, 0x85, 0xaa, 0x09, 0x4e, 0x95, 0x01,
    0xb1, 0x02, 0x85, 0xab, 0x09, 0x4f, 0x95, 0x39, 0xb1, 0x02, 0x85, 0xac,
    0x09, 0x50, 0x95, 0x39, 0xb1, 0x02, 0x85, 0xad, 0x09, 0x51, 0x95, 0x0b,
    0xb1, 0x02, 0x85, 0xae, 0x09, 0x52, 0x95, 0x01, 0xb1, 0x02, 0x85, 0xaf,
    0x09, 0x53, 0x95, 0x02, 0xb1, 0x02, 0x85, 0xb0, 0x09, 0x54, 0x95, 0x3f,
    0xb1, 0x02, 0x85, 0xe0, 0x09, 0x57, 0x95, 0x02, 0xb1, 0x02, 0x85, 0xb3,
    0x09, 0x55, 0x95, 0x3f, 0xb1, 0x02, 0x85, 0xb4, 0x09, 0x55, 0x95, 0x3f,
    0xb1, 0x02, 0x85, 0xb5, 0x09, 0x56, 0x95, 0x3f, 0xb1, 0x02, 0x85, 0xd0,
    0x09, 0x58, 0x95, 0x3f, 0xb1, 0x02, 0x85, 0xd4, 0x09, 0x59, 0x95, 0x3f,
    0xb1, 0x02, 0xc0,
];

// USB DualSense descriptor used by the working FrankenSense prototype.
// Keeping the real Sony descriptor lets hid-playstation create its normal
// gamepad + touchpad input topology instead of synthesising another uinput pad.
const DUALSENSE_RDESC: &[u8] = &[
    0x05,0x01,0x09,0x05,0xa1,0x01,0x85,0x01,
    0x09,0x30,0x09,0x31,0x09,0x32,0x09,0x35,0x09,0x33,0x09,0x34,
    0x15,0x00,0x26,0xff,0x00,0x75,0x08,0x95,0x06,0x81,0x02,
    0x06,0x00,0xff,0x09,0x20,0x95,0x01,0x81,0x02,
    0x05,0x01,0x09,0x39,0x15,0x00,0x25,0x07,0x35,0x00,
    0x46,0x3b,0x01,0x65,0x14,0x75,0x04,0x95,0x01,0x81,0x42,
    0x65,0x00,0x05,0x09,0x19,0x01,0x29,0x0f,0x15,0x00,0x25,0x01,
    0x75,0x01,0x95,0x0f,0x81,0x02,
    0x06,0x00,0xff,0x09,0x21,0x95,0x0d,0x81,0x02,
    0x06,0x00,0xff,0x09,0x22,0x15,0x00,0x26,0xff,0x00,
    0x75,0x08,0x95,0x34,0x81,0x02,
    0x85,0x02,0x09,0x23,0x95,0x2f,0x91,0x02,
    0x85,0x05,0x09,0x23,0x95,0x28,0xb1,0x02,
    0x85,0x08,0x09,0x24,0x95,0x2f,0xb1,0x02,
    0x85,0x09,0x09,0x24,0x95,0x13,0xb1,0x02,
    0x85,0x0a,0x09,0x25,0x95,0x1a,0xb1,0x02,
    0x85,0x20,0x09,0x26,0x95,0x3f,0xb1,0x02,
    0x85,0x21,0x09,0x27,0x95,0x04,0xb1,0x02,
    0x85,0x22,0x09,0x40,0x95,0x3f,0xb1,0x02,
    0x85,0x80,0x09,0x28,0x95,0x3f,0xb1,0x02,
    0x85,0x81,0x09,0x29,0x95,0x3f,0xb1,0x02,
    0x85,0x82,0x09,0x2a,0x95,0x09,0xb1,0x02,
    0x85,0x83,0x09,0x2b,0x95,0x3f,0xb1,0x02,
    0x85,0x84,0x09,0x2c,0x95,0x3f,0xb1,0x02,
    0x85,0x85,0x09,0x2d,0x95,0x02,0xb1,0x02,
    0x85,0xa0,0x09,0x2e,0x95,0x01,0xb1,0x02,
    0x85,0xe0,0x09,0x2f,0x95,0x3f,0xb1,0x02,
    0x85,0xf0,0x09,0x30,0x95,0x3f,0xb1,0x02,
    0x85,0xf1,0x09,0x31,0x95,0x3f,0xb1,0x02,
    0x85,0xf2,0x09,0x32,0x95,0x0f,0xb1,0x02,
    0xc0,
];

#[derive(Default)]
struct DualSenseState {
    buttons: BTreeMap<u16, bool>,
    axes: BTreeMap<u16, i32>,
    battery_percent: Option<u8>,
    battery_state: Option<BatteryState>,
}

struct DualSense {
    fd: libc::c_int,
    product: u16,
    state: DualSenseState,
}

impl DualSense {
    fn create(path: &str, product: u16) -> io::Result<Self> {
        let c = CString::new(path)
            .map_err(|_| io::Error::from(io::ErrorKind::InvalidInput))?;
        let fd = unsafe {
            libc::open(c.as_ptr(), libc::O_RDWR | libc::O_NONBLOCK | libc::O_CLOEXEC)
        };
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }

        let d = DualSense {
            fd,
            product,
            state: DualSenseState::default(),
        };

        if let Err(e) = d.create_kernel_device() {
            unsafe { libc::close(fd) };
            return Err(e);
        }

        Ok(d)
    }

    fn write_all(&self, data: &[u8]) -> io::Result<()> {
        let n = unsafe {
            libc::write(
                self.fd,
                data.as_ptr() as *const libc::c_void,
                data.len(),
            )
        };
        if n < 0 {
            Err(io::Error::last_os_error())
        } else if n as usize != data.len() {
            Err(io::Error::new(io::ErrorKind::WriteZero, "short UHID write"))
        } else {
            Ok(())
        }
    }

    fn create_kernel_device(&self) -> io::Result<()> {
        // struct uhid_create2_req:
        // name[128], phys[64], uniq[64], rd_size, bus, vendor, product,
        // version, country, rd_data[4096].
        let mut b = vec![0u8; 4 + 128 + 64 + 64 + 2 + 2 + 4 * 4 + 4096];

        b[0..4].copy_from_slice(&UHID_CREATE2.to_ne_bytes());

        let name = b"Sony Interactive Entertainment Wireless Controller";
        b[4..4 + name.len()].copy_from_slice(name);

        let rd_size_off = 4 + 128 + 64 + 64;
        b[rd_size_off..rd_size_off + 2]
            .copy_from_slice(&(DUALSENSE_RDESC.len() as u16).to_ne_bytes());

        // BUS_USB = 0x03
        b[rd_size_off + 2..rd_size_off + 4].copy_from_slice(&3u16.to_ne_bytes());
        b[rd_size_off + 4..rd_size_off + 8]
            .copy_from_slice(&(SONY_VENDOR as u32).to_ne_bytes());
        b[rd_size_off + 8..rd_size_off + 12]
            .copy_from_slice(&(self.product as u32).to_ne_bytes());

        let rd_off = rd_size_off + 2 + 2 + 4 * 4;
        b[rd_off..rd_off + DUALSENSE_RDESC.len()].copy_from_slice(DUALSENSE_RDESC);

        self.write_all(&b)
    }

    fn stick8(v: i32) -> u8 {
        let v = v.clamp(-32767, 32767) as i64;
        (((v + 32767) * 255 + 32767) / 65534).clamp(0, 255) as u8
    }

    fn trigger8(v: i32) -> u8 {
        v.clamp(0, 255) as u8
    }

    fn hat(x: i32, y: i32) -> u8 {
        match (x, y) {
            (0, -1) => 0,
            (1, -1) => 1,
            (1, 0) => 2,
            (1, 1) => 3,
            (0, 1) => 4,
            (-1, 1) => 5,
            (-1, 0) => 6,
            (-1, -1) => 7,
            _ => 15,
        }
    }

    fn pressed(&self, code: u16) -> bool {
        self.state.buttons.get(&code).copied().unwrap_or(false)
    }

    fn axis(&self, code: u16) -> i32 {
        self.state.axes.get(&code).copied().unwrap_or(0)
    }

    fn write_frame(&mut self, events: &[(u16, u16, i32)]) -> io::Result<()> {
        for &(t, c, v) in events {
            match t {
                EV_KEY => {
                    self.state.buttons.insert(c, v != 0);
                }
                EV_ABS => {
                    self.state.axes.insert(c, v);
                }
                _ => {}
            }
        }

        self.send_report()
    }

    fn send_report(&self) -> io::Result<()> {
        // DualSense USB input report 0x01 is 64 bytes.
        let mut r = [0u8; 64];
        r[0] = 0x01;

        // DualSense report order: LX, LY, RX, RY, L2, R2.
        // fx.pad transports Linux ABS_X/Y for the left stick,
        // ABS_RX/RY for the right stick, and ABS_Z/RZ for L2/R2.
        r[1] = Self::stick8(self.axis(0x00));   // LX / ABS_X
        r[2] = Self::stick8(self.axis(0x01));   // LY / ABS_Y
        r[3] = Self::stick8(self.axis(0x03));   // RX / ABS_RX
        r[4] = Self::stick8(self.axis(0x04));   // RY / ABS_RY
        r[5] = Self::trigger8(self.axis(0x02)); // L2 / ABS_Z
        r[6] = Self::trigger8(self.axis(0x05)); // R2 / ABS_RZ

        // Byte 8: low nibble = hat, high nibble = Square/Cross/Circle/Triangle.
        // Linux BTN_* positions are SOUTH=Cross, EAST=Circle,
        // NORTH=Triangle, WEST=Square.
        let mut b8 = Self::hat(self.axis(0x10), self.axis(0x11));
        if self.pressed(BTN_WEST) { b8 |= 1 << 4; } // Square / BTN_WEST
        if self.pressed(BTN_SOUTH) { b8 |= 1 << 5; } // Cross  / BTN_SOUTH
        if self.pressed(BTN_EAST) { b8 |= 1 << 6; } // Circle / BTN_EAST
        if self.pressed(BTN_NORTH) { b8 |= 1 << 7; } // Triangle / BTN_NORTH
        r[8] = b8;

        // Byte 9: L1/R1/L2/R2/Create/Options/L3/R3.
        if self.pressed(BTN_TL) { r[9] |= 1 << 0; }
        if self.pressed(BTN_TR) { r[9] |= 1 << 1; }
        if self.pressed(BTN_TL2) { r[9] |= 1 << 2; }
        if self.pressed(BTN_TR2) { r[9] |= 1 << 3; }
        if self.pressed(BTN_SELECT) { r[9] |= 1 << 4; }
        if self.pressed(BTN_START) { r[9] |= 1 << 5; }

        // Steamac transport button mapping:
        // THUMBL (0x13d) = L3, THUMBR (0x13e) = R3,
        // MODE (0x13c) = PS.
        if self.pressed(BTN_THUMBL) { r[9] |= 1 << 6; } // L3
        if self.pressed(BTN_THUMBR) { r[9] |= 1 << 7; } // R3

        // Byte 10: PS + physical touchpad click.
        if self.pressed(BTN_MODE) {
            r[10] |= 0x01;
        }
        if self.pressed(SONY_TOUCHPAD_CLICK) {
            r[10] |= 0x02;
        }

        // DualSense power status. hid-playstation converts the low nibble to
        // capacity as (level * 10 + 5), so choose the nearest 10%-step
        // midpoint. The high nibble describes the charging state.
        if let Some(percent) = self.state.battery_percent {
            let level = (percent / 10).min(9);
            let charging = match self.state.battery_state.unwrap_or(BatteryState::Unknown) {
                BatteryState::Discharging => 0x00,
                BatteryState::Charging => 0x10,
                BatteryState::Full => 0x20,
                BatteryState::Unknown => 0x00,
            };

            // Byte 53 is the power-state byte in the 64-byte USB input report.
            r[53] = charging | level;
        }

        // UHID_INPUT2: type + size + data[4096].
        let mut msg = vec![0u8; 4 + 2 + 4096];
        msg[0..4].copy_from_slice(&UHID_INPUT2.to_ne_bytes());
        msg[4..6].copy_from_slice(&(r.len() as u16).to_ne_bytes());
        msg[6..6 + r.len()].copy_from_slice(&r);

        self.write_all(&msg)
    }

    fn drain_kernel_events(&self) -> Option<(u16, u16)> {
        let mut rumble = None;

        // hid-playstation sends START/OPEN plus feature and output requests.
        // Drain and answer them here so /dev/uhid never wedges.
        let mut b = [0u8; 4380];
        loop {
            let n = unsafe {
                libc::read(
                    self.fd,
                    b.as_mut_ptr() as *mut libc::c_void,
                    b.len(),
                )
            };
            if n <= 0 {
                break;
            }

            if n >= 4 {
                let kind = u32::from_ne_bytes([b[0], b[1], b[2], b[3]]);

                // hid-playstation retrieves three DualSense feature reports
                // while probing a USB controller.  UHID_GET_REPORT contains:
                // id:u32, rnum:u8, rtype:u8.  Reply with the complete
                // uhid_get_report_reply_req (id, err, size, data[4096]).
                if kind == UHID_GET_REPORT && n >= 8 {
                    let req = u32::from_ne_bytes([b[4], b[5], b[6], b[7]]);


                    let report_id = b[8];

                    let data: Option<Vec<u8>> = match report_id {
                        // Pairing information. hid-playstation uses bytes 1..7
                        // as the controller MAC address.
                        0x09 => {
                            let mut r = vec![0u8; 20];
                            r[0] = 0x09;
                            // Stable locally-administered address for this
                            // synthetic controller (stored little-endian by
                            // hid-playstation).
                            r[1..7].copy_from_slice(&[0x02, 0x00, 0x00, 0x00, 0x00, 0x01]);
                            Some(r)
                        }

                        // Firmware information. The driver reads hardware
                        // version at 24, firmware version at 28, and feature
                        // ("update") version at 44.
                        0x20 => {
                            let mut r = vec![0u8; 64];
                            r[0] = 0x20;
                            r[24..28].copy_from_slice(&1u32.to_le_bytes());
                            r[28..32].copy_from_slice(&1u32.to_le_bytes());
                            // >= 2.21 enables the driver's modern compatible
                            // vibration path.
                            r[44..46].copy_from_slice(&0x0215u16.to_le_bytes());
                            Some(r)
                        }

                        // Sensor calibration. We don't transport motion data
                        // yet, but the driver requires a successful report.
                        // Use non-zero symmetric ranges so its calibration
                        // denominators are valid.
                        0x05 => {
                            let mut r = vec![0u8; 41];
                            r[0] = 0x05;

                            let vals: [i16; 17] = [
                                0, 0, 0,       // gyro biases
                                16384, -16384, // pitch +/-
                                16384, -16384, // yaw +/-
                                16384, -16384, // roll +/-
                                1024, 1024,    // gyro speed +/-
                                8192, -8192,   // accel X +/-
                                8192, -8192,   // accel Y +/-
                                8192, -8192,   // accel Z +/-
                            ];

                            for (i, v) in vals.iter().enumerate() {
                                let off = 1 + i * 2;
                                r[off..off + 2].copy_from_slice(&v.to_le_bytes());
                            }
                            Some(r)
                        }

                        _ => None,
                    };

                    if let Some(data) = data {
                        let mut reply = vec![0u8; 4 + 4 + 2 + 2 + 4096];
                        reply[0..4].copy_from_slice(&UHID_GET_REPORT_REPLY.to_ne_bytes());
                        reply[4..8].copy_from_slice(&req.to_ne_bytes());
                        reply[8..10].copy_from_slice(&0u16.to_ne_bytes());
                        reply[10..12].copy_from_slice(&(data.len() as u16).to_ne_bytes());
                        reply[12..12 + data.len()].copy_from_slice(&data);
                        let _ = self.write_all(&reply);
                    } else {
                        let mut reply = vec![0u8; 4 + 4 + 2 + 2 + 4096];
                        reply[0..4].copy_from_slice(&UHID_GET_REPORT_REPLY.to_ne_bytes());
                        reply[4..8].copy_from_slice(&req.to_ne_bytes());
                        reply[8..10].copy_from_slice(&(libc::EIO as u16).to_ne_bytes());
                        let _ = self.write_all(&reply);
                    }
                } else if kind == UHID_SET_REPORT && n >= 8 {
                    let req = u32::from_ne_bytes([b[4], b[5], b[6], b[7]]);
                    let mut reply = [0u8; 10];
                    reply[0..4].copy_from_slice(&UHID_SET_REPORT_REPLY.to_ne_bytes());
                    reply[4..8].copy_from_slice(&req.to_ne_bytes());
                    reply[8..10].copy_from_slice(&(libc::EIO as u16).to_ne_bytes());
                    let _ = self.write_all(&reply);
                } else if kind == UHID_OUTPUT && n >= 9 {
                    let data = &b[4..];

                    // USB DualSense output report 0x02. hid-playstation gives
                    // us the fully composed report, including explicit zero
                    // motor values when vibration stops.
                    //
                    //   0: report id
                    //   1: valid flags
                    //   2: secondary flags
                    //   3: right / weak motor
                    //   4: left / strong motor
                    if data[0] == 0x02 {
                        let weak = u16::from(data[3]) * 257;
                        let strong = u16::from(data[4]) * 257;
                        rumble = Some((strong, weak));
                    }
                }
            }
        }

        rumble
    }
}


// MARK: DualShock 4 UHID

#[derive(Default)]
struct DualShock4State {
    buttons: BTreeMap<u16, bool>,
    axes: BTreeMap<u16, i32>,
    battery_percent: Option<u8>,
    battery_state: Option<BatteryState>,
}

struct DualShock4 {
    fd: libc::c_int,
    state: DualShock4State,
}

impl DualShock4 {
    fn create(path: &str) -> io::Result<Self> {
        let c = CString::new(path)
            .map_err(|_| io::Error::from(io::ErrorKind::InvalidInput))?;
        let fd = unsafe {
            libc::open(c.as_ptr(), libc::O_RDWR | libc::O_NONBLOCK | libc::O_CLOEXEC)
        };
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }

        let d = Self {
            fd,
            state: DualShock4State::default(),
        };

        if let Err(e) = d.create_kernel_device() {
            unsafe { libc::close(fd) };
            return Err(e);
        }

        Ok(d)
    }

    fn write_all(&self, data: &[u8]) -> io::Result<()> {
        let n = unsafe {
            libc::write(
                self.fd,
                data.as_ptr() as *const libc::c_void,
                data.len(),
            )
        };

        if n < 0 {
            Err(io::Error::last_os_error())
        } else if n as usize != data.len() {
            Err(io::Error::new(io::ErrorKind::WriteZero, "short UHID write"))
        } else {
            Ok(())
        }
    }

    fn create_kernel_device(&self) -> io::Result<()> {
        // struct uhid_create2_req:
        // name[128], phys[64], uniq[64], rd_size, bus, vendor, product,
        // version, country, rd_data[4096].
        let mut b = vec![0u8; 4 + 128 + 64 + 64 + 2 + 2 + 4 * 4 + 4096];

        b[0..4].copy_from_slice(&UHID_CREATE2.to_ne_bytes());

        let name = b"Sony Interactive Entertainment Wireless Controller";
        b[4..4 + name.len()].copy_from_slice(name);

        let rd_size_off = 4 + 128 + 64 + 64;
        b[rd_size_off..rd_size_off + 2]
            .copy_from_slice(&(DUALSHOCK4_RDESC.len() as u16).to_ne_bytes());

        // BUS_USB = 0x03
        b[rd_size_off + 2..rd_size_off + 4]
            .copy_from_slice(&3u16.to_ne_bytes());
        b[rd_size_off + 4..rd_size_off + 8]
            .copy_from_slice(&(SONY_VENDOR as u32).to_ne_bytes());
        b[rd_size_off + 8..rd_size_off + 12]
            .copy_from_slice(&(DUALSHOCK4_PRODUCT as u32).to_ne_bytes());

        let rd_off = rd_size_off + 2 + 2 + 4 * 4;
        b[rd_off..rd_off + DUALSHOCK4_RDESC.len()]
            .copy_from_slice(DUALSHOCK4_RDESC);

        self.write_all(&b)
    }

    fn stick8(v: i32) -> u8 {
        let v = v.clamp(-32767, 32767) as i64;
        (((v + 32767) * 255 + 32767) / 65534).clamp(0, 255) as u8
    }

    fn trigger8(v: i32) -> u8 {
        v.clamp(0, 255) as u8
    }

    fn hat(x: i32, y: i32) -> u8 {
        match (x, y) {
            (0, -1) => 0,
            (1, -1) => 1,
            (1, 0) => 2,
            (1, 1) => 3,
            (0, 1) => 4,
            (-1, 1) => 5,
            (-1, 0) => 6,
            (-1, -1) => 7,
            _ => 15,
        }
    }

    fn pressed(&self, code: u16) -> bool {
        self.state.buttons.get(&code).copied().unwrap_or(false)
    }

    fn axis(&self, code: u16) -> i32 {
        self.state.axes.get(&code).copied().unwrap_or(0)
    }

    fn write_frame(&mut self, events: &[(u16, u16, i32)]) -> io::Result<()> {
        for &(t, c, v) in events {
            match t {
                EV_KEY => {
                    self.state.buttons.insert(c, v != 0);
                }
                EV_ABS => {
                    self.state.axes.insert(c, v);
                }
                _ => {}
            }
        }

        self.send_report()
    }

    fn send_report(&self) -> io::Result<()> {
        // DS4 USB input report 0x01 is 64 bytes.
        //
        // Bytes 1..4: LX, LY, RX, RY
        // Byte 5:     hat + Square/Cross/Circle/Triangle
        // Byte 6:     L1/R1/L2/R2/Share/Options/L3/R3
        // Byte 7:     PS + touchpad click
        // Bytes 8..9: analog L2/R2
        let mut r = [0u8; 64];
        r[0] = 0x01;

        r[1] = Self::stick8(self.axis(0x00));   // LX / ABS_X
        r[2] = Self::stick8(self.axis(0x01));   // LY / ABS_Y
        r[3] = Self::stick8(self.axis(0x03));   // RX / ABS_RX
        r[4] = Self::stick8(self.axis(0x04));   // RY / ABS_RY

        let mut b5 = Self::hat(self.axis(0x10), self.axis(0x11));
        if self.pressed(BTN_WEST) { b5 |= 1 << 4; } // Square / BTN_WEST
        if self.pressed(BTN_SOUTH) { b5 |= 1 << 5; } // Cross  / BTN_SOUTH
        if self.pressed(BTN_EAST) { b5 |= 1 << 6; } // Circle / BTN_EAST
        if self.pressed(BTN_NORTH) { b5 |= 1 << 7; } // Triangle / BTN_NORTH
        r[5] = b5;

        if self.pressed(BTN_TL) { r[6] |= 1 << 0; } // L1
        if self.pressed(BTN_TR) { r[6] |= 1 << 1; } // R1
        if self.pressed(BTN_TL2) { r[6] |= 1 << 2; } // L2
        if self.pressed(BTN_TR2) { r[6] |= 1 << 3; } // R2
        if self.pressed(BTN_SELECT) { r[6] |= 1 << 4; } // Share
        if self.pressed(BTN_START) { r[6] |= 1 << 5; } // Options
        if self.pressed(BTN_THUMBL) { r[6] |= 1 << 6; } // L3
        if self.pressed(BTN_THUMBR) { r[6] |= 1 << 7; } // R3

        if self.pressed(BTN_MODE) {
            r[7] |= 1 << 0; // PS
        }
        if self.pressed(SONY_TOUCHPAD_CLICK) {
            r[7] |= 1 << 1; // touchpad click
        }

        r[8] = Self::trigger8(self.axis(0x02)); // L2 / ABS_Z
        r[9] = Self::trigger8(self.axis(0x05)); // R2 / ABS_RZ

        // DS4 USB battery status lives at byte 30.
        // Low nibble: 0..10 capacity, 11 = full.
        // Bit 4: cable connected. This synthetic controller is USB.
        if let Some(percent) = self.state.battery_percent {
            let capacity = if matches!(self.state.battery_state, Some(BatteryState::Full)) {
                11
            } else {
                (percent.min(100) / 10).min(10)
            };
            r[30] = 0x10 | capacity;
        }

        // No finger coordinates are transported yet. Mark the touch slots
        // inactive while retaining the native DS4 touchpad device topology.
        r[33] = 1;    // one valid touch subreport
        r[35] = 0x80; // finger 0 inactive
        r[39] = 0x80; // finger 1 inactive

        let mut msg = vec![0u8; 4 + 2 + 4096];
        msg[0..4].copy_from_slice(&UHID_INPUT2.to_ne_bytes());
        msg[4..6].copy_from_slice(&(r.len() as u16).to_ne_bytes());
        msg[6..6 + r.len()].copy_from_slice(&r);

        self.write_all(&msg)
    }

    fn get_feature_report(report_id: u8) -> Option<Vec<u8>> {
        match report_id {
            // USB motion-sensor calibration report from hidtools.
            0x02 => Some(vec![
                0x02, 0x1e, 0x00, 0x05, 0x00, 0xe2, 0xff, 0xf2,
                0x22, 0x4f, 0xdd, 0xbe, 0x22, 0x4d, 0xdd, 0x8d,
                0x22, 0x39, 0xdd, 0x1c, 0x02, 0x1c, 0x02, 0xe3,
                0x1f, 0x8b, 0xdf, 0x8c, 0x1e, 0xb4, 0xde, 0x30,
                0x20, 0x71, 0xe0, 0x10, 0x00,
            ]),

            // Recommended USB MAC-address report.
            0x12 => Some(vec![
                0x12, 0x02, 0x00, 0x00, 0x00, 0x00, 0x01,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00,
            ]),

            // Alternate DS4 MAC-address report.
            0x81 => Some(vec![
                0x81, 0x02, 0x00, 0x00, 0x00, 0x00, 0x01,
            ]),

            // Hardware / firmware version from hidtools.
            0xa3 => Some(vec![
                0xa3, 0x41, 0x70, 0x72, 0x20, 0x20, 0x38, 0x20,
                0x32, 0x30, 0x31, 0x34, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x30, 0x39, 0x3a, 0x34, 0x36, 0x3a, 0x30,
                0x36, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x01, 0x00, 0x43, 0x03, 0x00, 0x00,
                0x00, 0x51, 0x00, 0x05, 0x00, 0x00, 0x80, 0x03,
                0x00,
            ]),

            _ => None,
        }
    }

    fn drain_kernel_events(&self) -> Option<(u16, u16)> {
        let mut rumble = None;
        let mut b = [0u8; 4380];

        loop {
            let n = unsafe {
                libc::read(
                    self.fd,
                    b.as_mut_ptr() as *mut libc::c_void,
                    b.len(),
                )
            };

            if n <= 0 {
                break;
            }

            if n < 4 {
                continue;
            }

            let kind = u32::from_ne_bytes([b[0], b[1], b[2], b[3]]);

            if kind == UHID_GET_REPORT && n >= 10 {
                let req = u32::from_ne_bytes([b[4], b[5], b[6], b[7]]);
                let report_id = b[8];

                let mut reply = vec![0u8; 4 + 4 + 2 + 2 + 4096];
                reply[0..4].copy_from_slice(&UHID_GET_REPORT_REPLY.to_ne_bytes());
                reply[4..8].copy_from_slice(&req.to_ne_bytes());

                if let Some(data) = Self::get_feature_report(report_id) {
                    reply[8..10].copy_from_slice(&0u16.to_ne_bytes());
                    reply[10..12]
                        .copy_from_slice(&(data.len() as u16).to_ne_bytes());
                    reply[12..12 + data.len()].copy_from_slice(&data);
                } else {
                    reply[8..10]
                        .copy_from_slice(&(libc::EIO as u16).to_ne_bytes());
                }

                let _ = self.write_all(&reply);
            } else if kind == UHID_SET_REPORT && n >= 8 {
                let req = u32::from_ne_bytes([b[4], b[5], b[6], b[7]]);
                let mut reply = [0u8; 10];
                reply[0..4].copy_from_slice(&UHID_SET_REPORT_REPLY.to_ne_bytes());
                reply[4..8].copy_from_slice(&req.to_ne_bytes());
                reply[8..10]
                    .copy_from_slice(&(libc::EIO as u16).to_ne_bytes());
                let _ = self.write_all(&reply);
            } else if kind == UHID_OUTPUT && n >= 10 {
                let data = &b[4..];
                if data[0] == 0x05 && data.len() >= 6 {
                    let weak = u16::from(data[4]) * 257;
                    let strong = u16::from(data[5]) * 257;
                    rumble = Some((strong, weak));
                }
            }
        }

        rumble
    }
}

impl Drop for DualShock4 {
    fn drop(&mut self) {
        let _ = self.write_all(&UHID_DESTROY.to_ne_bytes());
        unsafe { libc::close(self.fd) };
    }
}

impl Drop for DualSense {
    fn drop(&mut self) {
        let _ = self.write_all(&UHID_DESTROY.to_ne_bytes());
        unsafe { libc::close(self.fd) };
    }
}

enum PadDevice {
    Uinput(Device),
    DualSense(DualSense),
    DualShock4(DualShock4),
}

impl PadDevice {
    fn fd(&self) -> libc::c_int {
        match self {
            Self::Uinput(d) => d.fd,
            Self::DualSense(d) => d.fd,
            Self::DualShock4(d) => d.fd,
        }
    }

    fn write_frame(&mut self, events: &[(u16, u16, i32)]) -> io::Result<()> {
        match self {
            Self::Uinput(d) => d.write_frame(events),
            Self::DualSense(d) => d.write_frame(events),
            Self::DualShock4(d) => d.write_frame(events),
        }
    }
}

// MARK: service

/// Serve the port until the host closes it (exit 0); exit 1 if it cannot be opened.
pub fn run() -> i32 {
    let port_path = std::env::var("FX_PAD_PORT").unwrap_or_else(|_| DEFAULT_PORT.into());
    let uinput = std::env::var("FX_PAD_UINPUT").unwrap_or_else(|_| DEFAULT_UINPUT.into());
    let uhid = std::env::var("FX_PAD_UHID").unwrap_or_else(|_| DEFAULT_UHID.into());
    let mut port = match Port::open(&port_path) {
        Ok(p) => p,
        Err(e) => {
            eprintln!("fx-pad: {port_path}: {e}");
            return 1;
        }
    };
    let clock = Instant::now();
    let ms = || clock.elapsed().as_millis() as u64;
    let mut pad: Option<PadDevice> = None;
    let mut rumble = Rumble::default();
    let mut sony_rumble = (0u16, 0u16);
    let mut sent = (0u16, 0u16);
    eprintln!("fx-pad: > hello");
    port.send_quiet("hello");
    loop {
        for line in port.read_lines() {
            match parse(&line) {
                Some(Command::Create(spec)) => {
                    pad = None;
                    rumble = Rumble::default();
                    sony_rumble = (0, 0);
                    if spec.vendor == SONY_VENDOR
                        && matches!(spec.product, DUALSENSE_PRODUCT | DUALSENSE_EDGE_PRODUCT)
                    {
                        match DualSense::create(&uhid, spec.product) {
                            Ok(d) => {
                                eprintln!(
                                    "fx-pad: created PlayStation UHID \"{}\" ({:04x}:{:04x})",
                                    spec.name, spec.vendor, spec.product
                                );
                                pad = Some(PadDevice::DualSense(d));
                            }
                            Err(e) => eprintln!(
                                "fx-pad: cannot create PlayStation \"{}\" on {uhid}: {e}",
                                spec.name
                            ),
                        }
                    } else if spec.vendor == SONY_VENDOR
                        && spec.product == DUALSHOCK4_PRODUCT
                    {
                        match DualShock4::create(&uhid) {
                            Ok(d) => {
                                eprintln!(
                                    "fx-pad: created DualShock 4 UHID \"{}\" ({:04x}:{:04x})",
                                    spec.name, spec.vendor, spec.product
                                );
                                pad = Some(PadDevice::DualShock4(d));
                            }
                            Err(e) => eprintln!(
                                "fx-pad: cannot create DualShock 4 \"{}\" on {uhid}: {e}",
                                spec.name
                            ),
                        }
                    } else {
                        match Device::create(&uinput, &spec) {
                            Ok(d) => {
                                eprintln!(
                                    "fx-pad: created \"{}\" ({:04x}:{:04x})",
                                    spec.name, spec.vendor, spec.product
                                );
                                pad = Some(PadDevice::Uinput(d));
                            }
                            Err(e) => eprintln!(
                                "fx-pad: cannot create \"{}\" on {uinput}: {e}",
                                spec.name
                            ),
                        }
                    }
                }
                Some(Command::Remove) => {
                    if pad.take().is_some() {
                        eprintln!("fx-pad: removed the pad");
                    }
                    rumble = Rumble::default();
                    sony_rumble = (0, 0);
                }
                Some(Command::Frame(events)) => {
                    if let Some(d) = &mut pad {
                        if let Err(e) = d.write_frame(&events) {
                            eprintln!("fx-pad: write: {e}");
                        }
                    }
                }
                Some(Command::Battery(percent, state)) => {
                    let result = match &mut pad {
                        Some(PadDevice::DualSense(d)) => {
                            d.state.battery_percent = Some(percent);
                            d.state.battery_state = Some(state);
                            Some(d.send_report())
                        }
                        Some(PadDevice::DualShock4(d)) => {
                            d.state.battery_percent = Some(percent);
                            d.state.battery_state = Some(state);
                            Some(d.send_report())
                        }
                        _ => None,
                    };

                    if let Some(Err(e)) = result {
                        eprintln!("fx-pad: battery report: {e}");
                    }
                }
                None => eprintln!("fx-pad: ignoring {:?}", line.trim()),
            }
        }
        if let Some(d) = &pad {
            match d {
                PadDevice::Uinput(d) => {
                    for e in d.read_events() {
                        let now = ms();
                        match e.type_ {
                            EV_UINPUT => {
                                if let Err(err) =
                                    d.serve(e.code, e.value as u32, &mut rumble, now)
                                {
                                    eprintln!(
                                        "fx-pad: force-feedback request {}: {err}",
                                        e.code
                                    );
                                }
                            }
                            EV_FF if e.code < FF_EFFECTS_MAX => {
                                rumble.play(e.code as i16, e.value, now)
                            }
                            _ => {}
                        }
                    }
                }
                PadDevice::DualSense(d) => {
                    if let Some(level) = d.drain_kernel_events() {
                        sony_rumble = level;
                    }
                }
                PadDevice::DualShock4(d) => {
                    if let Some(level) = d.drain_kernel_events() {
                        sony_rumble = level;
                    }
                }
            }
        }
        let now = ms();
        let level = match pad {
            Some(PadDevice::Uinput(_)) => rumble.level(now),
            Some(PadDevice::DualSense(_)) | Some(PadDevice::DualShock4(_)) => sony_rumble,
            None => (0, 0),
        };
        if level != sent {
            port.send_quiet(&format!("rumble {} {}", level.0, level.1));
            sent = level;
        }
        port.flush();

        // Wait for host lines, uinput requests / FF events, the next rumble change, or (while
        // bytes for the host are waiting) a retry tick.
        let Some(port_fd) = port.read_fd() else { return 0 };
        let mut pfds = [
            libc::pollfd { fd: port_fd, events: libc::POLLIN, revents: 0 },
            libc::pollfd { fd: pad.as_ref().map_or(-1, PadDevice::fd), events: libc::POLLIN, revents: 0 },
        ];
        let mut wait = rumble.next_change(now).map(|t| t.saturating_sub(now) as i64);
        if port.has_pending() {
            wait = Some(wait.map_or(200, |w| w.min(200)));
        }
        let timeout = wait.map_or(-1, |w| w.clamp(0, i32::MAX as i64) as libc::c_int);
        let n = unsafe { libc::poll(pfds.as_mut_ptr(), pfds.len() as libc::nfds_t, timeout) };
        if n < 0 && io::Error::last_os_error().kind() != io::ErrorKind::Interrupted {
            eprintln!("fx-pad: poll: {}", io::Error::last_os_error());
            return 1;
        }
        if pfds[0].revents & libc::POLLHUP != 0 && pfds[0].revents & libc::POLLIN == 0 {
            eprintln!("fx-pad: host closed the port");
            return 0;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const DS: &str = "create 0003 054c 0ce6 8111 304,305,307 0:-32768:32767:16:128,2:0:255:0:0 \
                      Sony Interactive Entertainment DualSense Wireless Controller";

    #[test]
    fn ioctl_numbers_match_the_kernel_headers() {
        // aarch64 / 64-bit values from <linux/uinput.h>: they encode the struct sizes.
        assert_eq!(UI_DEV_CREATE, 0x5501);
        assert_eq!(UI_DEV_DESTROY, 0x5502);
        assert_eq!(UI_DEV_SETUP, 0x405c5503);
        assert_eq!(UI_ABS_SETUP, 0x401c5504);
        assert_eq!(UI_SET_EVBIT, 0x40045564);
        assert_eq!(UI_SET_FFBIT, 0x4004556b);
        assert_eq!(UI_BEGIN_FF_UPLOAD, 0xc06855c8);
        assert_eq!(UI_END_FF_UPLOAD, 0x406855c9);
        assert_eq!(UI_BEGIN_FF_ERASE, 0xc00c55ca);
        assert_eq!(UI_END_FF_ERASE, 0x400c55cb);
    }

    #[test]
    fn parses_create_with_name_spaces() {
        let Some(Command::Create(s)) = parse(DS) else { panic!("not a create") };
        assert_eq!((s.bus, s.vendor, s.product, s.version), (3, 0x054c, 0x0ce6, 0x8111));
        assert_eq!(s.keys, vec![304, 305, 307]);
        assert_eq!(s.axes[0], Axis { code: 0, min: -32768, max: 32767, fuzz: 16, flat: 128 });
        assert_eq!(s.axes[1].code, 2);
        assert_eq!(s.name, "Sony Interactive Entertainment DualSense Wireless Controller");
    }

    #[test]
    fn rejects_malformed_lines() {
        assert_eq!(parse("create 0003 054c 0ce6 8111 304 0:0:1:0:0"), None, "no name");
        assert_eq!(parse("create 0003 054c 0ce6 8111 304 0:0:1:0 name"), None, "axis with 4 fields");
        assert_eq!(parse("create 0003 054c 0ce6 8111 768 - name"), None, "key code beyond KEY_MAX");
        assert_eq!(parse("create 0003 054c 0ce6 8111 - - name"), None, "no capabilities");
        assert_eq!(parse("create zz03 054c 0ce6 8111 304 - name"), None, "bad hex id");
        assert_eq!(parse("ev 1:304"), None);
        assert_eq!(parse("ev 21:0:1"), None, "only EV_KEY / EV_ABS from the host");
        assert_eq!(parse("ev"), None);
        assert_eq!(parse("remove now"), None);
        assert_eq!(parse("hello"), None);
    }

    #[test]
    fn parses_frames_and_remove() {
        assert_eq!(parse("ev 1:304:1 3:0:-32768\n"), Some(Command::Frame(vec![(1, 304, 1), (3, 0, -32768)])));
        assert_eq!(parse("remove"), Some(Command::Remove));
    }

    fn fx(strong: u16, weak: u16, length: u16, delay: u16) -> Effect {
        Effect { strong, weak, length, delay }
    }

    #[test]
    fn plays_after_delay_for_length() {
        let mut r = Rumble::default();
        r.upload(0, fx(1000, 2000, 100, 50), 0);
        assert_eq!(r.level(0), (0, 0), "uploaded only");
        r.play(0, 1, 10);
        assert_eq!(r.level(59), (0, 0));
        assert_eq!(r.next_change(59), Some(60));
        assert_eq!(r.level(60), (1000, 2000));
        assert_eq!(r.next_change(60), Some(160));
        assert_eq!(r.level(159), (1000, 2000));
        assert_eq!(r.level(160), (0, 0));
        assert_eq!(r.next_change(160), None);
    }

    #[test]
    fn zero_length_plays_until_stopped() {
        let mut r = Rumble::default();
        r.upload(3, fx(500, 0, 0, 0), 0);
        r.play(3, 1, 0);
        assert_eq!(r.level(1_000_000), (500, 0));
        assert_eq!(r.next_change(1_000_000), None);
        r.play(3, 0, 1_000_001);
        assert_eq!(r.level(1_000_001), (0, 0));
    }

    #[test]
    fn repeats_with_delay_before_each_play() {
        let mut r = Rumble::default();
        r.upload(1, fx(100, 100, 10, 5), 0);
        r.play(1, 2, 0);
        assert_eq!(r.level(5), (100, 100));
        assert_eq!(r.level(15), (0, 0), "gap: the second play waits its delay");
        assert_eq!(r.next_change(15), Some(20));
        assert_eq!(r.level(20), (100, 100));
        assert_eq!(r.level(30), (0, 0));
        assert_eq!(r.next_change(30), None);
    }

    #[test]
    fn concurrent_effects_add_up_and_saturate() {
        let mut r = Rumble::default();
        r.upload(0, fx(40000, 1000, 0, 0), 0);
        r.upload(1, fx(40000, 2000, 50, 0), 0);
        r.play(0, 1, 0);
        r.play(1, 1, 0);
        assert_eq!(r.level(10), (0xffff, 3000));
        assert_eq!(r.level(50), (40000, 1000), "effect 1 ended");
    }

    #[test]
    fn reupload_restarts_a_playing_effect() {
        // SDL updates its rumble by uploading the same id again (and playing it).
        let mut r = Rumble::default();
        r.upload(0, fx(1000, 0, 100, 0), 0);
        r.play(0, 1, 0);
        r.upload(0, fx(3000, 0, 100, 0), 80);
        assert_eq!(r.level(80), (3000, 0));
        assert_eq!(r.level(150), (3000, 0), "the new parameters run their full length from the update");
        assert_eq!(r.level(180), (0, 0));
        r.upload(0, fx(5000, 0, 100, 0), 200);
        assert_eq!(r.level(200), (0, 0), "an idle effect stays idle when updated");
    }

    #[test]
    fn stop_and_erase_silence_an_effect() {
        let mut r = Rumble::default();
        r.upload(0, fx(1000, 0, 0, 0), 0);
        r.upload(1, fx(2000, 0, 0, 0), 0);
        r.play(0, 1, 0);
        r.play(1, 1, 0);
        r.play(0, 0, 10);
        assert_eq!(r.level(10), (2000, 0));
        r.erase(1);
        assert_eq!(r.level(10), (0, 0));
        r.play(1, 1, 20);
        assert_eq!(r.level(20), (0, 0), "an erased effect cannot be played");
    }
}
