import AppKit
import Foundation

/// `--resize-selftest S`: once Steam is ready (+S seconds), resize the window through
/// 1600x1000 → fullscreen → windowed → 1280x800 with the real window APIs (so the normal
/// debounced guest-resize path runs), wait for the guest's scanout to switch to the requested
/// size, give the guest UI time to reflow, and dump frames for each step.
enum ResizeSelfTest {
    typealias Dump = (_ path: String, _ done: (() -> Void)?) -> Void

    static func start(after delay: Double, window wc: WindowController, display: DisplayBackend,
                      progress: BootProgress, base: String, dump: @escaping Dump) {
        // Wait for `ready` (polling keeps BootProgress' callbacks untouched).
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { timer in
            guard progress.state.phase == .running else { return }
            timer.invalidate()
            log("resize selftest: Steam ready, starting in \(Int(delay)) s")
            let t = Thread { run(after: delay, wc: wc, display: display, base: base, dump: dump) }
            t.name = "resize-selftest"
            t.start()
        }
    }

    private static func run(after delay: Double, wc: WindowController, display: DisplayBackend, base: String, dump: @escaping Dump) {
        Thread.sleep(forTimeInterval: delay)
        let steps: [(String, () -> Void)] = [
            ("1600x1000", { wc.window.setContentSize(NSSize(width: 1600, height: 1000)) }),
            ("fullscreen", { wc.window.toggleFullScreen(nil) }),
            ("windowed", { wc.window.toggleFullScreen(nil) }),
            ("1280x800", { wc.window.setContentSize(NSSize(width: 1280, height: 800)) }),
        ]
        var failures = 0
        for (i, (name, action)) in steps.enumerated() {
            log("resize selftest: step \(i + 1) \(name)")
            DispatchQueue.main.sync(execute: action)
            // Fullscreen animations take ~0.7 s; then debounce + guest modeset.
            let started = Date()
            var want = DispatchQueue.main.sync { wc.guestSizeForWindow() }
            var reached = false
            while Date().timeIntervalSince(started) < 25 {
                Thread.sleep(forTimeInterval: 0.1)
                want = DispatchQueue.main.sync { wc.guestSizeForWindow() }
                if let g = display.scanouts[0].geometry, g.width == want.0, g.height == want.1 {
                    reached = true
                    break
                }
            }
            let window = DispatchQueue.main.sync { wc.view.bounds.size }
            if reached {
                log("resize selftest: step \(i + 1) \(name): window \(Int(window.width))x\(Int(window.height)) pt → guest scanout"
                    + " \(want.0)x\(want.1) after \(String(format: "%.2f", Date().timeIntervalSince(started))) s")
            } else {
                failures += 1
                let g = display.scanouts[0].geometry.map { "\($0.width)x\($0.height)" } ?? "none"
                log("resize selftest: FAIL step \(i + 1) \(name): guest scanout \(g), wanted \(want.0)x\(want.1)")
            }
            // Steam's webhelper GPU process restarts after a mode switch (MoltenVK "cannot reserve
            // 'buffer' resource location" — not resize-specific); wait until the guest shows a
            // non-black picture again (max 90 s), then let it settle.
            let repaintStart = Date()
            while Date().timeIntervalSince(repaintStart) < 90 && meanBrightness(display) < 12 {
                Thread.sleep(forTimeInterval: 0.5)
            }
            log("resize selftest: step \(i + 1) \(name): picture after \(String(format: "%.1f", Date().timeIntervalSince(repaintStart))) s"
                + " (mean brightness \(Int(meanBrightness(display))))")
            Thread.sleep(forTimeInterval: 3)
            let sem = DispatchSemaphore(value: 0)
            DispatchQueue.main.async { dump("\(base)-resize-\(i + 1)-\(name).png") { sem.signal() } }
            _ = sem.wait(timeout: .now() + 10)
        }
        log("resize selftest: \(failures == 0 ? "PASS" : "FAIL (\(failures) steps)")")
    }

    /// Mean of (R+G+B)/3 over a sparse grid of the last presented frame (0 = black / no frame).
    static func meanBrightness(_ display: DisplayBackend) -> Double {
        guard let snap = display.scanouts[0].snapshot(), let off = ScanoutFormat.rgbOffsets(snap.format) else { return 0 }
        var sum = 0, n = 0
        snap.data.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
            for y in stride(from: 0, to: snap.height, by: 16) {
                for x in stride(from: 0, to: snap.width, by: 16) {
                    let i = (y * snap.width + x) * 4
                    sum += Int(p[i + off.r]) + Int(p[i + off.g]) + Int(p[i + off.b])
                    n += 3
                }
            }
        }
        return n == 0 ? 0 : Double(sum) / Double(n)
    }
}
