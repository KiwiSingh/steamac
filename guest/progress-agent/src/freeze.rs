//! Game pause while the launcher is in the background (Settings > General
//! "Pause the game"): host -> guest `freeze-game <appid>` freezes the game's
//! cgroup with the cgroup v2 freezer, `thaw-game` thaws it. Only the game:
//! the Steam client (downloads, updates) keeps running.
//!
//! The game's cgroups are the user manager's scopes Steam starts it in,
//! `app-steam-app<appid>-<n>.scope` (steam-launch-wrapper, anywhere below
//! user@<uid>.service). They are frozen through the user manager
//! (`systemctl --user freeze`, systemd >= 246; its FreezerState stays right),
//! falling back to writing the scope's `cgroup.freeze` (the session user owns
//! its delegated subtree) if systemctl fails or takes more than 2 s.
//!
//! Never leaves a game frozen: while frozen the host sends `still-background`
//! every 2 s; without one for KEEPALIVE_TIMEOUT the agent thaws by itself (the
//! launcher died / was killed). Also thawed when the focus leaves the game,
//! on agent exit (Drop) and before a new freeze.
//!
//! Replies (queued, sent by the main loop with `send_replies`): `game-frozen
//! <appid>` once a freeze took effect, `game-thawed <appid>` after any thaw
//! (host request, keepalive timeout, focus change, agent exit), so the
//! launcher's "Game paused" overlay shows the real state.

use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use crate::port::Port;

pub const KEEPALIVE_TIMEOUT: Duration = Duration::from_secs(6);

pub struct Freezer {
    appid: Option<u32>,
    frozen: Vec<PathBuf>,
    last_keepalive: Instant,
    replies: Vec<String>,
}

impl Freezer {
    pub fn new() -> Freezer {
        Freezer { appid: None, frozen: Vec::new(), last_keepalive: Instant::now(), replies: Vec::new() }
    }

    pub fn freeze(&mut self, appid: u32) {
        if self.appid == Some(appid) {
            self.last_keepalive = Instant::now();
            return;
        }
        self.thaw("new freeze request");
        let Some(root) = user_manager_cgroup() else {
            eprintln!("fx-progress: freeze {appid}: user manager cgroup not found");
            return;
        };
        let prefix = format!("app-steam-app{appid}-");
        let mut scopes = Vec::new();
        find_scopes(&root, &prefix, 0, &mut scopes);
        if scopes.is_empty() {
            eprintln!("fx-progress: freeze {appid}: no {prefix}*.scope below {}", root.display());
            return;
        }
        let mut any = false;
        for s in &scopes {
            any |= set_frozen(s, true);
        }
        // Remember the scopes even if a write failed: thaw them all later.
        self.appid = Some(appid);
        self.frozen = scopes;
        self.last_keepalive = Instant::now();
        if any {
            self.replies.push(format!("game-frozen {appid}"));
        }
    }

    pub fn keepalive(&mut self) {
        self.last_keepalive = Instant::now();
    }

    pub fn thaw(&mut self, why: &str) {
        let Some(appid) = self.appid.take() else { return };
        for s in self.frozen.drain(..) {
            // A scope whose game exited is gone: nothing to thaw.
            if s.exists() {
                set_frozen(&s, false);
            }
        }
        eprintln!("fx-progress: thawed game {appid} ({why})");
        self.replies.push(format!("game-thawed {appid}"));
    }

    /// Thaw when the host stopped sending keepalives, or the focus left the game.
    pub fn pump(&mut self, focused_game: Option<u32>) {
        let Some(appid) = self.appid else { return };
        if self.last_keepalive.elapsed() > KEEPALIVE_TIMEOUT {
            self.thaw("no keepalive from the launcher");
        } else if focused_game != Some(appid) {
            self.thaw("focus left the game");
        }
    }

    /// Queue the pending `game-frozen` / `game-thawed` replies on the port.
    pub fn send_replies(&mut self, port: &mut Port) {
        for r in self.replies.drain(..) {
            port.send(&r);
        }
    }

    /// Longest ppoll wait while frozen (keepalive deadline check).
    pub fn wait_ms(&self) -> Option<i64> {
        self.appid.map(|_| 1000)
    }
}

impl Drop for Freezer {
    fn drop(&mut self) {
        self.thaw("agent exiting");
    }
}

/// Freeze / thaw one scope: `systemctl --user freeze|thaw <unit>` (bounded to
/// 2 s), else its cgroup.freeze directly. True if either took effect.
fn set_frozen(scope: &Path, frozen: bool) -> bool {
    let verb = if frozen { "freeze" } else { "thaw" };
    let unit = scope.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    let via_systemd = std::process::Command::new("systemctl")
        .args(["--user", verb, &unit])
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()
        .ok()
        .and_then(|mut child| {
            let deadline = Instant::now() + Duration::from_secs(2);
            loop {
                match child.try_wait() {
                    Ok(Some(status)) => return Some(status.success()),
                    Ok(None) if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(20)),
                    _ => {
                        let _ = child.kill();
                        let _ = child.wait();
                        return None;
                    }
                }
            }
        })
        == Some(true);
    if via_systemd {
        eprintln!("fx-progress: {verb} {unit} (systemctl)");
        return true;
    }
    match std::fs::write(scope.join("cgroup.freeze"), if frozen { "1" } else { "0" }) {
        Ok(()) => {
            eprintln!("fx-progress: {verb} {unit} (cgroup.freeze)");
            true
        }
        Err(e) => {
            eprintln!("fx-progress: {verb} {}: {e}", scope.display());
            false
        }
    }
}

/// /sys/fs/cgroup/.../user@<uid>.service of this process (cgroup v2).
fn user_manager_cgroup() -> Option<PathBuf> {
    let own = std::fs::read_to_string("/proc/self/cgroup").ok()?;
    let path = own.lines().find_map(|l| l.strip_prefix("0::"))?;
    let mut acc = PathBuf::from("/sys/fs/cgroup");
    for part in path.trim_start_matches('/').split('/') {
        acc.push(part);
        if part.starts_with("user@") && part.ends_with(".service") {
            return Some(acc);
        }
    }
    None
}

fn find_scopes(dir: &Path, prefix: &str, depth: usize, out: &mut Vec<PathBuf>) {
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    for e in entries.flatten() {
        if !e.file_type().map_or(false, |t| t.is_dir()) {
            continue;
        }
        let name = e.file_name();
        let name = name.to_string_lossy();
        if name.starts_with(prefix) && name.ends_with(".scope") {
            out.push(e.path());
        } else if depth < 4 && (name.ends_with(".slice") || name.ends_with(".service")) {
            find_scopes(&e.path(), prefix, depth + 1, out);
        }
    }
}
