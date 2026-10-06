import Darwin
import Foundation

/// Host -> guest controller transport over the named virtio-console port
/// /dev/virtio-ports/steamac.gamepad.
///
/// This first version intentionally only proves transport. The eventual
/// GamepadBridge will send fixed-size controller-state packets here.
final class GamepadPort {
    static let name = "steamac.gamepad"

    /// Handed to libkrun: guest -> host data is written here.
    let guestOutputFd: Int32

    /// Handed to libkrun: host -> guest data is read from here.
    let guestInputFd: Int32

    private let readFd: Int32
    private let inputWriteFd: Int32

    init() throws {
        var out: [Int32] = [0, 0]
        var inp: [Int32] = [0, 0]

        guard pipe(&out) == 0 else {
            throw OptionError("gamepad output pipe: \(String(cString: strerror(errno)))")
        }

        guard pipe(&inp) == 0 else {
            Darwin.close(out[0])
            Darwin.close(out[1])
            throw OptionError("gamepad input pipe: \(String(cString: strerror(errno)))")
        }

        readFd = out[0]
        guestOutputFd = out[1]

        guestInputFd = inp[0]
        inputWriteFd = inp[1]

        for fd in out + inp {
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        }

        _ = fcntl(
            inputWriteFd,
            F_SETFL,
            fcntl(inputWriteFd, F_GETFL) | O_NONBLOCK
        )
    }

    /// Host -> guest bytes. For the transport proof we use newline-delimited
    /// text; production controller state will use fixed-size binary packets.
    @discardableResult
    func send(_ line: String) -> Bool {
        let bytes = Array((line + "\n").utf8)

        var n: Int
        repeat {
            n = Darwin.write(inputWriteFd, bytes, bytes.count)
        } while n < 0 && errno == EINTR

        return n == bytes.count
    }

    deinit {
        Darwin.close(readFd)
        Darwin.close(guestOutputFd)
        Darwin.close(guestInputFd)
        Darwin.close(inputWriteFd)
    }
}
