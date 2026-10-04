import AppKit

/// `--selftest-settings [--selftest-out DIR]`: open the Settings window without a VM, write
/// DIR/settings-<tab>.png for every tab (command-line overrides of this run are shown as in a
/// real run), then DIR/settings-create-disk.png of the "Create New Disk…" window, and check that
/// each capture has content.
enum SettingsSelfTest {
    static func run(_ o: Options, overrides: [LauncherSettings.Key: String]) -> Never {
        let settings = LauncherSettings.shared
        settings.noteBoot(overrides: overrides, autoCapture: o.autoCapture)
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let context = SettingsContext(settings: settings, sound: nil, restart: { log("selftest: Restart VM pressed") },
                                      vmHasPad: o.gamepad, vmHasSound: o.sound)
        let sw = SettingsWindowController(context: context)
        final class Target: NSObject { var sw: SettingsWindowController?; @objc func open() { sw?.show() } }
        let target = Target()
        target.sw = sw
        MainMenu.installMinimal(settings: (#selector(Target.open), target))
        let dir = o.selftestOut ?? "."
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var failures: [String] = []
        var tabs = SettingsWindowController.Tab.allCases[...]

        func capture(_ name: String, _ rep: NSBitmapImageRep?) {
            let path = "\(dir)/settings-\(name).png"
            guard let rep, let png = rep.representation(using: .png, properties: [:]) else {
                failures.append("\(name): no capture")
                return
            }
            do {
                try png.write(to: URL(fileURLWithPath: path))
                // Text and controls: a dense sample grid over the content area must find many colours.
                let n = 48
                let distinct = Set((0..<(n * n)).map { i -> UInt32 in
                    let c = rep.colorAt(x: (i % n) * rep.pixelsWide / n, y: (i / n) * rep.pixelsHigh / n)
                    return c.map { UInt32(($0.redComponent * 255).rounded()) << 16 | UInt32(($0.greenComponent * 255).rounded()) << 8
                        | UInt32(($0.blueComponent * 255).rounded()) } ?? 0
                })
                log("selftest-settings: \(path) \(rep.pixelsWide)x\(rep.pixelsHigh), \(distinct.count) distinct sample colours")
                if distinct.count < 8 { failures.append("\(name): blank capture") }
            } catch {
                failures.append("\(name): \(error)")
            }
        }

        func finish() {
            log("selftest-settings: \(failures.isEmpty ? "PASS" : "FAIL: " + failures.joined(separator: ", "))")
            exit(failures.isEmpty ? 0 : 1)
        }

        func next() {
            guard let tab = tabs.popFirst() else {
                CreateDiskWindowController.show(settings: settings)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    capture("create-disk", CreateDiskWindowController.visibleWindow.flatMap(SettingsWindowController.snapshot))
                    finish()
                }
                return
            }
            sw.show(tab: tab)
            // Let the tab switch animation and SwiftUI layout settle.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                capture(tab.title.lowercased(), sw.snapshot())
                next()
            }
        }
        DispatchQueue.main.async { app.activate(); next() }
        app.run()
        exit(0)
    }
}
