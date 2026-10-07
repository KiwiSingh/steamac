use std::fs::OpenOptions;
use std::io::{self, BufRead, BufReader, Write};
use std::thread;
use std::time::Duration;

const PORT: &str = "/dev/virtio-ports/fx.bepis";
const MAX_LINE: usize = 16 * 1024;

fn open_port() -> io::Result<std::fs::File> {
    OpenOptions::new().read(true).write(true).open(PORT)
}

fn send(file: &mut std::fs::File, line: &str) -> io::Result<()> {
    file.write_all(line.as_bytes())?;
    file.write_all(b"\n")?;
    file.flush()
}

fn serve(mut port: std::fs::File) -> io::Result<()> {
    let reader_file = port.try_clone()?;
    let mut reader = BufReader::new(reader_file);
    let mut line = String::new();

    loop {
        line.clear();

        let count = reader.read_line(&mut line)?;
        if count == 0 {
            return Ok(());
        }

        if count > MAX_LINE {
            send(&mut port, "error request-too-large")?;
            continue;
        }

        let request = line.trim_end_matches(['\r', '\n']);

        if request == "hello" {
            send(&mut port, "hello 1 KiwiSingh/steamac guestFileAccess")?;
            continue;
        }

        if let Some(token) = request.strip_prefix("ping ") {
            if token.is_empty() || token.len() > 256 {
                send(&mut port, "error invalid-ping")?;
            } else {
                send(&mut port, &format!("pong {token}"))?;
            }
            continue;
        }

        send(&mut port, "error unsupported-request")?;
    }
}

fn main() {
    loop {
        match open_port() {
            Ok(port) => {
                if let Err(error) = serve(port) {
                    eprintln!("fx-bepis-agent: {error}");
                }
            }
            Err(error) => {
                // The service can start before the virtio port is visible.
                eprintln!("fx-bepis-agent: waiting for {PORT}: {error}");
            }
        }

        thread::sleep(Duration::from_secs(1));
    }
}
