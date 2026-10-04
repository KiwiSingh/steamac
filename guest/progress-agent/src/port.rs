//! Output side: the virtio-console port `fx.progress` (one message per line).
//!
//! The port is opened `O_NONBLOCK`, so a host that is not reading (or an older
//! launcher whose port has no reader) can never stall the session: unwritten
//! bytes stay in a small bounded buffer and are retried on the next tick.

use std::ffi::CString;
use std::io;

/// Upper bound for bytes waiting for the host. Progress messages are tiny; if
/// the host stops reading this long, older messages are dropped (only the
/// newest state matters to the overlay).
const MAX_PENDING: usize = 16 * 1024;

pub struct Port {
    fd: libc::c_int,
    pending: Vec<u8>,
}

impl Port {
    pub fn open(path: &str) -> io::Result<Port> {
        let c = CString::new(path).map_err(|_| io::Error::from(io::ErrorKind::InvalidInput))?;
        // O_APPEND only matters for the regular-file test override.
        let fd = unsafe {
            libc::open(
                c.as_ptr(),
                libc::O_WRONLY | libc::O_NONBLOCK | libc::O_CLOEXEC | libc::O_NOCTTY | libc::O_APPEND,
            )
        };
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(Port { fd, pending: Vec::new() })
    }

    /// Queue one protocol line (without the trailing newline) and try to send it.
    pub fn send(&mut self, line: &str) {
        eprintln!("fx-progress: > {line}");
        self.send_quiet(line);
    }

    /// `send` without the journal line (heartbeats: one per second).
    pub fn send_quiet(&mut self, line: &str) {
        if self.pending.len() + line.len() + 1 > MAX_PENDING {
            self.pending.clear();
        }
        self.pending.extend_from_slice(line.as_bytes());
        self.pending.push(b'\n');
        self.flush();
    }

    /// Write as much of the queue as the port accepts right now; never blocks.
    pub fn flush(&mut self) {
        while !self.pending.is_empty() {
            let n = unsafe {
                libc::write(self.fd, self.pending.as_ptr() as *const libc::c_void, self.pending.len())
            };
            if n > 0 {
                self.pending.drain(..n as usize);
                continue;
            }
            let err = io::Error::last_os_error();
            if n < 0 && err.kind() == io::ErrorKind::Interrupted {
                continue;
            }
            // EAGAIN (host not reading yet) or any other error: keep the data,
            // retry on the next tick.
            break;
        }
    }

    pub fn has_pending(&self) -> bool {
        !self.pending.is_empty()
    }
}

impl Drop for Port {
    fn drop(&mut self) {
        unsafe { libc::close(self.fd) };
    }
}
