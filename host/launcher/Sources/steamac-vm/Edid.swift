import AppKit
import CoreGraphics

/// Physical size the guest sees in the EDID (drives the UI scale of Steam/gamescope).
/// Default: the real size of the launcher window on the host monitor — the initial window
/// content size in points × the screen's mm per point (CGDisplayScreenSize / frame), so the
/// guest UI comes out at real-world size on any monitor, Retina or not. Fixed at boot.
enum EdidSize {
    struct Result {
        let widthMM: Int
        let heightMM: Int
        let source: String
    }

    /// 96 DPI-equivalent physical size for a pixel size.
    static func at96(_ w: Int, _ h: Int) -> (Int, Int) {
        (Int((Double(w) * 25.4 / 96).rounded()), Int((Double(h) * 25.4 / 96).rounded()))
    }

    static func resolve(_ o: Options) -> Result {
        let w = o.displayWidth, h = o.displayHeight
        if let (wmm, hmm) = o.displayMM {
            return Result(widthMM: wmm, heightMM: hmm, source: "--display-mm")
        }
        if let dpi = o.dpi {
            return Result(widthMM: Int((Double(w) * 25.4 / Double(dpi)).rounded()),
                          heightMM: Int((Double(h) * 25.4 / Double(dpi)).rounded()), source: "--dpi \(dpi)")
        }
        let (fw, fh) = at96(w, h)
        if o.headless {
            return Result(widthMM: fw, heightMM: fh, source: "96 dpi (headless)")
        }
        guard let screen = WindowController.targetScreen(),
              let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return Result(widthMM: fw, heightMM: fh, source: "96 dpi (no host screen)")
        }
        let mm = CGDisplayScreenSize(CGDirectDisplayID(num.uint32Value))
        let pts = screen.frame.size
        let name = screen.localizedName
        let mmPerPt = (mm.width / pts.width + mm.height / pts.height) / 2
        // Plausible: ~0.15 (dense HiDPI scaled) .. ~0.6 mm/pt (huge TV); anything else is a bogus EDID.
        guard mm.width > 0, mm.height > 0, (0.12...0.8).contains(mm.width / pts.width),
              (0.12...0.8).contains(mm.height / pts.height) else {
            return Result(widthMM: fw, heightMM: fh, source: "96 dpi (host screen \"\(name)\" reports no usable size)")
        }
        let content = WindowController.initialContentSize(width: w, height: h, screen: screen)
        return Result(widthMM: Int((content.width * mm.width / pts.width).rounded()),
                      heightMM: Int((content.height * mm.height / pts.height).rounded()),
                      source: "host screen \"\(name)\", \(String(format: "%.3f", mmPerPt)) mm/pt, window \(Int(content.width))x\(Int(content.height)) pt")
    }
}
