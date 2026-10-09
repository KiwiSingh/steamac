//! "Steam UI is on screen" detection over X11 (pure-Rust x11rb connection to
//! the gamescope Xwayland on $DISPLAY, normally :0; gamescope-onready runs
//! `xhost +`, $XAUTHORITY is honoured if set).
//!
//! Ready = a Steam UI window that is mapped (viewable), not override-redirect,
//! covers the whole root window and is gamescope's focused window
//! (GAMESCOPE_FOCUSED_WINDOW on the root) while the focused app is the Steam
//! UI (GAMESCOPE_FOCUSED_APP 769). gamescope publishes both properties from
//! its start, empty while nothing has the focus; only without them (another X
//! server) the focus test is skipped.
//!
//! The window title is localized ("Steam Big Picture Mode", "Режим Big
//! Picture", ...), so a window is a Steam UI window by
//!   - its owner process: _NET_WM_PID -> /proc/<pid>/comm is steamwebhelper
//!     (the CEF UI) or steam, or
//!   - its WM_CLASS (instance or class steamwebhelper / steam), or
//!   - the English title, as a last fallback.
//! Measured with xprop (Frame client and Steam Deck client, English and
//! Russian UI): the Big Picture window has _NET_WM_PID = steamwebhelper,
//! WM_CLASS "steamwebhelper", "steam", STEAM_GAME 769 and the localized title.
//! STEAM_BIGPICTURE is not evidence: the clients do not set it on their UI
//! window, but the bootstrapper's full-screen updater window (override-redirect,
//! "Steam", no pid/class, while it downloads a client) has it; gamescope
//! leaves the focus empty for that window.
//! Steam also keeps unmapped helper windows (steamwebhelper 200x200, steam
//! 10x10, ...); only a mapped one counts. The steamwebhelper process alone is
//! not "ready": it runs for 5-60 s before the UI window is drawn (main.rs uses
//! it for "Loading Steam UI").

use std::time::{Duration, Instant};
use x11rb::connection::Connection;
use x11rb::protocol::xproto::{AtomEnum, ConnectionExt, GetPropertyReply, MapState, Window};
use x11rb::rust_connection::RustConnection;

use crate::focus::STEAM_UI_APPID;

const UI_TITLE: &[u8] = b"Steam Big Picture Mode";
/// Owner processes / WM_CLASS names of the Steam client's windows.
const STEAM_NAMES: &[&str] = &["steamwebhelper", "steam"];

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum UiState {
    /// No X connection (yet).
    NoDisplay,
    /// Connected, no mapped Steam UI window.
    NoWindow,
    /// A Steam UI window is mapped but not (yet) full-screen and focused.
    Partial,
    /// Window mapped full-screen and focused.
    OnScreen,
}

struct Atoms {
    net_wm_name: u32,
    net_wm_pid: u32,
    utf8: u32,
    focused_window: u32,
    focused_app: u32,
}

struct Conn {
    conn: RustConnection,
    root: Window,
    atoms: Atoms,
}

pub struct Ui {
    conn: Option<Conn>,
    next_connect: Instant,
    /// What identified the last OnScreen window (for the journal).
    on_screen: String,
}

impl Ui {
    pub fn new() -> Ui {
        Ui {
            conn: None,
            next_connect: Instant::now(),
            on_screen: String::new(),
        }
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
        match query(self.conn.as_ref().unwrap(), &mut self.on_screen) {
            Some(s) => s,
            None => {
                // Connection broke (Xwayland restarted with the session): reconnect later.
                self.conn = None;
                UiState::NoDisplay
            }
        }
    }

    /// The window last seen OnScreen and the evidence that it is Steam's.
    pub fn on_screen_window(&self) -> &str {
        &self.on_screen
    }
}

fn connect() -> Option<Conn> {
    let (conn, screen) = RustConnection::connect(None).ok()?;
    let root = conn.setup().roots.get(screen)?.root;
    let atom = |name: &[u8]| -> Option<u32> {
        Some(conn.intern_atom(false, name).ok()?.reply().ok()?.atom)
    };
    let atoms = Atoms {
        net_wm_name: atom(b"_NET_WM_NAME")?,
        net_wm_pid: atom(b"_NET_WM_PID")?,
        utf8: atom(b"UTF8_STRING")?,
        focused_window: atom(b"GAMESCOPE_FOCUSED_WINDOW")?,
        focused_app: atom(b"GAMESCOPE_FOCUSED_APP")?,
    };
    Some(Conn { conn, root, atoms })
}

/// First CARDINAL of a property reply.
fn card(r: &GetPropertyReply) -> Option<u32> {
    r.value32().and_then(|mut v| v.next())
}

/// A root property gamescope publishes: None = not published (no gamescope),
/// Some(None) = published but empty (nothing focused).
fn published(r: Option<GetPropertyReply>) -> Option<Option<u32>> {
    let r = r?;
    (r.type_ != u32::from(AtomEnum::NONE)).then(|| card(&r))
}

/// Owner process name of a window (`/proc/<pid>/comm`). The Steam client and
/// its UI run in the session's PID namespace (pressure-vessel does not unshare
/// it), so _NET_WM_PID is a local pid.
fn comm(pid: u32) -> Option<String> {
    let c = std::fs::read_to_string(format!("/proc/{pid}/comm")).ok()?;
    Some(c.trim_end().to_string())
}

/// Why a window is a Steam UI window ("" = it is not).
fn steam_evidence(owner: Option<&str>, class: &[u8], title: &[u8]) -> String {
    let mut why = Vec::new();
    if let Some(c) = owner.filter(|c| STEAM_NAMES.contains(c)) {
        why.push(format!("owner {c}"));
    }
    let is_steam = |s: &[u8]| {
        STEAM_NAMES
            .iter()
            .any(|n| s.eq_ignore_ascii_case(n.as_bytes()))
    };
    if class.split(|&b| b == 0).any(is_steam) {
        why.push(format!(
            "WM_CLASS {}",
            String::from_utf8_lossy(class)
                .trim_end_matches('\0')
                .replace('\0', "/")
        ));
    }
    if title == UI_TITLE {
        why.push("English title".into());
    }
    why.join(", ")
}

/// Is the focus on window `w` and the Steam UI app (None = not published)?
fn focused(
    w: Window,
    focused_window: Option<Option<u32>>,
    focused_app: Option<Option<u32>>,
) -> bool {
    focused_window.map_or(true, |f| f == Some(w))
        && focused_app.map_or(true, |a| a == Some(STEAM_UI_APPID))
}

fn query(c: &Conn, on_screen: &mut String) -> Option<UiState> {
    let conn = &c.conn;
    let a = &c.atoms;
    let root_geo = conn.get_geometry(c.root).ok()?.reply().ok()?;
    let tree = conn.query_tree(c.root).ok()?.reply().ok()?;
    let root_card = |atom: u32| conn.get_property(false, c.root, atom, AtomEnum::CARDINAL, 0, 1);
    let focused_window = root_card(a.focused_window).ok()?;
    let focused_app = root_card(a.focused_app).ok()?;

    // Pipeline the requests for all top-level windows.
    let mut cookies = Vec::with_capacity(tree.children.len());
    for &w in &tree.children {
        let prop = |atom: u32, ty: u32, len: u32| conn.get_property(false, w, atom, ty, 0, len);
        cookies.push((
            w,
            conn.get_window_attributes(w).ok()?,
            prop(a.net_wm_pid, AtomEnum::CARDINAL.into(), 1).ok()?,
            prop(AtomEnum::WM_CLASS.into(), AtomEnum::STRING.into(), 64).ok()?,
            prop(a.net_wm_name, a.utf8, 64).ok()?,
            prop(AtomEnum::WM_NAME.into(), AtomEnum::ANY.into(), 64).ok()?,
        ));
    }
    let focused_window = published(focused_window.reply().ok());
    let focused_app = published(focused_app.reply().ok());

    let mut candidates = Vec::new();
    for (w, attr, pid, class, net_name, icccm_name) in cookies {
        // A window may vanish between query_tree and the replies: not fatal.
        let mapped = attr
            .reply()
            .is_ok_and(|r| r.map_state == MapState::VIEWABLE && !r.override_redirect);
        let pid = pid.reply().ok().as_ref().and_then(card);
        let class = class.reply().map(|r| r.value).unwrap_or_default();
        let net_name = net_name.reply().map(|r| r.value).unwrap_or_default();
        let icccm_name = icccm_name.reply().map(|r| r.value).unwrap_or_default();
        if !mapped {
            continue;
        }
        let title = if net_name.is_empty() {
            icccm_name
        } else {
            net_name
        };
        let why = steam_evidence(pid.and_then(comm).as_deref(), &class, &title);
        if !why.is_empty() {
            candidates.push((w, why));
        }
    }
    if candidates.is_empty() {
        return Some(UiState::NoWindow);
    }

    for (w, why) in candidates {
        if !focused(w, focused_window, focused_app) {
            continue;
        }
        let Ok(Ok(geo)) = conn.get_geometry(w).map(|c| c.reply()) else {
            continue;
        };
        if geo.width >= root_geo.width && geo.height >= root_geo.height {
            *on_screen = format!(
                "window {w:#x} {}x{} ({why}; focused app {})",
                geo.width,
                geo.height,
                focused_app
                    .flatten()
                    .map_or("-".to_string(), |v| v.to_string())
            );
            return Some(UiState::OnScreen);
        }
    }
    Some(UiState::Partial)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn evidence() {
        // Big Picture window as measured with xprop (Russian UI).
        let e = steam_evidence(
            Some("steamwebhelper"),
            b"steamwebhelper\0steam\0",
            "Режим Big Picture".as_bytes(),
        );
        assert_eq!(e, "owner steamwebhelper, WM_CLASS steamwebhelper/steam");
        assert_eq!(
            steam_evidence(None, b"steamwebhelper\0steam\0", b""),
            "WM_CLASS steamwebhelper/steam"
        );
        assert_eq!(steam_evidence(None, b"", UI_TITLE), "English title");
        // Bootstrapper updater window: no pid, no class, title "Steam".
        assert_eq!(steam_evidence(None, b"", b"Steam"), "");
        assert_eq!(
            steam_evidence(
                Some("mangoapp"),
                b"mangoapp overlay window\0mangoapp overlay window\0",
                b"x"
            ),
            ""
        );
    }

    #[test]
    fn focus() {
        let w = 0x2200035;
        // gamescope: focused window and app published.
        assert!(focused(w, Some(Some(w)), Some(Some(769))));
        assert!(!focused(w, Some(Some(w + 1)), Some(Some(769))));
        assert!(!focused(w, Some(Some(w)), Some(Some(570))));
        // Published but empty (bootstrapper updater window up): not focused.
        assert!(!focused(w, Some(None), Some(None)));
        // No gamescope: no focus test.
        assert!(focused(w, None, None));
    }
}
