//! Tail of `~/.local/share/Steam/logs/bootstrap_log.txt` (the Steam client
//! bootstrapper/updater log).
//!
//! - The file may not exist yet (first boot: Steam is unpacked from
//!   /usr/lib/steam/steam.tar.zst by steam.service a moment later): polled.
//! - It is appended across boots. On first discovery only lines stamped at or
//!   after this boot (minus a small margin) are used, so an old session's
//!   "Downloading update" never shows up again.
//! - Rotation (new inode) or truncation (size < read offset): the new file is
//!   entirely new content and is read from the start.
//! - Partial lines are kept until their newline arrives.

use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::os::unix::fs::MetadataExt;

pub struct Line {
    /// Unix time of the "[YYYY-MM-DD HH:MM:SS]" stamp (local time), if any.
    pub ts: Option<i64>,
    /// Message text after the stamp.
    pub text: String,
}

pub struct Tailer {
    path: String,
    /// Lines stamped before this are ignored on the first discovery.
    not_before: i64,
    file: Option<File>,
    ino: u64,
    offset: u64,
    partial: Vec<u8>,
    discovered: bool,
}

impl Tailer {
    pub fn new(path: String, not_before: i64) -> Tailer {
        Tailer {
            path,
            not_before,
            file: None,
            ino: 0,
            offset: 0,
            partial: Vec::new(),
            discovered: false,
        }
    }

    /// New complete lines since the last call.
    pub fn poll(&mut self) -> Vec<Line> {
        let meta = match std::fs::metadata(&self.path) {
            Ok(m) => m,
            Err(_) => {
                self.file = None;
                return Vec::new();
            }
        };
        let reopen = self.file.is_none() || meta.ino() != self.ino || meta.size() < self.offset;
        let mut filter_old = false;
        if reopen {
            match File::open(&self.path) {
                Ok(f) => {
                    self.file = Some(f);
                    self.ino = meta.ino();
                    self.offset = 0;
                    self.partial.clear();
                    filter_old = !self.discovered;
                    self.discovered = true;
                }
                Err(_) => return Vec::new(),
            }
        }
        let file = self.file.as_mut().unwrap();
        if file.seek(SeekFrom::Start(self.offset)).is_err() {
            self.file = None;
            return Vec::new();
        }
        let mut buf = Vec::new();
        if file.read_to_end(&mut buf).is_err() {
            self.file = None;
            return Vec::new();
        }
        self.offset += buf.len() as u64;
        self.partial.extend_from_slice(&buf);

        let mut out = Vec::new();
        let mut start = 0;
        while let Some(nl) = self.partial[start..].iter().position(|&b| b == b'\n') {
            let raw = String::from_utf8_lossy(&self.partial[start..start + nl]).into_owned();
            start += nl + 1;
            let line = parse_line(raw.trim_end_matches('\r'));
            if line.text.is_empty() {
                continue;
            }
            if filter_old {
                match line.ts {
                    Some(t) if t >= self.not_before => filter_old = false,
                    _ => continue,
                }
            }
            out.push(line);
        }
        self.partial.drain(..start);
        out
    }
}

fn parse_line(raw: &str) -> Line {
    // "[2026-10-03 13:57:47] Downloading update (12,514 of 662,547 KB)..."
    if raw.len() >= 22
        && raw.as_bytes()[0] == b'['
        && raw.as_bytes()[20] == b']'
        && raw.is_char_boundary(22)
    {
        let ts = parse_local_time(&raw[1..20]);
        return Line {
            ts,
            text: raw[22..].trim().to_string(),
        };
    }
    Line {
        ts: None,
        text: raw.trim().to_string(),
    }
}

/// "YYYY-MM-DD HH:MM:SS" in the guest's local time zone -> Unix time
/// (musl's mktime reads TZ or /etc/localtime).
fn parse_local_time(s: &str) -> Option<i64> {
    let b = s.as_bytes();
    if b.len() != 19
        || b[4] != b'-'
        || b[7] != b'-'
        || b[10] != b' '
        || b[13] != b':'
        || b[16] != b':'
    {
        return None;
    }
    let num = |r: std::ops::Range<usize>| s.get(r)?.parse::<i32>().ok();
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    tm.tm_year = num(0..4)? - 1900;
    tm.tm_mon = num(5..7)? - 1;
    tm.tm_mday = num(8..10)?;
    tm.tm_hour = num(11..13)?;
    tm.tm_min = num(14..16)?;
    tm.tm_sec = num(17..19)?;
    tm.tm_isdst = -1;
    let t = unsafe { libc::mktime(&mut tm) };
    if t == -1 {
        None
    } else {
        Some(t as i64)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stamped_line() {
        let l = parse_line("[2026-10-03 13:57:45] Verifying installation...");
        assert!(l.ts.is_some());
        assert_eq!(l.text, "Verifying installation...");
    }
}
