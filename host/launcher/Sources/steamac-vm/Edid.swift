import AppKit
import CoreGraphics

/// Physical size the guest sees in the EDID (drives the DPI-aware UI scale in the guest).
/// Default: the real size of the launcher window on the host monitor — window content size in
/// points × the screen's mm per point (CGDisplayScreenSize / frame), so guest UIs come out at
/// real-world size on any monitor, Retina or not. The same mm-per-point is reused whenever the
/// window is resized (the guest display follows the window at one guest pixel per point), so the
/// DPI stays constant for the whole session.
enum EdidSize {
    struct Result {
        let widthMM: Int
        let heightMM: Int
        /// Millimetres per guest pixel (= per window point once the guest follows the window).
        let mmPerUnitX: Double
        let mmPerUnitY: Double
        let source: String

        /// Physical size for a guest display of `w`x`h` pixels at this session's DPI.
        func millimetres(_ w: Int, _ h: Int) -> (Int, Int) {
            (Int((Double(w) * mmPerUnitX).rounded()), Int((Double(h) * mmPerUnitY).rounded()))
        }
    }

    static func resolve(_ o: Options) -> Result {
        let w = o.displayWidth, h = o.displayHeight
        func perPixel(_ mmX: Double, _ mmY: Double, _ source: String) -> Result {
            Result(widthMM: Int(mmX.rounded()), heightMM: Int(mmY.rounded()),
                   mmPerUnitX: mmX / Double(w), mmPerUnitY: mmY / Double(h), source: source)
        }
        if let (wmm, hmm) = o.displayMM {
            return perPixel(Double(wmm), Double(hmm), "--display-mm")
        }
        if let dpi = o.dpi {
            return perPixel(Double(w) * 25.4 / Double(dpi), Double(h) * 25.4 / Double(dpi), "--dpi \(dpi)")
        }
        let at96 = (Double(w) * 25.4 / 96, Double(h) * 25.4 / 96)
        if o.headless {
            return perPixel(at96.0, at96.1, "96 dpi (headless)")
        }
        guard let screen = WindowController.targetScreen(),
              let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return perPixel(at96.0, at96.1, "96 dpi (no host screen)")
        }
        let mm = CGDisplayScreenSize(CGDirectDisplayID(num.uint32Value))
        let pts = screen.frame.size
        let name = screen.localizedName
        let mmPerPtX = mm.width / pts.width, mmPerPtY = mm.height / pts.height
        // Plausible: ~0.15 (dense HiDPI scaled) .. ~0.6 mm/pt (huge TV); anything else is a bogus EDID.
        guard mm.width > 0, mm.height > 0, (0.12...0.8).contains(mmPerPtX), (0.12...0.8).contains(mmPerPtY) else {
            return perPixel(at96.0, at96.1, "96 dpi (host screen \"\(name)\" reports no usable size)")
        }
        let content = WindowController.initialContentSize(width: w, height: h, screen: screen)
        return Result(widthMM: Int((content.width * mmPerPtX).rounded()), heightMM: Int((content.height * mmPerPtY).rounded()),
                      mmPerUnitX: mmPerPtX, mmPerUnitY: mmPerPtY,
                      source: "host screen \"\(name)\", \(String(format: "%.3f", (mmPerPtX + mmPerPtY) / 2)) mm/pt,"
                        + " window \(Int(content.width))x\(Int(content.height)) pt")
    }
}
