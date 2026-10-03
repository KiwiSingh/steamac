import AppKit
import CKrun
import Foundation
import ImageIO

/// `--selftest-display`: drives the real krun_display_backend vtable in-process (exactly the
/// calls libkrun's GPU thread makes) with synthetic frames in every supported format, then
/// checks the PNG dump path (CPU conversion) and the Metal path (offscreen render through the
/// same renderer/texture the window uses). In window mode the frames are also on screen.
enum SelfTest {
    struct Failure: Error { let message: String }

    static func run(_ o: Options) -> Never {
        let display = DisplayBackend()
        let renderer = Renderer()
        let presenter = Presenter(display: display, renderer: renderer)
        display.sink = presenter
        let outDir = o.selftestOut ?? FileManager.default.currentDirectoryPath
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

        var wc: WindowController?
        if !o.headless {
            let app = SteamacApplication.shared
            app.setActivationPolicy(.regular)
            let w = WindowController(title: "steamac-vm display self-test", width: o.displayWidth, height: o.displayHeight,
                                     renderer: renderer, inputs: nil, mouseMode: .absolute)
            presenter.view = w.view
            w.view.metalLayer.framebufferOnly = false   // allow reading back what the window presents
            presenter.onScanoutResize = { [weak w] width, height in w?.scanoutResized(width: width, height: height) }
            w.onCloseRequest = { exit(2) }
            wc = w
            w.show()
            log("selftest: window number \(w.window.windowNumber) on \(w.window.screen?.localizedName ?? "?")"
                + " backingScale=\(w.window.backingScaleFactor) (screencapture -l\(w.window.windowNumber) out.png)")
        }

        let feeder = Thread {
            let failures = feed(display: display, presenter: presenter, renderer: renderer,
                                width: o.displayWidth, height: o.displayHeight, outDir: outDir)
            if failures.isEmpty {
                let paths = wc == nil ? "CPU PNG + Metal offscreen" : "CPU PNG + Metal offscreen + window drawable"
                log("selftest: PASS (\(ScanoutFormat.all.count) formats, \(paths)) -> \(outDir)")
            } else {
                for f in failures { log("selftest: FAIL \(f)") }
            }
            if wc != nil {
                log("selftest: holding window for 6 s")
                Thread.sleep(forTimeInterval: 6)
            }
            exit(failures.isEmpty ? 0 : 1)
        }
        feeder.name = "selftest-gpu-thread"
        feeder.start()

        if wc != nil { NSApp.run() } else { dispatchMain() }
        exit(0)
    }

    typealias RGB = (UInt8, UInt8, UInt8)

    /// Quadrants red/green/blue/white plus an optional yellow square in the center.
    static func fill(_ buf: UnsafeMutablePointer<UInt8>, width w: Int, height h: Int, format: UInt32, square: Bool) {
        let off = ScanoutFormat.rgbOffsets(format)!
        let alphaOff = 6 - off.r - off.g - off.b
        for y in 0..<h {
            for x in 0..<w {
                var c: RGB
                switch (x < w / 2, y < h / 2) {
                case (true, true): c = (255, 0, 0)
                case (false, true): c = (0, 255, 0)
                case (true, false): c = (0, 0, 255)
                case (false, false): c = (255, 255, 255)
                }
                if square && abs(x - w / 2) < 16 && abs(y - h / 2) < 16 { c = (255, 255, 0) }
                let p = buf + (y * w + x) * 4
                p[off.r] = c.0; p[off.g] = c.1; p[off.b] = c.2
                p[alphaOff] = 0   // X/A byte zero: output must still be opaque
            }
        }
    }

    static func feed(display: DisplayBackend, presenter: Presenter, renderer: Renderer,
                     width W: Int, height H: Int, outDir: String) -> [String] {
        let cb = display.makeCBackend()
        var inst: UnsafeMutableRawPointer?
        guard cb.create!(&inst, cb.create_userdata, nil) == 0 else { return ["create failed"] }
        let fb = cb.vtable.basic_framebuffer
        var failures: [String] = []

        func present(_ w: Int, _ h: Int, _ fmt: UInt32, square: Bool, damage: krun_rect?) throws {
            var ptr: UnsafeMutablePointer<UInt8>?
            var size = 0
            let id = fb.alloc_frame!(inst, 0, &ptr, &size)
            guard id >= 0, let ptr else { throw Failure(message: "alloc_frame -> \(id)") }
            guard size == w * h * 4 else { throw Failure(message: "alloc_frame size \(size) != \(w * h * 4)") }
            fill(ptr, width: w, height: h, format: fmt, square: square)
            var r = damage ?? krun_rect()
            let rc = damage == nil ? fb.present_frame!(inst, 0, UInt32(id), nil) : fb.present_frame!(inst, 0, UInt32(id), &r)
            guard rc == 0 else { throw Failure(message: "present_frame -> \(rc)") }
        }

        for (i, fmt) in ScanoutFormat.all.enumerated() {
            let name = ScanoutFormat.name(fmt)
            // Alternate sizes to exercise reconfiguration (new buffers + texture + window resize).
            let (w, h) = i % 2 == 0 ? (W, H) : (W * 3 / 4 / 2 * 2, H * 3 / 4 / 2 * 2)
            do {
                guard fb.configure_scanout!(inst, 0, UInt32(W), UInt32(H), UInt32(w), UInt32(h), fmt) == 0 else {
                    throw Failure(message: "configure_scanout")
                }
                try present(w, h, fmt, square: false, damage: nil)
                // Second frame: only the center square changed; pass just that damage rect.
                let sq = krun_rect(x: UInt32(w / 2 - 16), y: UInt32(h / 2 - 16), width: 32, height: 32)
                try present(w, h, fmt, square: true, damage: sq)

                let expect: [(Int, Int, RGB)] = [
                    (w / 4, h / 4, (255, 0, 0)), (3 * w / 4, h / 4, (0, 255, 0)),
                    (w / 4, 3 * h / 4, (0, 0, 255)), (3 * w / 4, 3 * h / 4, (255, 255, 255)),
                    (w / 2, h / 2, (255, 255, 0)),
                ]

                // CPU path: PNG dump of the last presented frame, decoded back.
                let png = "\(outDir)/selftest-\(name).png"
                try display.dumpPNG(to: png)
                let (pix, pw, _) = try decodePNG(png)
                for (x, y, c) in expect {
                    let p = (y * pw + x) * 4
                    let got: RGB = (pix[p], pix[p + 1], pix[p + 2])
                    if got != c { failures.append("\(name) PNG (\(x),\(y)) got \(got) want \(c)") }
                }

                // Metal path: same texture the window draws, rendered offscreen at 1.5x (linear, letterboxed)
                // and 2x (nearest).
                for (sx, rw, rh) in [(1.5, w * 3 / 2, h * 2), (2.0, w * 2, h * 2)] {
                    let bgra: [UInt8] = DispatchQueue.main.sync {
                        presenter.consume()
                        return renderer.renderOffscreen(width: rw, height: rh)
                    }
                    let yoff = (Double(rh) - Double(h) * sx) / 2
                    for (x, y, c) in expect {
                        let px = Int(Double(x) * sx), py = Int(yoff + Double(y) * sx)
                        let p = (py * rw + px) * 4
                        let got: RGB = (bgra[p + 2], bgra[p + 1], bgra[p])
                        if got != c { failures.append("\(name) Metal \(sx)x (\(px),\(py)) got \(got) want \(c)") }
                    }
                    if yoff >= 2 {
                        let p = (1 * rw + rw / 2) * 4
                        if bgra[p] != 0 || bgra[p + 1] != 0 || bgra[p + 2] != 0 { failures.append("\(name) Metal letterbox not black") }
                    }
                    if sx == 1.5 {
                        try PNG.write(bgrxLike: Data(bgra), width: rw, height: rh,
                                      format: UInt32(KRUN_DISPLAY_FORMAT_B8G8R8A8_UNORM), to: "\(outDir)/selftest-\(name)-metal.png")
                    }
                }

                // Window path: read back the drawable actually presented to the window's CAMetalLayer.
                if presenter.view != nil {
                    let sem = DispatchSemaphore(value: 0)
                    nonisolated(unsafe) var shot: ([UInt8], Int, Int)?
                    DispatchQueue.main.sync {
                        renderer.captureNextDraw = { bytes, dw, dh in shot = (bytes, dw, dh); sem.signal() }
                        presenter.consume()
                        presenter.view?.redraw()
                    }
                    if sem.wait(timeout: .now() + 5) == .timedOut {
                        failures.append("\(name) window drawable capture timed out")
                    } else if let (bytes, dw, dh) = shot {
                        let fit = Renderer.fit(content: CGSize(width: w, height: h), in: CGRect(x: 0, y: 0, width: dw, height: dh))
                        for (x, y, c) in expect {
                            let px = Int(fit.minX + CGFloat(x) * fit.width / CGFloat(w))
                            let py = Int(fit.minY + CGFloat(y) * fit.height / CGFloat(h))
                            let p = (py * dw + px) * 4
                            let got: RGB = (bytes[p + 2], bytes[p + 1], bytes[p])
                            if got != c { failures.append("\(name) window \(dw)x\(dh) (\(px),\(py)) got \(got) want \(c)") }
                        }
                        try PNG.write(bgrxLike: Data(bytes), width: dw, height: dh,
                                      format: UInt32(KRUN_DISPLAY_FORMAT_B8G8R8A8_UNORM), to: "\(outDir)/selftest-\(name)-window.png")
                    }
                }
                log("selftest: \(name) \(w)x\(h) ok=\(failures.isEmpty)")
            } catch let f as Failure {
                failures.append("\(name): \(f.message)")
            } catch {
                failures.append("\(name): \(error)")
            }
            Thread.sleep(forTimeInterval: 0.4)   // visible in the window
        }
        return failures
    }

    static func decodePNG(_ path: String) throws -> ([UInt8], Int, Int) {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw Failure(message: "cannot read \(path)") }
        let w = img.width, h = img.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ok = buf.withUnsafeMutableBytes { p -> Bool in
            guard let ctx = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { throw Failure(message: "decode \(path)") }
        return (buf, w, h)
    }
}
