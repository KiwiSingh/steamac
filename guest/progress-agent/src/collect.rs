//! Log bundle for the launcher's "Report a Problem" (host -> guest request on
//! the same fx.progress port):
//!
//!   host:  collect-logs <id>
//!   guest: logs-begin <id> <size>     size of the tar.gz in bytes
//!          logs <id> <base64>         CHUNK bytes per line
//!          logs-end <id> <sha256>     hex digest of the whole tar.gz
//!          logs-failed <id> <reason>  instead, when nothing could be packed
//!
//! Gathered in a worker thread as the session user, with whatever that user
//! can read: this boot's journal, coredumps, dmesg, OS/layer release, Steam
//! client logs (tails), Proton logs. Steam IDs, Steam account and persona
//! names and email addresses are replaced where recognisable before anything
//! is written. Packed with tar/gzip under /tmp and removed right after.

use std::os::fd::RawFd;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::mpsc;
use std::time::Duration;

use crate::codec;
use crate::port::Port;

/// Raw bytes per `logs` line (8192 base64 characters; the launcher splits
/// lines at 16 KiB).
const CHUNK: usize = 6144;
/// Whole transfer must leave the port within this time (the launcher waits 20 s
/// in total for the bundle).
const SEND_TIMEOUT: Duration = Duration::from_secs(10);
const JOURNAL_LINES: &str = "5000";
const STEAM_LOGS: &[&str] = &[
    "console_log.txt",
    "stderr.txt",
    "bootstrap_log.txt",
    "compat_log.txt",
    "connection_log.txt",
    "webhelper.txt",
    "cef_log.txt",
    "shader_log.txt",
];
const STEAM_LOG_TAIL: usize = 512 * 1024;
const PROTON_LOG_TAIL: usize = 1024 * 1024;

type Done = (String, Result<Vec<u8>, String>);

pub struct Collector {
    pending: Option<mpsc::Receiver<Done>>,
    wake_r: RawFd,
    wake_w: RawFd,
}

impl Collector {
    pub fn new() -> Collector {
        let mut fds = [-1; 2];
        if unsafe { libc::pipe2(fds.as_mut_ptr(), libc::O_NONBLOCK | libc::O_CLOEXEC) } < 0 {
            fds = [-1, -1];
        }
        Collector { pending: None, wake_r: fds[0], wake_w: fds[1] }
    }

    /// Readable when a bundle is ready (for the idle loop's ppoll set).
    pub fn wake_fd(&self) -> RawFd {
        self.wake_r
    }

    /// Host request `collect-logs <id>` (dispatched by main.rs): start
    /// gathering in a worker thread; the bundle goes out from `pump`.
    pub fn request(&mut self, id: &str, port: &mut Port) {
        if id.is_empty() || id.len() > 32 || !id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-') {
            eprintln!("fx-progress: ignoring malformed collect-logs request");
            return;
        }
        if self.pending.is_some() {
            port.send(&format!("logs-failed {id} busy"));
            return;
        }
        eprintln!("fx-progress: collecting logs for the launcher (request {id})");
        let (tx, rx) = mpsc::channel();
        let (id, wake) = (id.to_string(), self.wake_w);
        std::thread::spawn(move || {
            let result = collect(&id);
            let _ = tx.send((id, result));
            unsafe { libc::write(wake, b"x".as_ptr() as *const libc::c_void, 1) };
        });
        self.pending = Some(rx);
    }

    /// Finished bundles to the port. Cheap when idle; call on every loop
    /// iteration.
    pub fn pump(&mut self, port: &mut Port) {
        let mut buf = [0u8; 64];
        while unsafe { libc::read(self.wake_r, buf.as_mut_ptr() as *mut libc::c_void, buf.len()) } > 0 {}
        let Some(rx) = &self.pending else { return };
        let done = match rx.try_recv() {
            Ok(d) => d,
            Err(mpsc::TryRecvError::Empty) => return,
            Err(mpsc::TryRecvError::Disconnected) => {
                self.pending = None;
                return;
            }
        };
        self.pending = None;
        match done {
            (id, Ok(bundle)) => {
                let mut lines = Vec::with_capacity(bundle.len() / CHUNK + 3);
                lines.push(format!("logs-begin {id} {}", bundle.len()));
                for c in bundle.chunks(CHUNK) {
                    lines.push(format!("logs {id} {}", codec::base64(c)));
                }
                lines.push(format!("logs-end {id} {}", codec::sha256_hex(&bundle)));
                let ok = port.send_bulk(&lines, SEND_TIMEOUT);
                eprintln!(
                    "fx-progress: log bundle {id}: {} bytes {}",
                    bundle.len(),
                    if ok { "sent" } else { "NOT sent (host not reading)" }
                );
            }
            (id, Err(reason)) => {
                eprintln!("fx-progress: log bundle {id} failed: {reason}");
                port.send(&format!("logs-failed {id} {reason}"));
            }
        }
    }
}

impl Drop for Collector {
    fn drop(&mut self) {
        unsafe {
            libc::close(self.wake_r);
            libc::close(self.wake_w);
        }
    }
}

// MARK: collection

fn collect(id: &str) -> Result<Vec<u8>, String> {
    let home = std::env::var("HOME").unwrap_or_else(|_| "/home/steamos".into());
    let steam = PathBuf::from(
        std::env::var("FX_PROGRESS_STEAM_ROOT").unwrap_or_else(|_| format!("{home}/.local/share/Steam")),
    );
    let base = PathBuf::from(format!("/tmp/.fx-logs-{}-{id}", std::process::id()));
    let _ = std::fs::remove_dir_all(&base);
    let dir = base.join("steamos-logs");
    std::fs::create_dir_all(&dir).map_err(|e| format!("mkdir: {e}"))?;
    let result = gather(&dir, &steam, Path::new(&home)).and_then(|_| pack(&base));
    let _ = std::fs::remove_dir_all(&base);
    result
}

fn gather(dir: &Path, steam: &Path, home: &Path) -> Result<(), String> {
    let s = Scrubber::from_steam(steam, home);
    let mut notes = vec![format!("account/persona names recognised for scrubbing: {}", s.names.len())];
    let mut out = |name: &str, args: &[&str], max: usize| {
        let note = run(dir, name, args, max, &s);
        notes.push(format!("{name}: {note}"));
    };
    out("id.txt", &["id"], 4096);
    out("journal.txt", &["journalctl", "-b", "--no-pager", "-o", "short-monotonic", "-n", JOURNAL_LINES], 6 << 20);
    out("journal-user.txt", &["journalctl", "--user", "-b", "--no-pager", "-o", "short-monotonic", "-n", "2000"], 2 << 20);
    out("coredumps.txt", &["coredumpctl", "list", "--no-pager"], 256 << 10);
    out("coredump-last.txt", &["coredumpctl", "info", "--no-pager"], 512 << 10);
    out("dmesg.txt", &["dmesg"], 2 << 20);
    out("systemctl-failed.txt", &["systemctl", "--failed", "--no-pager"], 64 << 10);
    out("systemctl-user-failed.txt", &["systemctl", "--user", "--failed", "--no-pager"], 64 << 10);
    out("uname.txt", &["uname", "-a"], 4096);
    out("df.txt", &["df", "-h"], 64 << 10);
    out("free.txt", &["free", "-m"], 4096);
    for (name, path) in [
        ("os-release.txt", "/etc/os-release"),
        ("layer-release.txt", "/usr/lib/steamac/layer-release"),
        ("cmdline.txt", "/proc/cmdline"),
    ] {
        let note = copy_tail(Path::new(path), &dir.join(name), 64 << 10, &s);
        notes.push(format!("{name}: {note}"));
    }

    let logs = steam.join("logs");
    let steam_dir = dir.join("steam");
    let _ = std::fs::create_dir_all(&steam_dir);
    let mut names: Vec<String> = STEAM_LOGS.iter().map(|n| n.to_string()).collect();
    if let Ok(rd) = std::fs::read_dir(&logs) {
        let mut ui: Vec<String> = rd
            .flatten()
            .filter_map(|e| e.file_name().into_string().ok())
            .filter(|n| n.starts_with("steamui_") && n.ends_with(".txt"))
            .collect();
        ui.sort();
        names.extend(ui);
    } else {
        notes.push(format!("steam logs: {} not readable", logs.display()));
    }
    for n in names {
        let note = copy_tail(&logs.join(&n), &steam_dir.join(&n), STEAM_LOG_TAIL, &s);
        notes.push(format!("steam/{n}: {note}"));
    }

    // Proton: PROTON_LOG=1 writes ~/steam-<appid>.log; compatdata holds the
    // Proton version / config of each prefix.
    let proton_dir = dir.join("proton");
    let _ = std::fs::create_dir_all(&proton_dir);
    let mut proton_logs = newest(home, |n| n.starts_with("steam-") && n.ends_with(".log"));
    proton_logs.truncate(5);
    for p in &proton_logs {
        let name = p.file_name().unwrap_or_default().to_string_lossy().to_string();
        let note = copy_tail(p, &proton_dir.join(&name), PROTON_LOG_TAIL, &s);
        notes.push(format!("proton/{name}: {note}"));
    }
    let compat = steam.join("steamapps/compatdata");
    let mut prefixes = newest(&compat, |n| n.bytes().all(|b| b.is_ascii_digit()));
    prefixes.truncate(5);
    for p in &prefixes {
        let appid = p.file_name().unwrap_or_default().to_string_lossy().to_string();
        for f in ["version", "config_info"] {
            let src = p.join(f);
            if src.exists() {
                let note = copy_tail(&src, &proton_dir.join(format!("{appid}-{f}.txt")), 16 << 10, &s);
                notes.push(format!("proton/{appid}-{f}.txt: {note}"));
            }
        }
    }
    if proton_logs.is_empty() && prefixes.is_empty() {
        notes.push("proton: no PROTON_LOG files or compatdata prefixes".into());
    }

    notes.push(String::new());
    std::fs::write(dir.join("collect-notes.txt"), notes.join("\n")).map_err(|e| format!("write notes: {e}"))
}

/// Run a command (10 s limit) and keep the tail of its scrubbed output.
fn run(dir: &Path, name: &str, args: &[&str], max: usize, s: &Scrubber) -> String {
    let out = Command::new("timeout")
        .args(["-k", "2", "10"])
        .args(args)
        .env("SYSTEMD_COLORS", "0")
        .env("SYSTEMD_PAGER", "")
        .env("LC_ALL", "C")
        .stdin(Stdio::null())
        .output();
    let out = match out {
        Ok(o) => o,
        Err(e) => return format!("not run ({e})"),
    };
    let mut text = String::from_utf8_lossy(&out.stdout).to_string();
    let err = String::from_utf8_lossy(&out.stderr);
    if !err.trim().is_empty() {
        text.push_str("\n--- stderr ---\n");
        text.push_str(&err);
    }
    let lines = out.stdout.iter().filter(|&&b| b == b'\n').count();
    let text = s.scrub(tail(&text, max));
    match std::fs::write(dir.join(name), text) {
        Ok(()) => format!("{lines} lines, exit {}", out.status.code().unwrap_or(-1)),
        Err(e) => format!("write failed ({e})"),
    }
}

fn copy_tail(src: &Path, dst: &Path, max: usize, s: &Scrubber) -> String {
    match std::fs::read(src) {
        Ok(data) => {
            let size = data.len();
            let text = String::from_utf8_lossy(&data);
            match std::fs::write(dst, s.scrub(tail(&text, max))) {
                Ok(()) if size > max => format!("last {} KiB of {} KiB", max >> 10, size >> 10),
                Ok(()) => format!("{size} bytes"),
                Err(e) => format!("write failed ({e})"),
            }
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => "absent".into(),
        Err(e) => format!("not readable ({e})"),
    }
}

/// Entries of `dir` whose name matches, newest first.
fn newest(dir: &Path, keep: impl Fn(&str) -> bool) -> Vec<PathBuf> {
    let Ok(rd) = std::fs::read_dir(dir) else { return Vec::new() };
    let mut v: Vec<(std::time::SystemTime, PathBuf)> = rd
        .flatten()
        .filter(|e| e.file_name().to_str().is_some_and(&keep))
        .filter_map(|e| Some((e.metadata().ok()?.modified().ok()?, e.path())))
        .collect();
    v.sort_by(|a, b| b.0.cmp(&a.0));
    v.into_iter().map(|(_, p)| p).collect()
}

/// The last `max` bytes, starting at a line boundary.
fn tail(text: &str, max: usize) -> &str {
    if text.len() <= max {
        return text;
    }
    let mut cut = text.len() - max;
    while !text.is_char_boundary(cut) {
        cut += 1;
    }
    let rest = &text[cut..];
    match rest.find('\n') {
        Some(nl) => &rest[nl + 1..],
        None => rest,
    }
}

fn pack(base: &Path) -> Result<Vec<u8>, String> {
    let out = base.join("steamos-logs.tar.gz");
    let status = Command::new("tar")
        .arg("-czf")
        .arg(&out)
        .arg("-C")
        .arg(base)
        .arg("steamos-logs")
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map_err(|e| format!("tar: {e}"))?;
    if !status.success() {
        return Err(format!("tar exited {}", status.code().unwrap_or(-1)));
    }
    std::fs::read(&out).map_err(|e| format!("read bundle: {e}"))
}

// MARK: scrubbing

/// Replaces Steam IDs (`[U:1:<n>]`, 64-bit 7656119… IDs), email addresses and
/// the Steam account / persona names this machine knows (loginusers.vdf,
/// registry.vdf AutoLoginUser).
pub struct Scrubber {
    /// (ASCII-lowercased name, replacement)
    names: Vec<(String, &'static str)>,
}

impl Scrubber {
    pub fn from_steam(steam: &Path, home: &Path) -> Scrubber {
        let mut names: Vec<(String, &'static str)> = Vec::new();
        let mut add = |v: String, what: &'static str| {
            let v = v.trim().to_ascii_lowercase();
            if v.chars().count() >= 3 && !names.iter().any(|(n, _)| *n == v) {
                names.push((v, what));
            }
        };
        if let Ok(t) = std::fs::read_to_string(steam.join("config/loginusers.vdf")) {
            for (k, v) in vdf_pairs(&t) {
                match k.as_str() {
                    "AccountName" => add(v, "<account>"),
                    "PersonaName" => add(v, "<persona>"),
                    _ => {}
                }
            }
        }
        if let Ok(t) = std::fs::read_to_string(home.join(".steam/registry.vdf")) {
            for (k, v) in vdf_pairs(&t) {
                if k == "AutoLoginUser" {
                    add(v, "<account>");
                }
            }
        }
        // Longest first: a name containing another is replaced whole.
        names.sort_by(|a, b| b.0.len().cmp(&a.0.len()));
        Scrubber { names }
    }

    #[cfg(test)]
    fn with_names(list: &[(&str, &'static str)]) -> Scrubber {
        Scrubber { names: list.iter().map(|(n, r)| (n.to_ascii_lowercase(), *r)).collect() }
    }

    pub fn scrub(&self, text: &str) -> String {
        let mut s = steam3_ids(text);
        s = steam64_ids(&s);
        s = emails(&s);
        for (name, with) in &self.names {
            s = replace_word(&s, name, with);
        }
        s
    }
}

/// `"key"   "value"` lines of a VDF text file.
fn vdf_pairs(text: &str) -> Vec<(String, String)> {
    text.lines()
        .filter_map(|l| {
            let q: Vec<&str> = l.split('"').collect();
            // ["\t\t", key, "\t\t", value, ""]
            (q.len() >= 5 && q[2].trim().is_empty()).then(|| (q[1].to_string(), q[3].to_string()))
        })
        .collect()
}

/// `[U:1:12345]` -> `[U:1:<id>]`
fn steam3_ids(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(i) = rest.find("[U:1:") {
        out.push_str(&rest[..i + 5]);
        let after = &rest[i + 5..];
        let digits = after.bytes().take_while(|b| b.is_ascii_digit()).count();
        if digits > 0 {
            out.push_str("<id>");
        }
        rest = &after[digits..];
    }
    out.push_str(rest);
    out
}

/// 17-digit SteamID64 (7656119…) -> `<steamid>`
fn steam64_ids(text: &str) -> String {
    let b = text.as_bytes();
    let mut out = String::with_capacity(text.len());
    let mut last = 0;
    let mut i = 0;
    while let Some(off) = text[i..].find("7656119") {
        let start = i + off;
        let end = start + 17;
        let digits_ok = end <= b.len() && b[start..end].iter().all(|c| c.is_ascii_digit());
        let bounded = (start == 0 || !b[start - 1].is_ascii_digit()) && (end >= b.len() || !b[end].is_ascii_digit());
        if digits_ok && bounded {
            out.push_str(&text[last..start]);
            out.push_str("<steamid>");
            last = end;
            i = end;
        } else {
            i = start + 1;
        }
    }
    out.push_str(&text[last..]);
    out
}

/// systemd unit types: `name@instance.<type>` is a unit, not an email address.
const UNIT_SUFFIXES: &[&str] =
    &["service", "socket", "target", "mount", "automount", "timer", "path", "slice", "scope", "device", "swap"];

fn emails(text: &str) -> String {
    if !text.contains('@') {
        return text.to_string();
    }
    let b = text.as_bytes();
    let local = |c: u8| c.is_ascii_alphanumeric() || b"._%+-".contains(&c);
    let domain = |c: u8| c.is_ascii_alphanumeric() || c == b'.' || c == b'-';
    let mut out = String::with_capacity(text.len());
    let mut last = 0;
    for (at, _) in text.match_indices('@') {
        if at < last {
            continue;
        }
        let mut s = at;
        while s > last && local(b[s - 1]) {
            s -= 1;
        }
        let mut e = at + 1;
        while e < b.len() && domain(b[e]) {
            e += 1;
        }
        let mut host = &text[at + 1..e];
        while host.ends_with('.') || host.ends_with('-') {
            host = &host[..host.len() - 1];
        }
        // systemd instance units (getty@tty1.service, user-runtime-dir@1000.service) are not addresses.
        let tld_ok = host.rsplit_once('.').is_some_and(|(h, t)| {
            !h.is_empty() && t.len() >= 2 && t.bytes().all(|c| c.is_ascii_alphabetic()) && !UNIT_SUFFIXES.contains(&t)
        });
        if s < at && tld_ok {
            out.push_str(&text[last..s]);
            out.push_str("<email>");
            last = at + 1 + host.len();
        }
    }
    out.push_str(&text[last..]);
    out
}

/// Case-insensitive (ASCII) replacement of `name` where it is not part of a
/// longer word.
fn replace_word(text: &str, name: &str, with: &str) -> String {
    let lower = text.to_ascii_lowercase();
    let b = text.as_bytes();
    let word = |c: u8| c.is_ascii_alphanumeric() || c == b'_';
    let first_word = name.bytes().next().is_some_and(word);
    let last_word = name.bytes().last().is_some_and(word);
    let mut out = String::with_capacity(text.len());
    let mut last = 0;
    for (i, _) in lower.match_indices(name) {
        if i < last {
            continue;
        }
        let end = i + name.len();
        let ok_before = !first_word || i == 0 || !word(b[i - 1]);
        let ok_after = !last_word || end >= b.len() || !word(b[end]);
        if ok_before && ok_after && text.is_char_boundary(i) && text.is_char_boundary(end) {
            out.push_str(&text[last..i]);
            out.push_str(with);
            last = end;
        }
    }
    out.push_str(&text[last..]);
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ids() {
        assert_eq!(steam3_ids("Logged on [U:1:123456] ok [U:1:]"), "Logged on [U:1:<id>] ok [U:1:]");
        assert_eq!(steam64_ids("id 76561198000000001, x 765611980000000012"), "id <steamid>, x 765611980000000012");
    }

    #[test]
    fn mail() {
        assert_eq!(emails("from a.b+c@example.com."), "from <email>.");
        assert_eq!(emails("x@y nope, user@host.co ok"), "x@y nope, <email> ok");
        assert_eq!(emails("Started getty@tty1.service and dbus-:1.2-org@0.service"), "Started getty@tty1.service and dbus-:1.2-org@0.service");
    }

    #[test]
    fn names() {
        let s = Scrubber::with_names(&[("GamerGuy", "<account>"), ("Ninja Cat", "<persona>")]);
        assert_eq!(
            s.scrub("Logon 'gamerguy' as Ninja Cat; gamerguys stays"),
            "Logon '<account>' as <persona>; gamerguys stays"
        );
    }

    #[test]
    fn vdf() {
        let t = "\"users\"\n{\n\t\"7656\"\n\t{\n\t\t\"AccountName\"\t\t\"bob\"\n\t\t\"PersonaName\"\t\t\"Bobby B\"\n\t}\n}\n";
        let p = vdf_pairs(t);
        assert!(p.contains(&("AccountName".into(), "bob".into())));
        assert!(p.contains(&("PersonaName".into(), "Bobby B".into())));
    }

    #[test]
    fn tails() {
        assert_eq!(tail("aaa\nbbb\nccc\n", 6), "ccc\n");
        assert_eq!(tail("short", 100), "short");
    }
}
