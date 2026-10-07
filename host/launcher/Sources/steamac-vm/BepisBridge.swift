import Darwin
import Foundation

/// Host endpoint for the KiwiSingh/steamac BepisLoader bridge.
///
/// Inner transport:
///     steamac-vm <-> fx.bepis <-> fx-bepis-agent
///
/// Outer transport:
///     BepisLoader <-> /tmp/steamac-<pid>/bepis.sock
///
/// v1 deliberately proxies a tiny line protocol. The guest remains the
/// authority for protocol version and advertised capabilities.
final class BepisBridgePort {
    static let name = "fx.bepis"
    static let socketName = "bepis.sock"

    let guestOutputFd: Int32
    let guestInputFd: Int32

    private let readFd: Int32
    private let inputWriteFd: Int32

    private var listenerFd: Int32 = -1
    private var clientFd: Int32 = -1
    private var stopped = false

    private let queue = DispatchQueue(label: "es.fxgam.steamac.bepis-bridge")
    private var pendingGuest = Data()

    init() throws {
        var out: [Int32] = [0, 0]
        var inp: [Int32] = [0, 0]

        guard pipe(&out) == 0 else {
            throw OptionError("bepis output pipe: \(String(cString: strerror(errno)))")
        }

        guard pipe(&inp) == 0 else {
            Darwin.close(out[0])
            Darwin.close(out[1])
            throw OptionError("bepis input pipe: \(String(cString: strerror(errno)))")
        }

        readFd = out[0]
        guestOutputFd = out[1]
        guestInputFd = inp[0]
        inputWriteFd = inp[1]

        for fd in out + inp {
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        }
    }

    deinit {
        stop()
        for fd in [readFd, guestOutputFd, guestInputFd, inputWriteFd] {
            Darwin.close(fd)
        }
    }

    func start(runDir: String) throws {
        let path = runDir + "/" + Self.socketName

        guard path.utf8.count < 104 else {
            throw OptionError("Bepis bridge socket path is too long: \(path)")
        }

        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw OptionError("bepis socket: \(String(cString: strerror(errno)))")
        }

        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)

        let pathBytes = Array(path.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.initializeMemory(as: UInt8.self, repeating: 0)
            pathBytes.withUnsafeBytes { source in
                raw.copyBytes(from: source.prefix(raw.count))
            }
        }

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(
                    fd,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }

        guard bindResult == 0 else {
            let message = String(cString: strerror(errno))
            Darwin.close(fd)
            throw OptionError("bind \(path): \(message)")
        }

        // Supervisor.runDir itself is 0700; keep the endpoint private too.
        _ = chmod(path, S_IRUSR | S_IWUSR)

        guard listen(fd, 1) == 0 else {
            let message = String(cString: strerror(errno))
            Darwin.close(fd)
            unlink(path)
            throw OptionError("listen \(path): \(message)")
        }

        listenerFd = fd

        queue.async { [weak self] in
            self?.run(listener: fd)
        }

        queue.async { [weak self] in
            self?.readGuest()
        }

        log("Bepis bridge: \(path)")
    }

    func stop() {
        stopped = true

        if clientFd >= 0 {
            shutdown(clientFd, SHUT_RDWR)
            Darwin.close(clientFd)
            clientFd = -1
        }

        if listenerFd >= 0 {
            shutdown(listenerFd, SHUT_RDWR)
            Darwin.close(listenerFd)
            listenerFd = -1
        }
    }

    private func run(listener: Int32) {
        while !stopped {
            let fd = accept(listener, nil, nil)

            if fd < 0 {
                if errno == EINTR { continue }
                if stopped { return }
                usleep(50_000)
                continue
            }

            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)

            // One BepisLoader client at a time. Replacing a stale client is
            // preferable to leaving the bridge permanently occupied.
            if clientFd >= 0 {
                shutdown(clientFd, SHUT_RDWR)
                Darwin.close(clientFd)
            }

            clientFd = fd
            readClient(fd)

            if clientFd == fd {
                Darwin.close(fd)
                clientFd = -1
            }
        }
    }

    private func readClient(_ fd: Int32) {
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)

        while !stopped {
            let count = Darwin.read(fd, &buffer, buffer.count)

            if count == 0 { return }

            if count < 0 {
                if errno == EINTR { continue }
                return
            }

            pending.append(buffer, count: count)

            if pending.count > 16 * 1024 {
                writeClient("error request-too-large\n")
                return
            }

            while let newline = pending.firstIndex(of: 0x0A) {
                let frame = pending.prefix(upTo: newline)
                pending.removeSubrange(...newline)

                guard frame.count <= 16 * 1024 else {
                    writeClient("error request-too-large\n")
                    return
                }

                var bytes = Data(frame)
                bytes.append(0x0A)

                guard writeAll(inputWriteFd, bytes) else {
                    writeClient("error guest-unavailable\n")
                    return
                }
            }
        }
    }

    private func readGuest() {
        var buffer = [UInt8](repeating: 0, count: 4096)

        while !stopped {
            let count = Darwin.read(readFd, &buffer, buffer.count)

            if count == 0 { return }

            if count < 0 {
                if errno == EINTR { continue }
                if stopped { return }
                continue
            }

            pendingGuest.append(buffer, count: count)

            if pendingGuest.count > 64 * 1024 {
                pendingGuest.removeAll(keepingCapacity: true)
                writeClient("error guest-frame-too-large\n")
                continue
            }

            while let newline = pendingGuest.firstIndex(of: 0x0A) {
                let frame = pendingGuest.prefix(newline + 1)
                pendingGuest.removeSubrange(...newline)

                if clientFd >= 0 {
                    _ = writeAll(clientFd, Data(frame))
                }
            }
        }
    }

    private func writeClient(_ string: String) {
        guard clientFd >= 0 else { return }
        _ = writeAll(clientFd, Data(string.utf8))
    }

    private func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return true }

            var offset = 0

            while offset < raw.count {
                let count = Darwin.write(
                    fd,
                    base.advanced(by: offset),
                    raw.count - offset
                )

                if count < 0 {
                    if errno == EINTR { continue }
                    return false
                }

                if count == 0 { return false }
                offset += count
            }

            return true
        }
    }
}
