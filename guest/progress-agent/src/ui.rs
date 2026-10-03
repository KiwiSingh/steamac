//! "Steam UI is on screen" detection over X11 (pure-Rust x11rb connection to
//! the gamescope Xwayland on $DISPLAY, normally :0; gamescope-onready runs
//! `xhost +`, $XAUTHORITY is honoured if set).
//!
//! Ready = a top-level window named "Steam Big Picture Mode" that is mapped
//! (viewable), covers the whole root window and - when gamescope publishes it -
//! is gamescope's focused window (GAMESCOPE_FOCUSED_WINDOW on the root).

use std::time::{Duration, Instant};
use x11rb::connection::Connection;
use x11rb::protocol::xproto::{AtomEnum, ConnectionExt, MapState, Window};
use x11rb::rust_connection::RustConnection;

const UI_TITLE: &[u8] = b"Steam Big Picture Mode";

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum UiState {
    /// No X connection (yet).
    NoDisplay,
    /// Connected, no Steam UI window.
    NoWindow,
    /// Window exists but is not yet mapped full-screen / focused.
    Partial,
    /// Window mapped full-screen and focused.
    OnScreen,
}

struct Conn {
    conn: RustConnection,
    root: Window,
    net_wm_name: u32,
    utf8: u32,
    focused: u32,
}

pub struct Ui {
    conn: Option<Conn>,
    next_connect: Instant,
}

impl Ui {
    pub fn new() -> Ui {
        Ui { conn: None, next_connect: Instant::now() }
    }

    pub fn check(&mut self) -> UiState {
        if self.conn.is_none() {
            if Instant::now() < self.next_connect {
                return UiState::NoDisplay;
            }
            self.next_connect = Instant::now() + Duration::from_secs(1);
            match connect() {
                Some(c) => self.conn = Some(c),
                None => return UiState::NoDisplay,
            }
        }
        match query(self.conn.as_ref().unwrap()) {
            Some(s) => s,
            None => {
                // Connection broke (Xwayland restarted with the session): reconnect later.
                self.conn = None;
                UiState::NoDisplay
            }
        }
    }
}

fn connect() -> Option<Conn> {
    let (conn, screen) = RustConnection::connect(None).ok()?;
    let root = conn.setup().roots.get(screen)?.root;
    let atom = |name: &[u8]| -> Option<u32> { Some(conn.intern_atom(false, name).ok()?.reply().ok()?.atom) };
    let net_wm_name = atom(b"_NET_WM_NAME")?;
    let utf8 = atom(b"UTF8_STRING")?;
    let focused = atom(b"GAMESCOPE_FOCUSED_WINDOW")?;
    Some(Conn { conn, root, net_wm_name, utf8, focused })
}

fn query(c: &Conn) -> Option<UiState> {
    let conn = &c.conn;
    let root_geo = conn.get_geometry(c.root).ok()?.reply().ok()?;
    let tree = conn.query_tree(c.root).ok()?.reply().ok()?;

    // Pipeline the name requests for all top-level windows.
    let mut cookies = Vec::with_capacity(tree.children.len());
    for &w in &tree.children {
        let net = conn.get_property(false, w, c.net_wm_name, c.utf8, 0, 64).ok()?;
        let icccm = conn.get_property(false, w, AtomEnum::WM_NAME, AtomEnum::STRING, 0, 64).ok()?;
        cookies.push((w, net, icccm));
    }
    let mut candidates = Vec::new();
    for (w, net, icccm) in cookies {
        // A window may vanish between query_tree and get_property: not fatal.
        let net = net.reply().ok().map(|r| r.value).unwrap_or_default();
        let icccm = icccm.reply().ok().map(|r| r.value).unwrap_or_default();
        if net == UI_TITLE || icccm == UI_TITLE {
            candidates.push(w);
        }
    }
    if candidates.is_empty() {
        return Some(UiState::NoWindow);
    }

    let focused = conn
        .get_property(false, c.root, c.focused, AtomEnum::CARDINAL, 0, 1)
        .ok()?
        .reply()
        .ok()
        .and_then(|r| r.value32().and_then(|mut v| v.next()));

    for w in candidates {
        let Ok(attr_cookie) = conn.get_window_attributes(w) else { continue };
        let Ok(geo_cookie) = conn.get_geometry(w) else { continue };
        let (Ok(attr), Ok(geo)) = (attr_cookie.reply(), geo_cookie.reply()) else { continue };
        let viewable = attr.map_state == MapState::VIEWABLE;
        let fullscreen = geo.width >= root_geo.width && geo.height >= root_geo.height;
        let is_focused = focused.map_or(true, |f| f == w);
        if viewable && fullscreen && is_focused {
            return Some(UiState::OnScreen);
        }
    }
    Some(UiState::Partial)
}
