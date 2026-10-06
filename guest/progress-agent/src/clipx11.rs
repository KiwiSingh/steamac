//! Shared clipboard on one gamescope Xwayland server (see clipboard.rs).
//!
//! The worker owns CLIPBOARD with the shared content (TARGETS, UTF8_STRING,
//! text/plain;charset=utf-8, text/plain, TEXT, STRING as Latin-1, image/png;
//! INCR above 256 KiB) and watches the owner through XFixes: when another
//! client takes the selection it reads TARGETS and then the text and/or PNG
//! (INCR too) and hands them to the coordinator. Only servers with gamescope's
//! GAMESCOPE_XWAYLAND_SERVER_ID root property are used (not the nested
//! desktop's own Xwayland, which KWin bridges to Wayland: clipwl.rs).
//!
//! Everything is event-driven on the X connection and the mailbox eventfd; a
//! transfer that stalls is dropped after a few seconds.

use std::collections::HashMap;
use std::os::fd::AsRawFd;
use std::sync::mpsc::Sender;
use std::sync::Arc;
use std::time::{Duration, Instant};

use x11rb::connection::{Connection, RequestConnection};
use x11rb::errors::{ConnectError, ConnectionError, ReplyError};
use x11rb::protocol::xfixes::{ConnectionExt as _, SelectionEventMask};
use x11rb::protocol::xproto::{
    Atom, AtomEnum, ChangeWindowAttributesAux, ConnectionExt as _, CreateWindowAux, EventMask, PropMode, Property,
    SelectionNotifyEvent, SelectionRequestEvent, Window, WindowClass, SELECTION_NOTIFY_EVENT,
};
use x11rb::protocol::Event;
use x11rb::wrapper::ConnectionExt as _;
use x11rb::rust_connection::RustConnection;
use x11rb::CURRENT_TIME;

use crate::clipboard::{self, capped, mailbox, poll_in, Cmd, Content, Ev, Inbox, IMAGE_MAX, TAG, TEXT_MAX};

/// Largest property written in one piece; bigger data goes INCR.
const CHUNK: usize = 256 * 1024;
/// A fetch step or an INCR send that sees no progress this long is dropped.
const STALL: Duration = Duration::from_secs(4);
/// Connection attempts while a new server is coming up.
const CONNECT_TRIES: u32 = 10;

struct Atoms {
    clipboard: Atom,
    targets: Atom,
    multiple: Atom,
    incr: Atom,
    utf8: Atom,
    string: Atom,
    text: Atom,
    plain_utf8: Atom,
    plain: Atom,
    png: Atom,
    prop: Atom,
}

enum Stage {
    Targets,
    /// Waiting for the SelectionNotify of `target`.
    Data(Atom),
    /// INCR transfer of `target` in progress.
    Incr(Atom, Vec<u8>),
}

struct Fetch {
    stage: Stage,
    /// Targets still to read after the current one.
    queue: Vec<Atom>,
    text: Option<Vec<u8>>,
    png: Option<Vec<u8>>,
    deadline: Instant,
    /// We took over the selection meanwhile: finish the conversation, report nothing.
    discard: bool,
}

/// An INCR transfer to a requestor (keyed by requestor window + property).
struct Outgoing {
    kind: Atom,
    data: Arc<Vec<u8>>,
    at: usize,
    deadline: Instant,
}

struct Worker {
    conn: RustConnection,
    win: Window,
    a: Atoms,
    name: String,
    owned: Option<Arc<Content>>,
    /// STRING (Latin-1) rendering of the owned text, made on first request.
    latin1: Option<Arc<Vec<u8>>>,
    fetch: Option<Fetch>,
    /// The owner changed again while `fetch` ran: read once more when it ends.
    refetch: bool,
    outgoing: HashMap<(Window, Atom), Outgoing>,
    tx: Sender<Ev>,
}

enum Fail {
    /// Not one of gamescope's servers (or not reachable): give up on it.
    NotOurs(String),
    /// Try again shortly (server still starting).
    Retry(String),
}

pub fn run(display: String, tx: Sender<Ev>) {
    let mut tries = 0;
    let (conn, win, a) = loop {
        match connect(&display) {
            Ok(c) => break c,
            Err(Fail::NotOurs(why)) => {
                eprintln!("{TAG}: {display}: {why}; not shared");
                let _ = tx.send(Ev::Down(display));
                return;
            }
            Err(Fail::Retry(why)) => {
                tries += 1;
                if tries >= CONNECT_TRIES {
                    eprintln!("{TAG}: {display}: {why}; not shared");
                    let _ = tx.send(Ev::Down(display));
                    return;
                }
                std::thread::sleep(Duration::from_secs(1));
            }
        }
    };
    let (mb, inbox) = match mailbox() {
        Ok(m) => m,
        Err(e) => {
            eprintln!("{TAG}: {display}: eventfd: {e}");
            let _ = tx.send(Ev::Down(display));
            return;
        }
    };
    if tx.send(Ev::Up(display.clone(), mb)).is_err() {
        return;
    }
    let mut w = Worker {
        conn,
        win,
        a,
        name: display.clone(),
        owned: None,
        latin1: None,
        fetch: None,
        refetch: false,
        outgoing: HashMap::new(),
        tx: tx.clone(),
    };
    if let Err(e) = w.serve(&inbox) {
        eprintln!("{TAG}: {display}: connection closed ({e})");
    }
    let _ = tx.send(Ev::Down(display));
}

fn connect(display: &str) -> Result<(RustConnection, Window, Atoms), Fail> {
    let (conn, screen) = RustConnection::connect(Some(display)).map_err(|e| match e {
        // The nested desktop's own Xwayland wants KWin's cookie: not one of gamescope's servers.
        ConnectError::SetupAuthenticate(_) | ConnectError::SetupFailed(_) => {
            Fail::NotOurs("refuses the connection (not a gamescope Xwayland)".into())
        }
        e => Fail::Retry(format!("cannot connect: {e}")),
    })?;
    let setup_root = conn.setup().roots.get(screen).map(|s| (s.root, s.root_visual));
    let (root, visual) = setup_root.ok_or_else(|| Fail::NotOurs("no screen".into()))?;
    let atom = |name: &str| -> Result<Atom, Fail> {
        let r = conn.intern_atom(false, name.as_bytes()).map_err(|e| Fail::Retry(e.to_string()))?;
        Ok(r.reply().map_err(|e| Fail::Retry(e.to_string()))?.atom)
    };
    let server_id = atom("GAMESCOPE_XWAYLAND_SERVER_ID")?;
    let prop = conn
        .get_property(false, root, server_id, AtomEnum::CARDINAL, 0, 1)
        .map_err(|e| Fail::Retry(e.to_string()))?
        .reply()
        .map_err(|e| Fail::Retry(e.to_string()))?;
    if prop.value.is_empty() {
        return Err(Fail::NotOurs("not a gamescope Xwayland".into()));
    }
    let a = Atoms {
        clipboard: atom("CLIPBOARD")?,
        targets: atom("TARGETS")?,
        multiple: atom("MULTIPLE")?,
        incr: atom("INCR")?,
        utf8: atom("UTF8_STRING")?,
        string: AtomEnum::STRING.into(),
        text: atom("TEXT")?,
        plain_utf8: atom("text/plain;charset=utf-8")?,
        plain: atom("text/plain")?,
        png: atom("image/png")?,
        prop: atom("FX_CLIPBOARD")?,
    };
    let fail = |e: ConnectionError| Fail::Retry(e.to_string());
    let reply_fail = |e: ReplyError| Fail::Retry(e.to_string());
    conn.xfixes_query_version(5, 0).map_err(fail)?.reply().map_err(reply_fail)?;
    let win = conn.generate_id().map_err(|e| Fail::Retry(e.to_string()))?;
    conn.create_window(
        0,
        win,
        root,
        -10,
        -10,
        1,
        1,
        0,
        WindowClass::INPUT_ONLY,
        visual,
        &CreateWindowAux::new().override_redirect(1).event_mask(EventMask::PROPERTY_CHANGE),
    )
    .map_err(fail)?;
    conn.xfixes_select_selection_input(
        win,
        a.clipboard,
        SelectionEventMask::SET_SELECTION_OWNER
            | SelectionEventMask::SELECTION_WINDOW_DESTROY
            | SelectionEventMask::SELECTION_CLIENT_CLOSE,
    )
    .map_err(fail)?;
    conn.flush().map_err(fail)?;
    Ok((conn, win, a))
}

impl Worker {
    fn serve(&mut self, inbox: &Inbox) -> Result<(), ConnectionError> {
        let xfd = self.conn.stream().as_raw_fd();
        loop {
            let timeout = self.next_deadline().map(|d| d.saturating_duration_since(Instant::now()));
            let rev = poll_in(&[xfd, inbox.wake.fd()], timeout);
            if rev[0] & (libc::POLLHUP | libc::POLLERR) != 0 && rev[0] & libc::POLLIN == 0 {
                return Err(ConnectionError::UnknownError);
            }
            inbox.wake.drain();
            while let Ok(cmd) = inbox.rx.try_recv() {
                match cmd {
                    Cmd::Own(c) => self.own(c)?,
                }
            }
            while let Some(ev) = self.conn.poll_for_event()? {
                self.event(ev)?;
            }
            self.expire()?;
            self.conn.flush()?;
        }
    }

    fn next_deadline(&self) -> Option<Instant> {
        self.fetch.iter().map(|f| f.deadline).chain(self.outgoing.values().map(|o| o.deadline)).min()
    }

    fn expire(&mut self) -> Result<(), ConnectionError> {
        let now = Instant::now();
        if self.fetch.as_ref().is_some_and(|f| f.deadline <= now) {
            eprintln!("{TAG}: {}: the clipboard owner did not answer; change not shared", self.name);
            self.fetch = None;
            self.fetch_again()?;
        }
        self.outgoing.retain(|_, o| o.deadline > now);
        Ok(())
    }

    fn own(&mut self, c: Arc<Content>) -> Result<(), ConnectionError> {
        self.owned = Some(c);
        self.latin1 = None;
        // A read in progress is of the selection we replace now.
        if let Some(f) = self.fetch.as_mut() {
            f.discard = true;
        }
        self.refetch = false;
        self.conn.set_selection_owner(self.win, self.a.clipboard, CURRENT_TIME)?;
        Ok(())
    }

    fn event(&mut self, ev: Event) -> Result<(), ConnectionError> {
        match ev {
            Event::XfixesSelectionNotify(e) if e.selection == self.a.clipboard => {
                if e.owner != self.win && e.owner != x11rb::NONE {
                    self.start_fetch()?;
                }
            }
            Event::SelectionClear(e) if e.selection == self.a.clipboard => {
                self.owned = None;
                self.latin1 = None;
            }
            Event::SelectionRequest(e) => self.request(&e)?,
            Event::SelectionNotify(e) if e.requestor == self.win && e.selection == self.a.clipboard => {
                self.notified(e.target, e.property)?
            }
            Event::PropertyNotify(e) => {
                if e.window == self.win && e.atom == self.a.prop && e.state == Property::NEW_VALUE {
                    self.incr_chunk()?;
                } else if e.state == Property::DELETE {
                    self.send_next_chunk(e.window, e.atom)?;
                }
            }
            _ => {}
        }
        Ok(())
    }

    // MARK: reading another client's selection

    /// One conversation at a time: an owner change while one runs is read after it (replies
    /// of an abandoned conversation could otherwise be taken for the new one's).
    fn start_fetch(&mut self) -> Result<(), ConnectionError> {
        if self.fetch.is_some() {
            self.refetch = true;
            return Ok(());
        }
        self.fetch = Some(Fetch {
            stage: Stage::Targets,
            queue: Vec::new(),
            text: None,
            png: None,
            deadline: Instant::now() + STALL,
            discard: false,
        });
        self.conn.delete_property(self.win, self.a.prop)?;
        self.conn.convert_selection(self.win, self.a.clipboard, self.a.targets, self.a.prop, CURRENT_TIME)?;
        Ok(())
    }

    fn fetch_again(&mut self) -> Result<(), ConnectionError> {
        if std::mem::take(&mut self.refetch) {
            self.start_fetch()?;
        }
        Ok(())
    }

    /// SelectionNotify for our request of `target`: `property` NONE = refused.
    fn notified(&mut self, target: Atom, property: Atom) -> Result<(), ConnectionError> {
        let Some(f) = self.fetch.as_mut() else { return Ok(()) };
        let expected = match f.stage {
            Stage::Targets => self.a.targets,
            Stage::Data(t) => t,
            Stage::Incr(..) => return Ok(()),
        };
        if target != expected {
            return Ok(()); // a late answer to a conversation given up on
        }
        f.deadline = Instant::now() + STALL;
        match f.stage {
            Stage::Targets => {
                let targets = if property == x11rb::NONE {
                    Vec::new()
                } else {
                    let r = self.conn.get_property(true, self.win, self.a.prop, AtomEnum::ANY, 0, 4096)?.reply();
                    r.ok().and_then(|r| r.value32().map(|v| v.collect::<Vec<u32>>())).unwrap_or_default()
                };
                // No TARGETS support: just try UTF8_STRING.
                let targets = if targets.is_empty() { vec![self.a.utf8] } else { targets };
                let a = &self.a;
                let text = [a.utf8, a.plain_utf8, a.string, a.plain].into_iter().find(|t| targets.contains(t));
                f.queue = text.into_iter().chain(targets.contains(&a.png).then_some(a.png)).collect();
                self.next_target()
            }
            Stage::Data(target) => {
                if property == x11rb::NONE {
                    return self.next_target();
                }
                let head = self.conn.get_property(false, self.win, self.a.prop, AtomEnum::ANY, 0, 0)?.reply();
                let Ok(head) = head else { return self.next_target() };
                if head.type_ == self.a.incr {
                    // Deleting the property starts the transfer.
                    self.conn.delete_property(self.win, self.a.prop)?;
                    f.stage = Stage::Incr(target, Vec::new());
                    return Ok(());
                }
                let cap = if target == self.a.png { IMAGE_MAX } else { TEXT_MAX };
                if head.bytes_after as usize > cap {
                    self.too_large(target, head.bytes_after as usize);
                    self.conn.delete_property(self.win, self.a.prop)?;
                    return self.next_target();
                }
                let r = self.conn.get_property(true, self.win, self.a.prop, AtomEnum::ANY, 0, u32::MAX / 4)?.reply();
                if let Ok(r) = r {
                    self.store(target, r.type_, r.value);
                }
                self.next_target()
            }
            Stage::Incr(..) => Ok(()),
        }
    }

    fn incr_chunk(&mut self) -> Result<(), ConnectionError> {
        let Some(Fetch { stage: Stage::Incr(target, _), .. }) = self.fetch else { return Ok(()) };
        let r = self.conn.get_property(true, self.win, self.a.prop, AtomEnum::ANY, 0, u32::MAX / 4)?.reply();
        let Ok(r) = r else {
            self.fetch = None;
            return self.fetch_again();
        };
        let cap = if target == self.a.png { IMAGE_MAX } else { TEXT_MAX };
        let f = self.fetch.as_mut().unwrap();
        f.deadline = Instant::now() + STALL;
        let Stage::Incr(_, buf) = &mut f.stage else { return Ok(()) };
        if r.value.is_empty() {
            let data = std::mem::take(buf);
            self.store(target, r.type_, data);
            return self.next_target();
        }
        buf.extend_from_slice(&r.value);
        if buf.len() > cap {
            let n = buf.len();
            self.too_large(target, n);
            // Abandon this target; the owner's INCR times out on its side.
            return self.next_target();
        }
        Ok(())
    }

    fn too_large(&self, target: Atom, n: usize) {
        let (what, cap) = if target == self.a.png { ("image", IMAGE_MAX) } else { ("text", TEXT_MAX) };
        eprintln!(
            "{TAG}: {}: copied {what} is larger than the {} limit ({}+): not shared",
            self.name,
            clipboard::size(cap),
            clipboard::size(n)
        );
    }

    fn store(&mut self, target: Atom, kind: Atom, data: Vec<u8>) {
        let Some(f) = self.fetch.as_mut() else { return };
        if target == self.a.png {
            f.png = Some(data);
        } else if kind == self.a.string {
            // ICCCM STRING is Latin-1.
            f.text = Some(data.iter().map(|&b| b as char).collect::<String>().into_bytes());
        } else {
            f.text = Some(String::from_utf8_lossy(&data).into_owned().into_bytes());
        }
    }

    fn next_target(&mut self) -> Result<(), ConnectionError> {
        let Some(f) = self.fetch.as_mut() else { return Ok(()) };
        if f.queue.is_empty() {
            let f = self.fetch.take().unwrap();
            if !f.discard {
                if let Some(c) = capped(f.text, f.png, &self.name) {
                    let _ = self.tx.send(Ev::Guest(self.name.clone(), c));
                }
            }
            return self.fetch_again();
        }
        let target = f.queue.remove(0);
        f.stage = Stage::Data(target);
        f.deadline = Instant::now() + STALL;
        self.conn.convert_selection(self.win, self.a.clipboard, target, self.a.prop, CURRENT_TIME)?;
        Ok(())
    }

    // MARK: serving our content

    fn request(&mut self, e: &SelectionRequestEvent) -> Result<(), ConnectionError> {
        // Obsolete clients send property None: use the target as the property.
        let property = if e.property == x11rb::NONE { e.target } else { e.property };
        let answered = self.answer(e, property)?;
        let notify = SelectionNotifyEvent {
            response_type: SELECTION_NOTIFY_EVENT,
            sequence: 0,
            time: e.time,
            requestor: e.requestor,
            selection: e.selection,
            target: e.target,
            property: if answered { property } else { x11rb::NONE },
        };
        self.conn.send_event(false, e.requestor, EventMask::NO_EVENT, notify)?;
        Ok(())
    }

    /// Write the requested data to the requestor's property; false = refuse.
    fn answer(&mut self, e: &SelectionRequestEvent, property: Atom) -> Result<bool, ConnectionError> {
        let Some(c) = self.owned.clone() else { return Ok(false) };
        if e.selection != self.a.clipboard || e.target == self.a.multiple {
            return Ok(false);
        }
        let a = &self.a;
        let text_targets = [a.utf8, a.plain_utf8, a.plain, a.text, a.string];
        if e.target == a.targets {
            let mut list = vec![a.targets];
            if c.text.is_some() {
                list.extend(text_targets);
            }
            if c.png.is_some() {
                list.push(a.png);
            }
            self.conn.change_property32(PropMode::REPLACE, e.requestor, property, AtomEnum::ATOM, &list)?;
            return Ok(true);
        }
        let (kind, data) = if e.target == a.png {
            match &c.png {
                Some(p) => (a.png, p.clone()),
                None => return Ok(false),
            }
        } else if text_targets.contains(&e.target) {
            let Some(t) = &c.text else { return Ok(false) };
            if e.target == a.string {
                let l1 = self.latin1.get_or_insert_with(|| {
                    let s = String::from_utf8_lossy(t);
                    Arc::new(s.chars().map(|ch| if (ch as u32) < 256 { ch as u8 } else { b'?' }).collect())
                });
                (a.string, l1.clone())
            } else {
                // TEXT is answered as UTF8_STRING (any type may answer TEXT).
                (if e.target == a.text { a.utf8 } else { e.target }, t.clone())
            }
        } else {
            return Ok(false);
        };
        let chunk = CHUNK.min(self.conn.maximum_request_bytes().saturating_sub(1024));
        if data.len() <= chunk {
            self.conn.change_property8(PropMode::REPLACE, e.requestor, property, kind, &data)?;
        } else {
            // INCR: announce the size, then one chunk per PropertyNotify(Delete).
            self.conn.change_window_attributes(
                e.requestor,
                &ChangeWindowAttributesAux::new().event_mask(EventMask::PROPERTY_CHANGE),
            )?;
            self.conn.change_property32(PropMode::REPLACE, e.requestor, property, self.a.incr, &[data.len() as u32])?;
            self.outgoing
                .insert((e.requestor, property), Outgoing { kind, data, at: 0, deadline: Instant::now() + STALL });
        }
        Ok(true)
    }

    fn send_next_chunk(&mut self, window: Window, property: Atom) -> Result<(), ConnectionError> {
        let Some(o) = self.outgoing.get_mut(&(window, property)) else { return Ok(()) };
        let chunk = CHUNK.min(self.conn.maximum_request_bytes().saturating_sub(1024));
        let end = (o.at + chunk).min(o.data.len());
        let piece = &o.data[o.at..end];
        // The last, zero-length piece ends the transfer.
        self.conn.change_property8(PropMode::REPLACE, window, property, o.kind, piece)?;
        if piece.is_empty() {
            self.outgoing.remove(&(window, property));
        } else {
            o.at = end;
            o.deadline = Instant::now() + STALL;
        }
        Ok(())
    }
}
