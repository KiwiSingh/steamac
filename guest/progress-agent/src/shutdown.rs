//! SIGTERM handling: is the session being torn down because the system is
//! powering off / rebooting, or only because the session ends (gamescope
//! restart, SDDM relogin)?
//!
//! systemd stops user@1000.service (and thereby this unit) as part of the
//! poweroff.target / reboot.target transaction, so while we handle SIGTERM the
//! target's start job is still queued: `systemctl list-jobs` (system manager,
//! readable without privileges) names it. Every query is bounded by a hard
//! timeout so the agent never delays the shutdown it reports.

use std::io::Read;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Kind {
    Poweroff,
    Reboot,
}

impl Kind {
    pub fn word(self) -> &'static str {
        match self {
            Kind::Poweroff => "poweroff",
            Kind::Reboot => "reboot",
        }
    }
}

/// None = not a system shutdown (only the session is going away).
pub fn detect() -> Option<Kind> {
    if let Some(jobs) = run("/usr/bin/systemctl", &["list-jobs", "--no-legend", "--no-pager"], Duration::from_millis(1000)) {
        for line in jobs.lines() {
            let unit = line.split_whitespace().nth(1).unwrap_or("");
            match unit {
                "reboot.target" | "kexec.target" | "soft-reboot.target" => return Some(Kind::Reboot),
                "poweroff.target" | "halt.target" => return Some(Kind::Poweroff),
                _ => {}
            }
        }
    }
    // No target job visible (query failed/timed out, or the job already ran):
    // if the system is stopping it is a shutdown of unknown kind. Report
    // poweroff; the launcher still sees "reboot: Restarting system" on hvc0.
    match run("/usr/bin/systemctl", &["is-system-running"], Duration::from_millis(500)) {
        Some(s) if s.trim() == "stopping" => Some(Kind::Poweroff),
        _ => None,
    }
}

/// Run a command, return its stdout if it finished within `timeout`.
fn run(prog: &str, args: &[&str], timeout: Duration) -> Option<String> {
    let mut child = Command::new(prog)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    let mut stdout = child.stdout.take()?;
    // Drain stdout concurrently so a long job list can never fill the pipe.
    let reader = std::thread::spawn(move || {
        let mut s = String::new();
        let _ = stdout.read_to_string(&mut s);
        s
    });
    let deadline = Instant::now() + timeout;
    loop {
        match child.try_wait() {
            Ok(Some(_)) => break,
            Ok(None) if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(20)),
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return None;
            }
        }
    }
    reader.join().ok()
}
