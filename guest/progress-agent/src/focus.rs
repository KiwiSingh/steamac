//! Focus reporter: which client gamescope shows (Steam UI or a game), for the
//! launcher's mouse handling (pointer grab while a game has focus).
//!
//! gamescope publishes the focused app id as GAMESCOPE_FOCUSED_APP (CARDINAL)
//! on the root window of its Xwayland (:0). 0 = nothing / startup, 769 = the
//! Steam client UI; anything else is a game's Steam app id. The watcher selects
//! PropertyChange on the root window, so it only wakes when that changes.
//!
//! Messages (line protocol, see main.rs): `focus steam` | `focus game <appid>`.

use std::os::fd::{AsRawFd, RawFd};
use std::time::{Duration, Instant};
use x11rb::connection::Connection;
use x11rb::protocol::xproto::{AtomEnum, ChangeWindowAttributesAux, ConnectionExt, EventMask, Window};
use x11rb::protocol::Event;
use x11rb::rust_connection::RustConnection;

use crate::port::Port;

const STEAM_UI_APPID: u32 = 769;

struct Conn {
    conn: RustConnection,
    root: Window,
    atom: u32,
}

pub struct Focus {
    conn: Option<Conn>,
    next_connect: Instant,
    /// Last message sent (to report only changes).
    last: Option<String>,
}

impl Focus {
    pub fn new() -> Focus {
        Focus { conn: None, next_connect: Instant::now(), last: None }
    }

    /// X connection fd to poll on, if connected.
    pub fn fd(&self) -> Option<RawFd> {
        self.conn.as_ref().map(|c| c.conn.stream().as_raw_fd())
    }

    pub fn connected(&self) -> bool {
        self.conn.is_some()
    }

    /// Connect if needed (rate limited to 1/s), drain pending X events and send
    /// `focus ...` when the focused app changed. `force` resends the current
    /// value even if unchanged (after `ready`, after the port was opened).
    pub fn pump(&mut self, port: &mut Port, force: bool) {
        let mut force = force;
        if self.conn.is_none() {
            if Instant::now() < self.next_connect {
                return;
            }
            self.next_connect = Instant::now() + Duration::from_secs(1);
            match connect() {
                Some(c) => {
                    self.conn = Some(c);
                    // New X connection (gamescope (re)started): resend.
                    force = true;
                }
                None => return,
            }
        }
        let mut changed = force;
        loop {
            match self.conn.as_ref().unwrap().conn.poll_for_event() {
                Ok(Some(Event::PropertyNotify(e))) => {
                    let c = self.conn.as_ref().unwrap();
                    if e.window == c.root && e.atom == c.atom {
                        changed = true;
                    }
                }
                Ok(Some(_)) => {}
                Ok(None) => break,
                Err(_) => {
                    // Xwayland went away with the session; reconnect later.
                    self.conn = None;
                    return;
                }
            }
        }
        if changed {
            self.report(port, force);
        }
    }

    fn report(&mut self, port: &mut Port, force: bool) {
        let Some(c) = self.conn.as_ref() else { return };
        let value = c
            .conn
            .get_property(false, c.root, c.atom, AtomEnum::CARDINAL, 0, 1)
            .ok()
            .and_then(|cookie| cookie.reply().ok())
            .map(|r| r.value32().and_then(|mut v| v.next()).unwrap_or(0));
        let Some(value) = value else {
            // Connection broke: reconnect (and resend) on the next pump.
            self.conn = None;
            return;
        };
        let msg = if value == 0 || value == STEAM_UI_APPID {
            "focus steam".to_string()
        } else {
            format!("focus game {value}")
        };
        if force || self.last.as_deref() != Some(msg.as_str()) {
            port.send(&msg);
            self.last = Some(msg);
        }
    }
}

fn connect() -> Option<Conn> {
    let (conn, screen) = RustConnection::connect(None).ok()?;
    let root = conn.setup().roots.get(screen)?.root;
    let atom = conn.intern_atom(false, b"GAMESCOPE_FOCUSED_APP").ok()?.reply().ok()?.atom;
    conn.change_window_attributes(root, &ChangeWindowAttributesAux::new().event_mask(EventMask::PROPERTY_CHANGE))
        .ok()?
        .check()
        .ok()?;
    conn.flush().ok()?;
    Some(Conn { conn, root, atom })
}
