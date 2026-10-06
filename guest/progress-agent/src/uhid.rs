//! A HID device of the Mac passed through to the guest as a uhid device (`/dev/uhid`, see
//! <linux/uhid.h>): the guest's own HID driver (hid-playstation for a DualSense) binds to it and
//! /dev/hidraw* carries its raw reports, exactly as for the controller plugged into a Linux machine.
//! Reports keep the HID convention: a numbered report starts with its report ID.
//!
//! The uhid ABI is one packed `struct uhid_event` per read/write: `u32 type`, then the union of
//! the request structs. Offsets below are those of the packed structs.

use std::ffi::CString;
use std::io;

/// UHID_DATA_MAX, HID_MAX_DESCRIPTOR_SIZE.
pub const DATA_MAX: usize = 4096;
/// sizeof(struct uhid_event): the type and the largest member, uhid_create2_req.
pub const EVENT_SIZE: usize = 4 + 128 + 64 + 64 + 2 + 2 + 4 * 4 + DATA_MAX;

// enum uhid_event_type
const DESTROY: u32 = 1;
const START: u32 = 2;
const STOP: u32 = 3;
const OPEN: u32 = 4;
const CLOSE: u32 = 5;
const OUTPUT: u32 = 6;
const GET_REPORT: u32 = 9;
const GET_REPORT_REPLY: u32 = 10;
const CREATE2: u32 = 11;
const INPUT2: u32 = 12;
const SET_REPORT: u32 = 13;
const SET_REPORT_REPLY: u32 = 14;

/// enum uhid_report_type, as the protocol names it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ReportType {
    Feature,
    Output,
    Input,
}

impl ReportType {
    fn from_raw(v: u8) -> Option<ReportType> {
        match v {
            0 => Some(ReportType::Feature),
            1 => Some(ReportType::Output),
            2 => Some(ReportType::Input),
            _ => None,
        }
    }

    pub fn name(self) -> &'static str {
        match self {
            ReportType::Feature => "feature",
            ReportType::Output => "output",
            ReportType::Input => "input",
        }
    }
}

/// What `hid-create` asks for: the Mac device's identity and report descriptor.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HidSpec {
    pub bus: u16,
    pub vendor: u16,
    pub product: u16,
    pub version: u16,
    pub country: u32,
    pub descriptor: Vec<u8>,
    pub name: String,
}

/// Requests of the guest's HID drivers and hidraw users, for the host.
#[derive(Debug, PartialEq, Eq)]
pub enum Event {
    /// The driver started / stopped, a hidraw or input user opened / closed it.
    Start,
    Stop,
    Open,
    Close,
    /// An output report (hid_hw_output_report, hidraw write).
    Output { rtype: ReportType, data: Vec<u8> },
    /// GET_REPORT: the driver waits for `get_reply` with this id (uhid gives up after 5 s).
    GetReport { id: u32, rnum: u8, rtype: ReportType },
    /// SET_REPORT: the driver waits for `set_reply` with this id.
    SetReport { id: u32, rnum: u8, rtype: ReportType, data: Vec<u8> },
}

fn put(buf: &mut [u8], at: usize, bytes: &[u8]) {
    buf[at..at + bytes.len()].copy_from_slice(bytes);
}

fn u16_at(buf: &[u8], at: usize) -> u16 {
    u16::from_ne_bytes([buf[at], buf[at + 1]])
}

fn u32_at(buf: &[u8], at: usize) -> u32 {
    u32::from_ne_bytes([buf[at], buf[at + 1], buf[at + 2], buf[at + 3]])
}

/// UHID_CREATE2. Strings are cut to fit with their NUL; the descriptor must fit DATA_MAX.
pub fn encode_create(spec: &HidSpec, phys: &str) -> Vec<u8> {
    let mut b = vec![0u8; EVENT_SIZE];
    put(&mut b, 0, &CREATE2.to_ne_bytes());
    let name = spec.name.as_bytes();
    put(&mut b, 4, &name[..name.len().min(127)]);
    let phys = phys.as_bytes();
    put(&mut b, 132, &phys[..phys.len().min(63)]);
    // uniq (196..260) stays empty: hid-playstation sets it from the controller's MAC address.
    put(&mut b, 260, &(spec.descriptor.len() as u16).to_ne_bytes());
    put(&mut b, 262, &spec.bus.to_ne_bytes());
    put(&mut b, 264, &(spec.vendor as u32).to_ne_bytes());
    put(&mut b, 268, &(spec.product as u32).to_ne_bytes());
    put(&mut b, 272, &(spec.version as u32).to_ne_bytes());
    put(&mut b, 276, &spec.country.to_ne_bytes());
    put(&mut b, 280, &spec.descriptor);
    b
}

/// UHID_INPUT2 with one input report.
pub fn encode_input(report: &[u8]) -> Vec<u8> {
    let mut b = vec![0u8; 6 + report.len()];
    put(&mut b, 0, &INPUT2.to_ne_bytes());
    put(&mut b, 4, &(report.len() as u16).to_ne_bytes());
    put(&mut b, 6, report);
    b
}

/// UHID_GET_REPORT_REPLY: `err` 0 with the report (ID first), or an errno without data.
pub fn encode_get_reply(id: u32, err: u16, data: &[u8]) -> Vec<u8> {
    let mut b = vec![0u8; 12 + data.len()];
    put(&mut b, 0, &GET_REPORT_REPLY.to_ne_bytes());
    put(&mut b, 4, &id.to_ne_bytes());
    put(&mut b, 8, &err.to_ne_bytes());
    put(&mut b, 10, &(data.len() as u16).to_ne_bytes());
    put(&mut b, 12, data);
    b
}

/// UHID_SET_REPORT_REPLY.
pub fn encode_set_reply(id: u32, err: u16) -> Vec<u8> {
    let mut b = vec![0u8; 10];
    put(&mut b, 0, &SET_REPORT_REPLY.to_ne_bytes());
    put(&mut b, 4, &id.to_ne_bytes());
    put(&mut b, 8, &err.to_ne_bytes());
    b
}

/// One event read from /dev/uhid (EVENT_SIZE bytes); None for types the host does not need.
pub fn decode(b: &[u8]) -> Option<Event> {
    if b.len() < EVENT_SIZE {
        return None;
    }
    let data = |at: usize, len: usize| b[at..at + len.min(DATA_MAX)].to_vec();
    match u32_at(b, 0) {
        START => Some(Event::Start),
        STOP => Some(Event::Stop),
        OPEN => Some(Event::Open),
        CLOSE => Some(Event::Close),
        // uhid_output_req: data[4096], u16 size, u8 rtype.
        OUTPUT => Some(Event::Output {
            rtype: ReportType::from_raw(b[4 + DATA_MAX + 2])?,
            data: data(4, u16_at(b, 4 + DATA_MAX) as usize),
        }),
        // uhid_get_report_req: u32 id, u8 rnum, u8 rtype.
        GET_REPORT => Some(Event::GetReport { id: u32_at(b, 4), rnum: b[8], rtype: ReportType::from_raw(b[9])? }),
        // uhid_set_report_req: u32 id, u8 rnum, u8 rtype, u16 size, data[4096].
        SET_REPORT => Some(Event::SetReport {
            id: u32_at(b, 4),
            rnum: b[8],
            rtype: ReportType::from_raw(b[9])?,
            data: data(12, u16_at(b, 10) as usize),
        }),
        _ => None,
    }
}

/// The uhid device; destroyed on drop (closing the fd would do it too).
pub struct Device {
    pub fd: libc::c_int,
}

impl Device {
    pub fn create(path: &str, spec: &HidSpec) -> io::Result<Device> {
        let c = CString::new(path).map_err(|_| io::Error::from(io::ErrorKind::InvalidInput))?;
        let fd = unsafe { libc::open(c.as_ptr(), libc::O_RDWR | libc::O_NONBLOCK | libc::O_CLOEXEC) };
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        let d = Device { fd };
        d.write(&encode_create(spec, "fx.pad"))?;
        Ok(d)
    }

    /// One whole event; uhid takes each write as one event.
    pub fn write(&self, event: &[u8]) -> io::Result<()> {
        loop {
            let n = unsafe { libc::write(self.fd, event.as_ptr() as *const libc::c_void, event.len()) };
            if n >= 0 {
                return Ok(());
            }
            let e = io::Error::last_os_error();
            if e.kind() != io::ErrorKind::Interrupted {
                return Err(e);
            }
        }
    }

    /// Pending events; never blocks.
    pub fn read_events(&self) -> Vec<Event> {
        let mut out = Vec::new();
        let mut buf = vec![0u8; EVENT_SIZE];
        loop {
            let n = unsafe { libc::read(self.fd, buf.as_mut_ptr() as *mut libc::c_void, buf.len()) };
            if n == EVENT_SIZE as isize {
                out.extend(decode(&buf));
            } else if n < 0 && io::Error::last_os_error().kind() == io::ErrorKind::Interrupted {
                continue;
            } else {
                return out;
            }
        }
    }
}

impl Drop for Device {
    fn drop(&mut self) {
        let _ = self.write(&DESTROY.to_ne_bytes());
        unsafe { libc::close(self.fd) };
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn event_size_matches_the_kernel_struct() {
        // sizeof(struct uhid_event) (packed): u32 type + uhid_create2_req, the largest member.
        assert_eq!(EVENT_SIZE, 4376);
    }

    #[test]
    fn create_puts_fields_at_the_packed_offsets() {
        let spec = HidSpec {
            bus: 5,
            vendor: 0x054c,
            product: 0x0ce6,
            version: 0x0100,
            country: 0x21,
            descriptor: vec![0x05, 0x01, 0x09, 0x05],
            name: "DualSense Wireless Controller".into(),
        };
        let b = encode_create(&spec, "fx.pad");
        assert_eq!(b.len(), EVENT_SIZE);
        assert_eq!(u32_at(&b, 0), CREATE2);
        assert_eq!(&b[4..33], b"DualSense Wireless Controller");
        assert_eq!(b[33], 0);
        assert_eq!(&b[132..138], b"fx.pad");
        assert_eq!(u16_at(&b, 260), 4, "rd_size");
        assert_eq!(u16_at(&b, 262), 5, "bus");
        assert_eq!((u32_at(&b, 264), u32_at(&b, 268), u32_at(&b, 272)), (0x054c, 0x0ce6, 0x0100));
        assert_eq!(u32_at(&b, 276), 0x21, "country");
        assert_eq!(&b[280..284], &[0x05, 0x01, 0x09, 0x05]);
    }

    #[test]
    fn long_names_keep_their_terminator() {
        let spec = HidSpec { bus: 3, vendor: 1, product: 2, version: 0, country: 0, descriptor: vec![0], name: "n".repeat(200) };
        let b = encode_create(&spec, &"p".repeat(100));
        assert_eq!(b[4 + 127], 0);
        assert_eq!(b[132 + 63], 0);
    }

    #[test]
    fn decodes_output_and_report_requests() {
        let mut b = vec![0u8; EVENT_SIZE];
        put(&mut b, 0, &OUTPUT.to_ne_bytes());
        put(&mut b, 4, &[0x02, 0xff, 0xf7]);
        put(&mut b, 4 + DATA_MAX, &3u16.to_ne_bytes());
        b[4 + DATA_MAX + 2] = 1;
        assert_eq!(decode(&b), Some(Event::Output { rtype: ReportType::Output, data: vec![0x02, 0xff, 0xf7] }));

        let mut b = vec![0u8; EVENT_SIZE];
        put(&mut b, 0, &GET_REPORT.to_ne_bytes());
        put(&mut b, 4, &7u32.to_ne_bytes());
        b[8] = 0x05;
        b[9] = 0;
        assert_eq!(decode(&b), Some(Event::GetReport { id: 7, rnum: 5, rtype: ReportType::Feature }));

        let mut b = vec![0u8; EVENT_SIZE];
        put(&mut b, 0, &SET_REPORT.to_ne_bytes());
        put(&mut b, 4, &9u32.to_ne_bytes());
        b[8] = 0x80;
        b[9] = 0;
        put(&mut b, 10, &2u16.to_ne_bytes());
        put(&mut b, 12, &[0x80, 0x01]);
        assert_eq!(decode(&b), Some(Event::SetReport { id: 9, rnum: 0x80, rtype: ReportType::Feature, data: vec![0x80, 0x01] }));
    }

    #[test]
    fn rejects_short_reads_and_unknown_report_types() {
        assert_eq!(decode(&[0u8; 8]), None);
        let mut b = vec![0u8; EVENT_SIZE];
        put(&mut b, 0, &GET_REPORT.to_ne_bytes());
        b[9] = 7;
        assert_eq!(decode(&b), None);
    }

    #[test]
    fn replies_carry_id_error_and_data() {
        let b = encode_get_reply(3, 0, &[0x09, 1, 2]);
        assert_eq!((u32_at(&b, 0), u32_at(&b, 4), u16_at(&b, 8), u16_at(&b, 10)), (GET_REPORT_REPLY, 3, 0, 3));
        assert_eq!(&b[12..], &[0x09, 1, 2]);
        let b = encode_set_reply(4, 5);
        assert_eq!((u32_at(&b, 0), u32_at(&b, 4), u16_at(&b, 8)), (SET_REPORT_REPLY, 4, 5));
        let b = encode_input(&[0x01, 0x80]);
        assert_eq!((u32_at(&b, 0), u16_at(&b, 4)), (INPUT2, 2));
        assert_eq!(&b[6..], &[0x01, 0x80]);
    }
}
