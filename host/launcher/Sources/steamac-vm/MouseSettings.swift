import Foundation

/// Mouse auto-capture preferences, persisted in the `dev.steamac.vm` defaults domain
/// (~/Library/Preferences/dev.steamac.vm.plist):
///   autoCaptureGames         Bool  global default (true)
///   autoCapture.<appid>      Bool  per-game override
/// `--auto-capture on|off` overrides the global default for one run without persisting it.
final class MouseSettings {
    static let domain = "dev.steamac.vm"
    private let defaults: UserDefaults
    private let runOverride: Bool?

    init(runOverride: Bool?) {
        defaults = UserDefaults(suiteName: MouseSettings.domain) ?? .standard
        self.runOverride = runOverride
    }

    var globalAutoCapture: Bool {
        get { runOverride ?? (defaults.object(forKey: "autoCaptureGames") as? Bool ?? true) }
        set {
            defaults.set(newValue, forKey: "autoCaptureGames")
            log("input: auto-capture in games \(newValue ? "on" : "off") (saved)" + (runOverride != nil ? "; --auto-capture still applies to this run" : ""))
        }
    }

    /// Per-game override, nil = follow the global default.
    func override(for appid: Int) -> Bool? {
        defaults.object(forKey: "autoCapture.\(appid)") as? Bool
    }

    func autoCapture(for appid: Int) -> Bool {
        override(for: appid) ?? globalAutoCapture
    }

    func setAutoCapture(_ on: Bool, for appid: Int) {
        defaults.set(on, forKey: "autoCapture.\(appid)")
        log("input: auto-capture for game \(appid) \(on ? "on" : "off") (saved)")
    }

    var summary: String {
        let overrides = defaults.dictionaryRepresentation()
            .compactMap { k, v -> String? in
                guard k.hasPrefix("autoCapture."), let b = v as? Bool else { return nil }
                return "\(k.dropFirst("autoCapture.".count))=\(b ? "on" : "off")"
            }
            .sorted()
        return "auto-capture in games \(globalAutoCapture ? "on" : "off")"
            + (runOverride != nil ? " (--auto-capture)" : "")
            + (overrides.isEmpty ? "" : ", per game: " + overrides.joined(separator: " "))
    }
}
