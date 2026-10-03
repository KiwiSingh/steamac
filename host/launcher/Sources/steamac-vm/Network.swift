import CKrun
import Darwin
import Foundation

/// gvproxy (containers/gvisor-tap-vsock) in vfkit unixgram mode backing virtio-net.
/// Guest MAC 5a:94:ef:e4:0c:ee is gvproxy's built-in static DHCP lease -> 192.168.127.2,
/// which is also the target of its -ssh-port forward (127.0.0.1:PORT -> guest :22).
/// Owned by the supervisor process (it outlives each VM process), restarted for every boot.
final class Gvproxy {
    static let guestMAC: [UInt8] = [0x5a, 0x94, 0xef, 0xe4, 0x0c, 0xee]
    let runDir: String
    let vfkitSocket: String
    let apiSocket: String
    private var process: Process?

    init(runDir: String) {
        self.runDir = runDir
        vfkitSocket = runDir + "/net.sock"
        apiSocket = runDir + "/api.sock"
    }

    static func locate(explicit: String?) -> String? {
        if let explicit { return explicit }
        let exe = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        let exeDir = exe.resolvingSymlinksInPath().deletingLastPathComponent().path
        let candidates = [
            exeDir + "/host/bin/gvproxy",
            "/opt/homebrew/opt/podman/libexec/podman/gvproxy",
            "/opt/homebrew/libexec/podman/gvproxy",
            "/opt/homebrew/bin/gvproxy",
            "/usr/local/bin/gvproxy",
        ] + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/gvproxy" }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func start(binary: String, sshPort: Int) throws {
        try? FileManager.default.removeItem(atPath: vfkitSocket)
        try? FileManager.default.removeItem(atPath: apiSocket)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = [
            "-listen-vfkit", "unixgram://" + vfkitSocket,
            "-listen", "unix://" + apiSocket,
            "-ssh-port", String(sshPort == 0 ? -1 : sshPort),
            "-log-file", runDir + "/gvproxy.log",
            "-pid-file", runDir + "/gvproxy.pid",
        ]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        process = p
        // Wait for the vfkit socket (libkrun connects to it when the net device is created).
        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: vfkitSocket) {
            guard p.isRunning else {
                // The run dir is removed on exit, so surface gvproxy's own error now.
                let tail = ((try? String(contentsOfFile: runDir + "/gvproxy.log", encoding: .utf8)) ?? "")
                    .split(separator: "\n").suffix(3).joined(separator: "\n  ")
                throw OptionError("gvproxy exited (status \(p.terminationStatus))"
                    + (sshPort == 0 ? "" : " — is 127.0.0.1:\(sshPort) already in use? (--ssh-port)") + "\n  \(tail)")
            }
            guard Date() < deadline else { throw OptionError("gvproxy did not create \(vfkitSocket)") }
            usleep(20_000)
        }
        log("network: gvproxy \(binary) pid \(p.processIdentifier), guest 192.168.127.2"
            + (sshPort == 0 ? "" : ", ssh -p \(sshPort) <user>@127.0.0.1") + ", API unix://\(apiSocket)")
    }

    static func attach(ctx: UInt32, socket: String) throws {
        var mac = Gvproxy.guestMAC
        let r = socket.withCString { path in
            krun_add_net_unixgram(ctx, path, -1, &mac, STEAMAC_COMPAT_NET_FEATURES, STEAMAC_NET_FLAG_VFKIT)
        }
        if r < 0 { throw KrunError(call: "krun_add_net_unixgram", code: r) }
    }

    /// Stop gvproxy and wait until it is gone (its ssh port is free again afterwards).
    func stop() {
        guard let p = process else { return }
        process = nil
        guard p.isRunning else { return }
        kill(p.processIdentifier, SIGTERM)
        for _ in 0..<100 where p.isRunning { usleep(10_000) }
        if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        p.waitUntilExit()
    }
}
