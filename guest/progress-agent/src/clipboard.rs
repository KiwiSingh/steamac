//! `fx-progress-agent clipboard`: the guest side of the shared clipboard
//! (fx-clipboard-agent.service, a user service of the gamescope session and of
//! Desktop Mode). Text (UTF-8) and PNG images go both ways over the
//! virtio-console port /dev/virtio-ports/fx.clipboard; the launcher side is
//! host/launcher/Sources/steamac-vm/Clipboard.swift.
//!
//! Frames (both directions, little endian):
//!
//!   "FXCB" | type u8 | flags u8 (0) | reserved u16 (0) | seq u32 | length u32 | payload
//!
//!   1 HELLO  guest -> host at start: protocol version u32 + agent description (UTF-8)
//!   2 STATE  host -> guest: u8 1 = sharing on, 0 = off (sent after HELLO and on every change)
//!   3 SET    the clipboard changed on the sender's side: u16 item count, then per item
//!            u16 mime length, mime, u32 data length, data. Mimes: `text/plain;charset=utf-8`,
//!            `image/png` (others are ignored)
//!   4 ACK    answer to SET `seq`: u32 seq + u8 status (0 applied, 1 already the content,
//!            2 rejected: too large / malformed / sharing off)
//!
//! `seq` counts the sender's SET frames. Echo suppression is by content: both
//! sides remember the content they last took over or sent (FNV-1a hash) and
//! never send it back, so one copy gives exactly one transfer however often
//! gamescope, KWin or Klipper re-announce the same data.
//!
//! Inside SteamOS the agent is a clipboard owner and watcher on:
//!   - every gamescope Xwayland (clipx11.rs; gaming mode runs two, :0 for Steam
//!     and :1 for games). gamescope itself syncs plain text between them by
//!     taking over CLIPBOARD on all of its servers, but neither images nor text
//!     sent INCR, so the agent owns the selection on each server itself;
//!   - the Desktop Mode Plasma session's Wayland display (clipwl.rs, the
//!     wlr / ext data-control protocol: KWin bridges it to its own Xwayland).
//! A change seen on one of them is also handed to all the others, then to the
//! Mac. The selection present when a display appears is not sent (Klipper
//! restoring an old entry must not overwrite the Mac's clipboard); the current
//! shared content is offered on it instead.
//!
//! Limits (both sides): text 1 MiB, image 16 MiB; larger items are dropped
//! with a journal line.
//!
//! Environment override (testing): FX_CLIPBOARD_PORT=<path> instead of the port.

use std::collections::HashMap;
use std::io::{self, Read, Write};
use std::os::fd::{FromRawFd, RawFd};
use std::sync::mpsc::{self, Receiver, Sender, SyncSender};
use std::sync::Arc;
use std::time::Duration;

use crate::{clipwl, clipx11};

const DEFAULT_PORT: &str = "/dev/virtio-ports/fx.clipboard";
pub const TEXT_MAX: usize = 1 << 20;
pub const IMAGE_MAX: usize = 16 << 20;
pub const MIME_TEXT: &str = "text/plain;charset=utf-8";
pub const MIME_PNG: &str = "image/png";
const MAGIC: &[u8; 4] = b"FXCB";
const HEADER: usize = 16;
/// Largest payload accepted (both items at their limit + framing).
const MAX_PAYLOAD: usize = TEXT_MAX + IMAGE_MAX + 1024;
const PROTOCOL_VERSION: u32 = 1;
pub const TAG: &str = "fx-clipboard";

pub const T_HELLO: u8 = 1;
pub const T_STATE: u8 = 2;
pub const T_SET: u8 = 3;
pub const T_ACK: u8 = 4;

pub const ACK_APPLIED: u8 = 0;
pub const ACK_SAME: u8 = 1;
pub const ACK_REJECTED: u8 = 2;

/// One clipboard content: UTF-8 text and/or a PNG image.
#[derive(Debug, Default)]
pub struct Content {
    pub text: Option<Arc<Vec<u8>>>,
    pub png: Option<Arc<Vec<u8>>>,
    pub hash: u64,
}

impl Content {
    /// None if there is nothing (an empty clipboard is never shared).
    pub fn new(text: Option<Vec<u8>>, png: Option<Vec<u8>>) -> Option<Content> {
        let text = text.filter(|t| !t.is_empty());
        let png = png.filter(|p| !p.is_empty());
        if text.is_none() && png.is_none() {
            return None;
        }
        let mut h = Fnv::new();
        for (tag, part) in [(b'T', &text), (b'I', &png)] {
            if let Some(p) = part {
                h.write(&[tag]);
                h.write(&(p.len() as u64).to_le_bytes());
                h.write(p);
            }
        }
        Some(Content { text: text.map(Arc::new), png: png.map(Arc::new), hash: h.0 })
    }

    /// "text 31 B, image 5.9 KiB" for the journal.
    pub fn describe(&self) -> String {
        let mut parts = Vec::new();
        if let Some(t) = &self.text {
            parts.push(format!("text {}", size(t.len())));
        }
        if let Some(p) = &self.png {
            parts.push(format!("image {}", size(p.len())));
        }
        parts.join(", ")
    }
}

pub fn size(n: usize) -> String {
    if n < 1024 {
        format!("{n} B")
    } else if n < 1 << 20 {
        format!("{:.1} KiB", n as f64 / 1024.0)
    } else {
        format!("{:.1} MiB", n as f64 / (1 << 20) as f64)
    }
}

/// FNV-1a, 64 bit.
struct Fnv(u64);

impl Fnv {
    fn new() -> Fnv {
        Fnv(0xcbf29ce484222325)
    }
    fn write(&mut self, data: &[u8]) {
        for &b in data {
            self.0 = (self.0 ^ b as u64).wrapping_mul(0x100000001b3);
        }
    }
}

/// Drop items over their limit (journal line each); None if nothing is left.
pub fn capped(text: Option<Vec<u8>>, png: Option<Vec<u8>>, what: &str) -> Option<Content> {
    let text = text.filter(|t| {
        let ok = t.len() <= TEXT_MAX;
        if !ok {
            eprintln!("{TAG}: {what}: text of {} exceeds the {} limit: not shared", size(t.len()), size(TEXT_MAX));
        }
        ok
    });
    let png = png.filter(|p| {
        let ok = p.len() <= IMAGE_MAX;
        if !ok {
            eprintln!("{TAG}: {what}: image of {} exceeds the {} limit: not shared", size(p.len()), size(IMAGE_MAX));
        }
        ok
    });
    Content::new(text, png)
}

// MARK: frames

#[derive(Debug, PartialEq, Eq)]
pub struct Frame {
    pub kind: u8,
    pub seq: u32,
    pub payload: Vec<u8>,
}

pub fn encode(kind: u8, seq: u32, payload: &[u8]) -> Vec<u8> {
    let mut f = Vec::with_capacity(HEADER + payload.len());
    f.extend_from_slice(MAGIC);
    f.extend_from_slice(&[kind, 0, 0, 0]);
    f.extend_from_slice(&seq.to_le_bytes());
    f.extend_from_slice(&(payload.len() as u32).to_le_bytes());
    f.extend_from_slice(payload);
    f
}

pub fn set_payload(c: &Content) -> Vec<u8> {
    let items: Vec<(&str, &Arc<Vec<u8>>)> =
        [(MIME_TEXT, &c.text), (MIME_PNG, &c.png)].into_iter().filter_map(|(m, d)| d.as_ref().map(|d| (m, d))).collect();
    let mut p = Vec::with_capacity(2 + items.iter().map(|(m, d)| 6 + m.len() + d.len()).sum::<usize>());
    p.extend_from_slice(&(items.len() as u16).to_le_bytes());
    for (mime, data) in items {
        p.extend_from_slice(&(mime.len() as u16).to_le_bytes());
        p.extend_from_slice(mime.as_bytes());
        p.extend_from_slice(&(data.len() as u32).to_le_bytes());
        p.extend_from_slice(data);
    }
    p
}

/// SET payload -> (text, png); None if malformed.
pub fn parse_set(p: &[u8]) -> Option<(Option<Vec<u8>>, Option<Vec<u8>>)> {
    let mut r = Reader { p, at: 0 };
    let n = r.u16()?;
    let (mut text, mut png) = (None, None);
    for _ in 0..n {
        let ml = r.u16()? as usize;
        let mime = r.take(ml)?.to_vec();
        let dl = r.u32()? as usize;
        let data = r.take(dl)?;
        match std::str::from_utf8(&mime).ok()? {
            MIME_TEXT => text = Some(data.to_vec()),
            MIME_PNG => png = Some(data.to_vec()),
            _ => {}
        }
    }
    (r.at == p.len()).then_some((text, png))
}

struct Reader<'a> {
    p: &'a [u8],
    at: usize,
}

impl Reader<'_> {
    fn take(&mut self, n: usize) -> Option<&[u8]> {
        let s = self.p.get(self.at..self.at.checked_add(n)?)?;
        self.at += n;
        Some(s)
    }
    fn u16(&mut self) -> Option<u16> {
        Some(u16::from_le_bytes(self.take(2)?.try_into().ok()?))
    }
    fn u32(&mut self) -> Option<u32> {
        Some(u32::from_le_bytes(self.take(4)?.try_into().ok()?))
    }
}

/// Incremental frame decoder; resynchronises on the magic after garbage
/// (e.g. the tail of a frame a previous agent did not read to the end).
#[derive(Default)]
pub struct Decoder {
    buf: Vec<u8>,
}

impl Decoder {
    pub fn feed(&mut self, data: &[u8]) -> Vec<Frame> {
        self.buf.extend_from_slice(data);
        let mut out = Vec::new();
        loop {
            match self.buf.windows(4).position(|w| w == MAGIC) {
                Some(0) => {}
                Some(i) => {
                    self.buf.drain(..i);
                }
                None => {
                    // Keep a possible partial magic at the end.
                    let keep = self.buf.len().min(3);
                    self.buf.drain(..self.buf.len() - keep);
                    return out;
                }
            }
            if self.buf.len() < HEADER {
                return out;
            }
            let h = &self.buf[..HEADER];
            let kind = h[4];
            let len = u32::from_le_bytes(h[12..16].try_into().unwrap()) as usize;
            if !(T_HELLO..=T_ACK).contains(&kind) || h[5] != 0 || h[6] != 0 || h[7] != 0 || len > MAX_PAYLOAD {
                self.buf.drain(..1); // not a frame start: look for the next magic
                continue;
            }
            if self.buf.len() < HEADER + len {
                return out;
            }
            let seq = u32::from_le_bytes(h[8..12].try_into().unwrap());
            let payload = self.buf[HEADER..HEADER + len].to_vec();
            self.buf.drain(..HEADER + len);
            out.push(Frame { kind, seq, payload });
        }
    }
}

// MARK: coordinator

/// Requests to a display worker.
pub enum Cmd {
    /// Become the clipboard owner with this content.
    Own(Arc<Content>),
}

/// Events for the coordinator.
pub enum Ev {
    Host(Frame),
    HostGone,
    /// A display socket appeared (discovery): `x11 :1` / Wayland socket path.
    Display(Kind, String),
    /// A worker is connected and takes commands.
    Up(String, Mailbox),
    /// A worker's connection ended.
    Down(String),
    /// The clipboard of display `src` changed to this content.
    Guest(String, Content),
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Kind {
    X11,
    Wayland,
}

/// Command channel of a worker plus the eventfd that wakes its poll loop.
pub struct Mailbox {
    tx: Sender<Cmd>,
    wake: Arc<EventFd>,
}

impl Mailbox {
    pub fn send(&self, c: Cmd) {
        if self.tx.send(c).is_ok() {
            self.wake.signal();
        }
    }
}

/// The worker's end: commands + the fd to poll.
pub struct Inbox {
    pub rx: Receiver<Cmd>,
    pub wake: Arc<EventFd>,
}

pub fn mailbox() -> io::Result<(Mailbox, Inbox)> {
    let wake = Arc::new(EventFd::new()?);
    let (tx, rx) = mpsc::channel();
    Ok((Mailbox { tx, wake: wake.clone() }, Inbox { rx, wake }))
}

pub struct EventFd(RawFd);

impl EventFd {
    fn new() -> io::Result<EventFd> {
        let fd = unsafe { libc::eventfd(0, libc::EFD_CLOEXEC | libc::EFD_NONBLOCK) };
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(EventFd(fd))
    }
    pub fn fd(&self) -> RawFd {
        self.0
    }
    fn signal(&self) {
        let one: u64 = 1;
        unsafe { libc::write(self.0, &one as *const u64 as *const libc::c_void, 8) };
    }
    pub fn drain(&self) {
        let mut v: u64 = 0;
        unsafe { libc::read(self.0, &mut v as *mut u64 as *mut libc::c_void, 8) };
    }
}

impl Drop for EventFd {
    fn drop(&mut self) {
        unsafe { libc::close(self.0) };
    }
}

struct Coordinator {
    out: SyncSender<Vec<u8>>,
    workers: HashMap<String, Mailbox>,
    /// Displays with a worker (connecting or connected).
    started: HashMap<String, Kind>,
    current: Option<Arc<Content>>,
    enabled: bool,
    seq: u32,
    tx: Sender<Ev>,
}

impl Coordinator {
    fn send_frame(&mut self, kind: u8, seq: u32, payload: &[u8]) {
        // Bounded queue: a host that stopped reading costs no memory.
        if self.out.try_send(encode(kind, seq, payload)).is_err() {
            eprintln!("{TAG}: host is not reading the port; frame dropped");
        }
    }

    fn ack(&mut self, seq: u32, status: u8) {
        let mut p = seq.to_le_bytes().to_vec();
        p.push(status);
        self.send_frame(T_ACK, 0, &p);
    }

    /// Offer `c` on every display except `except`.
    fn broadcast(&self, c: &Arc<Content>, except: Option<&str>) {
        for (name, m) in &self.workers {
            if Some(name.as_str()) != except {
                m.send(Cmd::Own(c.clone()));
            }
        }
    }

    fn handle(&mut self, ev: Ev) -> bool {
        match ev {
            Ev::Host(f) => self.host_frame(f),
            Ev::HostGone => {
                eprintln!("{TAG}: host closed the port; exiting");
                return false;
            }
            Ev::Display(kind, name) => {
                if !self.started.contains_key(&name) {
                    self.started.insert(name.clone(), kind);
                    let tx = self.tx.clone();
                    let spawn = std::thread::Builder::new().name(format!("clip {name}"));
                    let r = match kind {
                        Kind::X11 => spawn.spawn(move || clipx11::run(name, tx)),
                        Kind::Wayland => spawn.spawn(move || clipwl::run(name, tx)),
                    };
                    if let Err(e) = r {
                        eprintln!("{TAG}: cannot start a display thread: {e}");
                    }
                }
            }
            Ev::Up(name, m) => {
                eprintln!("{TAG}: {name}: sharing this display's clipboard");
                if let Some(c) = &self.current {
                    m.send(Cmd::Own(c.clone()));
                }
                self.workers.insert(name, m);
            }
            Ev::Down(name) => {
                self.workers.remove(&name);
                self.started.remove(&name);
            }
            Ev::Guest(src, c) => {
                if self.current.as_ref().is_some_and(|cur| cur.hash == c.hash) {
                    return true; // our own content re-announced (gamescope, KWin, Klipper)
                }
                let c = Arc::new(c);
                self.current = Some(c.clone());
                self.broadcast(&c, Some(&src));
                if self.enabled {
                    self.seq = self.seq.wrapping_add(1);
                    eprintln!("{TAG}: SteamOS -> Mac #{}: {} (copied on {src})", self.seq, c.describe());
                    let (seq, p) = (self.seq, set_payload(&c));
                    self.send_frame(T_SET, seq, &p);
                } else {
                    eprintln!("{TAG}: copied on {src}: {}; sharing is off, not sent", c.describe());
                }
            }
        }
        true
    }

    fn host_frame(&mut self, f: Frame) {
        match f.kind {
            T_STATE => {
                let on = f.payload.first() == Some(&1);
                if on != self.enabled {
                    eprintln!("{TAG}: sharing {}", if on { "on" } else { "off" });
                }
                self.enabled = on;
            }
            T_SET => {
                if !self.enabled {
                    eprintln!("{TAG}: Mac -> SteamOS #{} while sharing is off: ignored", f.seq);
                    return self.ack(f.seq, ACK_REJECTED);
                }
                let Some((text, png)) = parse_set(&f.payload) else {
                    eprintln!("{TAG}: Mac -> SteamOS #{}: malformed, ignored", f.seq);
                    return self.ack(f.seq, ACK_REJECTED);
                };
                let Some(c) = capped(text, png, &format!("Mac -> SteamOS #{}", f.seq)) else {
                    return self.ack(f.seq, ACK_REJECTED);
                };
                if self.current.as_ref().is_some_and(|cur| cur.hash == c.hash) {
                    eprintln!("{TAG}: Mac -> SteamOS #{}: {} (already the clipboard)", f.seq, c.describe());
                    return self.ack(f.seq, ACK_SAME);
                }
                eprintln!("{TAG}: Mac -> SteamOS #{}: {} -> {} display(s)", f.seq, c.describe(), self.workers.len());
                let c = Arc::new(c);
                self.current = Some(c.clone());
                self.broadcast(&c, None);
                self.ack(f.seq, ACK_APPLIED);
            }
            T_ACK if f.payload.len() >= 5 => {
                let seq = u32::from_le_bytes(f.payload[..4].try_into().unwrap());
                let what = match f.payload[4] {
                    ACK_APPLIED => "on the Mac's clipboard",
                    ACK_SAME => "already the Mac's clipboard",
                    _ => "rejected by the Mac",
                };
                eprintln!("{TAG}: SteamOS -> Mac #{seq}: {what}");
            }
            _ => {}
        }
    }
}

fn open_port(path: &str) -> io::Result<std::fs::File> {
    let c = std::ffi::CString::new(path).map_err(|_| io::Error::from(io::ErrorKind::InvalidInput))?;
    let fd = unsafe { libc::open(c.as_ptr(), libc::O_RDWR | libc::O_CLOEXEC | libc::O_NOCTTY) };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(unsafe { std::fs::File::from_raw_fd(fd) })
}

pub fn run() -> i32 {
    let path = std::env::var("FX_CLIPBOARD_PORT").unwrap_or_else(|_| DEFAULT_PORT.into());
    let port = match open_port(&path) {
        Ok(p) => p,
        Err(e) => {
            // Launcher without clipboard sharing (or no permission): nothing to do.
            eprintln!("{TAG}: {path}: {e}; exiting");
            return 0;
        }
    };
    let (tx, rx) = mpsc::channel::<Ev>();
    // A paste target that closes its end early must not kill the agent (EPIPE instead).
    unsafe { libc::signal(libc::SIGPIPE, libc::SIG_IGN) };

    let mut reader = match port.try_clone() {
        Ok(r) => r,
        Err(e) => {
            eprintln!("{TAG}: {path}: {e}");
            return 1;
        }
    };
    let rtx = tx.clone();
    std::thread::spawn(move || {
        let mut dec = Decoder::default();
        let mut buf = vec![0u8; 256 * 1024];
        loop {
            match reader.read(&mut buf) {
                Ok(0) => {
                    // No host connected right now: virtio ports report EOF; wait for data.
                    std::thread::sleep(Duration::from_millis(500));
                }
                Ok(n) => {
                    for f in dec.feed(&buf[..n]) {
                        if rtx.send(Ev::Host(f)).is_err() {
                            return;
                        }
                    }
                }
                Err(e) if e.kind() == io::ErrorKind::Interrupted => {}
                Err(e) => {
                    eprintln!("{TAG}: reading {e}");
                    let _ = rtx.send(Ev::HostGone);
                    return;
                }
            }
        }
    });
    // Writer: blocking writes of whole frames, at most a few queued.
    let (out_tx, out_rx) = mpsc::sync_channel::<Vec<u8>>(4);
    let mut writer = port;
    std::thread::spawn(move || {
        for frame in out_rx {
            if let Err(e) = writer.write_all(&frame) {
                eprintln!("{TAG}: writing {e}");
            }
        }
    });

    let mut co = Coordinator {
        out: out_tx,
        workers: HashMap::new(),
        started: HashMap::new(),
        current: None,
        enabled: false,
        seq: 0,
        tx: tx.clone(),
    };
    let mut hello = PROTOCOL_VERSION.to_le_bytes().to_vec();
    hello.extend_from_slice(concat!("fx-progress-agent ", env!("CARGO_PKG_VERSION")).as_bytes());
    co.send_frame(T_HELLO, 0, &hello);

    let dtx = tx.clone();
    std::thread::spawn(move || discover(dtx));
    drop(tx);

    for ev in rx {
        if !co.handle(ev) {
            break;
        }
    }
    0
}

// MARK: display discovery

const X11_DIR: &str = "/tmp/.X11-unix";

/// `X<n>` -> `:<n>`.
pub fn x11_display(name: &str) -> Option<String> {
    let n = name.strip_prefix('X')?;
    (!n.is_empty() && n.bytes().all(|b| b.is_ascii_digit())).then(|| format!(":{n}"))
}

/// `wayland-<n>` (not its `.lock`).
pub fn is_wayland_socket(name: &str) -> bool {
    name.strip_prefix("wayland-").is_some_and(|n| !n.is_empty() && n.bytes().all(|b| b.is_ascii_digit()))
}

fn is_socket(path: &str) -> bool {
    use std::os::unix::fs::FileTypeExt;
    std::fs::metadata(path).is_ok_and(|m| m.file_type().is_socket())
}

/// Report every X socket in /tmp/.X11-unix and every `wayland-<n>` socket in
/// $XDG_RUNTIME_DIR or one directory below it (the nested Plasma session's
/// own runtime directory), now and whenever one is created (inotify, no polling).
fn discover(tx: Sender<Ev>) {
    let runtime = std::env::var("XDG_RUNTIME_DIR").unwrap_or_else(|_| format!("/run/user/{}", unsafe { libc::getuid() }));
    let ino = unsafe { libc::inotify_init1(libc::IN_CLOEXEC) };
    let mut dirs: HashMap<i32, String> = HashMap::new();
    let mask = libc::IN_CREATE | libc::IN_MOVED_TO;
    let watch = |dirs: &mut HashMap<i32, String>, dir: &str| {
        if ino < 0 {
            return;
        }
        let Ok(c) = std::ffi::CString::new(dir) else { return };
        let wd = unsafe { libc::inotify_add_watch(ino, c.as_ptr(), mask) };
        if wd >= 0 {
            dirs.insert(wd, dir.to_string());
        }
    };
    let report = |dir: &str, name: &str| -> Option<Ev> {
        if dir == X11_DIR {
            return x11_display(name).map(|d| Ev::Display(Kind::X11, d));
        }
        let path = format!("{dir}/{name}");
        (is_wayland_socket(name) && is_socket(&path)).then_some(Ev::Display(Kind::Wayland, path))
    };
    let scan = |dir: &str| -> Vec<Ev> {
        std::fs::read_dir(dir).map_or(Vec::new(), |rd| {
            rd.flatten().filter_map(|e| report(dir, &e.file_name().to_string_lossy())).collect()
        })
    };
    watch(&mut dirs, X11_DIR);
    watch(&mut dirs, &runtime);
    let mut initial = scan(X11_DIR);
    initial.extend(scan(&runtime));
    if let Ok(rd) = std::fs::read_dir(&runtime) {
        for e in rd.flatten().filter(|e| e.file_type().is_ok_and(|t| t.is_dir())) {
            let sub = format!("{runtime}/{}", e.file_name().to_string_lossy());
            watch(&mut dirs, &sub);
            initial.extend(scan(&sub));
        }
    }
    for ev in initial {
        if tx.send(ev).is_err() {
            return;
        }
    }
    if ino < 0 {
        eprintln!("{TAG}: inotify: {}; only the displays present at start are shared", io::Error::last_os_error());
        return;
    }
    let mut buf = vec![0u8; 16 * 1024];
    loop {
        let n = unsafe { libc::read(ino, buf.as_mut_ptr() as *mut libc::c_void, buf.len()) };
        if n <= 0 {
            if n < 0 && io::Error::last_os_error().kind() == io::ErrorKind::Interrupted {
                continue;
            }
            return;
        }
        let mut at = 0usize;
        while at + std::mem::size_of::<libc::inotify_event>() <= n as usize {
            let ev = unsafe { &*(buf.as_ptr().add(at) as *const libc::inotify_event) };
            let name_start = at + std::mem::size_of::<libc::inotify_event>();
            let name_bytes = &buf[name_start..name_start + ev.len as usize];
            let name = String::from_utf8_lossy(name_bytes.split(|&b| b == 0).next().unwrap_or_default()).into_owned();
            at = name_start + ev.len as usize;
            let Some(dir) = dirs.get(&ev.wd).cloned() else { continue };
            let found = if ev.mask & libc::IN_ISDIR != 0 {
                if dir != runtime || name == "doc" {
                    continue;
                }
                // A new runtime directory (the nested desktop's): watch it and look inside
                // (its socket may already exist by the time the watch is in place).
                let sub = format!("{runtime}/{name}");
                watch(&mut dirs, &sub);
                scan(&sub)
            } else {
                report(&dir, &name).into_iter().collect()
            };
            for e in found {
                if tx.send(e).is_err() {
                    return;
                }
            }
        }
    }
}

/// poll(2) on `fds` for POLLIN; `timeout` None = forever. Returns the revents.
pub fn poll_in(fds: &[RawFd], timeout: Option<Duration>) -> Vec<i16> {
    let mut p: Vec<libc::pollfd> = fds.iter().map(|&fd| libc::pollfd { fd, events: libc::POLLIN, revents: 0 }).collect();
    let ms = timeout.map_or(-1, |t| t.as_millis().min(i32::MAX as u128) as i32);
    let r = unsafe { libc::poll(p.as_mut_ptr(), p.len() as libc::nfds_t, ms) };
    if r < 0 {
        return vec![0; fds.len()];
    }
    p.iter().map(|x| x.revents).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn frame_round_trip_and_resync() {
        let c = Content::new(Some("привет 🎮".as_bytes().to_vec()), Some(vec![0x89, b'P', b'N', b'G'])).unwrap();
        let set = encode(T_SET, 7, &set_payload(&c));
        let mut stream = b"garbage FXC".to_vec();
        stream.extend_from_slice(&set);
        stream.extend_from_slice(&encode(T_STATE, 0, &[1]));
        let mut d = Decoder::default();
        // Byte by byte: partial headers and payloads.
        let mut frames = Vec::new();
        for b in &stream {
            frames.extend(d.feed(std::slice::from_ref(b)));
        }
        assert_eq!(frames.len(), 2);
        assert_eq!((frames[0].kind, frames[0].seq), (T_SET, 7));
        let (text, png) = parse_set(&frames[0].payload).unwrap();
        let back = Content::new(text, png).unwrap();
        assert_eq!(back.hash, c.hash);
        assert_eq!(back.text.as_deref().map(|v| v.as_slice()), Some("привет 🎮".as_bytes()));
        assert_eq!(frames[1], Frame { kind: T_STATE, seq: 0, payload: vec![1] });
    }

    #[test]
    fn bad_headers_are_skipped() {
        let mut bad = encode(9, 1, b"xx"); // unknown type
        bad.extend_from_slice(&encode(T_ACK, 3, &[3, 0, 0, 0, 0]));
        let frames = Decoder::default().feed(&bad);
        assert_eq!(frames.len(), 1);
        assert_eq!(frames[0].seq, 3);
    }

    #[test]
    fn content_rules() {
        assert!(Content::new(Some(vec![]), None).is_none());
        let a = Content::new(Some(b"a".to_vec()), None).unwrap();
        let b = Content::new(None, Some(b"a".to_vec())).unwrap();
        assert_ne!(a.hash, b.hash, "text and image with the same bytes differ");
        assert!(capped(Some(vec![b'x'; TEXT_MAX + 1]), None, "test").is_none());
        let only_text = capped(Some(b"t".to_vec()), Some(vec![0; IMAGE_MAX + 1]), "test").unwrap();
        assert!(only_text.png.is_none() && only_text.text.is_some());
        assert!(parse_set(&[1, 0, 3, 0]).is_none(), "truncated");
        let mut extra = set_payload(&a);
        extra.push(0);
        assert!(parse_set(&extra).is_none(), "trailing bytes");
    }

    #[test]
    fn socket_names() {
        assert_eq!(x11_display("X1").as_deref(), Some(":1"));
        assert_eq!(x11_display("X").as_deref(), None);
        assert_eq!(x11_display("X1.lock").as_deref(), None);
        assert!(is_wayland_socket("wayland-0"));
        assert!(!is_wayland_socket("wayland-0.lock"));
        assert!(!is_wayland_socket("gamescope-0"));
    }
}
