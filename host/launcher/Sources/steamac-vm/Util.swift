import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Launcher diagnostics go to stderr; stdout carries the guest console.
func log(_ message: String) {
    LogOutput.write("[steamac-vm] \(message)\n")
    CrashReporting.logged(message)
}

/// Where log() writes: stderr until a write fails with EPIPE. The VM process's stderr is the
/// supervisor's tap pipe, gone if the supervisor was killed (STEAMAC-10); SIGPIPE is ignored
/// (main.swift), so the VM process keeps running and the guest finishes its shutdown. Later
/// lines go to the app's log file (app bundle) or are dropped.
enum LogOutput {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var fd = STDERR_FILENO

    static func write(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        guard fd >= 0, !writeAll(fd, line), errno == EPIPE else { return }
        fd = AppBundle.resources == nil ? -1
            : open(AppBundle.logPath, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return }
        _ = writeAll(fd, "[steamac-vm] stderr is closed (pid \(getpid())): the launcher log continues here\n" + line)
    }

    /// False on a write error (errno set).
    private static func writeAll(_ fd: Int32, _ text: String) -> Bool {
        var text = text
        return text.withUTF8 { p in
            var off = 0
            while off < p.count {
                let n = Darwin.write(fd, p.baseAddress! + off, p.count - off)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { return false }
                off += n
            }
            return true
        }
    }
}

func fatal(_ message: String) -> Never {
    log("error: \(message)")
    exit(1)
}

enum PNG {
    /// Convert a 32bpp virtio-gpu frame to opaque RGBA and write it as PNG.
    static func write(bgrxLike data: Data, width: Int, height: Int, format: UInt32, to path: String) throws {
        guard let off = ScanoutFormat.rgbOffsets(format) else { throw OptionError("unsupported format \(format)") }
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        data.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            rgba.withUnsafeMutableBufferPointer { dst in
                for i in 0..<(width * height) {
                    let s = i * 4
                    dst[s] = src[s + off.r]
                    dst[s + 1] = src[s + off.g]
                    dst[s + 2] = src[s + off.b]
                }
            }
        }
        try write(rgba: rgba, width: width, height: height, to: path)
    }

    static func write(_ image: CGImage, to path: String) throws {
        guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw OptionError("cannot create \(path)")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw OptionError("cannot write \(path)") }
    }

    /// BGRA (Metal drawable readback) -> opaque CGImage.
    static func image(bgra: [UInt8], width: Int, height: Int) -> CGImage? {
        let provider = CGDataProvider(data: Data(bgra) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    static func write(rgba: [UInt8], width: Int, height: Int, to path: String) throws {
        let provider = CGDataProvider(data: Data(rgba) as CFData)!
        guard let image = CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { throw OptionError("CGImage creation failed") }
        let url = URL(fileURLWithPath: path)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw OptionError("cannot create \(path)")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw OptionError("cannot write \(path)") }
    }
}
