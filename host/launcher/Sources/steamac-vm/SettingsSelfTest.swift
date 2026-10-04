import AppKit

/// `--selftest-settings [--selftest-out DIR]`: open the Settings window without a VM, write
/// DIR/settings-<tab>.png for every tab (command-line overrides of this run are shown as in a
/// real run) and check that each capture has content.
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

        func next() {
            guard let tab = tabs.popFirst() else {
                log("selftest-settings: \(failures.isEmpty ? "PASS" : "FAIL: " + failures.joined(separator: ", "))")
                exit(failures.isEmpty ? 0 : 1)
            }
            sw.show(tab: tab)
            // Let the tab switch animation and SwiftUI layout settle.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                let path = "\(dir)/settings-\(tab.title.lowercased()).png"
                guard let rep = sw.snapshot(), let png = rep.representation(using: .png, properties: [:]) else {
                    failures.append("\(tab.title): no capture")
                    return next()
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
                    if distinct.count < 8 { failures.append("\(tab.title): blank capture") }
                } catch {
                    failures.append("\(tab.title): \(error)")
                }
                next()
            }
        }
        DispatchQueue.main.async { app.activate(); next() }
        app.run()
        exit(0)
    }
}
