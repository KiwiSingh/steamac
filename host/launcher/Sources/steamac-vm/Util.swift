import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Launcher diagnostics go to stderr; stdout carries the guest console.
func log(_ message: String) {
    let line = "[steamac-vm] \(message)\n"
    line.withCString { p in _ = Darwin.write(STDERR_FILENO, p, strlen(p)) }
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
