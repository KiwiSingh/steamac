import Darwin
import Foundation

/// libkrun ends the process with _exit() when the guest stops, so atexit handlers never run.
/// A tiny /bin/sh child blocks reading a pipe whose only writer is this process; when we die
/// (any way) it sees EOF and stops gvproxy, removes its run dir and restores the terminal.
enum Reaper {
    nonisolated(unsafe) private static var keepAlive: [AnyObject] = []

    static func start(gvproxy: Gvproxy?, restoreTerminal: Bool) throws {
        var env: [String: String] = ["PATH": "/usr/bin:/bin"]
        if let g = gvproxy, let pid = g.pid {
            env["GVPID"] = String(pid)
            env["RUNDIR"] = g.runDir
        }
        if restoreTerminal, let s = currentStty() { env["STTY"] = s }
        guard env.count > 1 else { return }

        let script = """
        trap '' INT HUP TERM QUIT TTOU
        while read -r _; do :; done
        [ -n "$GVPID" ] && kill "$GVPID" 2>/dev/null
        [ -n "$RUNDIR" ] && rm -rf "$RUNDIR"
        # TTOU ignored above: the shell may already own the terminal's foreground by now.
        [ -n "$STTY" ] && stty "$STTY" </dev/tty 2>/dev/null
        exit 0
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        p.environment = env
        let pipe = Pipe()
        p.standardInput = pipe
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        // Our write end stays open for the process lifetime; never inherited by later children.
        _ = fcntl(pipe.fileHandleForWriting.fileDescriptor, F_SETFD, FD_CLOEXEC)
        keepAlive = [p, pipe]
    }

    /// `stty -g` of the controlling terminal (before the console switches it to raw mode).
    private static func currentStty() -> String? {
        guard isatty(STDIN_FILENO) != 0 else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/stty")
        p.arguments = ["-g"]
        p.standardInput = FileHandle.standardInput
        let out = Pipe()
        p.standardOutput = out
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        let s = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (p.terminationStatus == 0 && s?.isEmpty == false) ? s : nil
    }
}
