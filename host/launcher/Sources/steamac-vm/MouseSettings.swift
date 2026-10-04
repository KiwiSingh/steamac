import Foundation

/// Mouse auto-capture preferences, persisted in the app's defaults domain `es.fxgam.steamac`
/// (~/Library/Preferences/es.fxgam.steamac.plist):
///   autoCaptureGames         Bool  global default (true)
///   autoCapture.<appid>      Bool  per-game override
/// `--auto-capture on|off` overrides the global default for one run without persisting it.
final class MouseSettings {
    static let domain = "es.fxgam.steamac"
    /// Domain used before the bundle id change; copied once into `domain` if that is still empty.
    static let legacyDomain = "dev.steamac.vm"
    private let defaults: UserDefaults
    private let runOverride: Bool?

    init(runOverride: Bool?) {
        defaults = UserDefaults(suiteName: MouseSettings.domain) ?? .standard
        self.runOverride = runOverride
        MouseSettings.migrateLegacy(into: defaults)
    }

    private static func migrateLegacy(into defaults: UserDefaults) {
        guard defaults.persistentDomain(forName: domain)?.isEmpty ?? true,
              let old = defaults.persistentDomain(forName: legacyDomain), !old.isEmpty else { return }
        defaults.setPersistentDomain(old, forName: domain)
        log("settings: copied \(old.count) preference(s) from \(legacyDomain) to \(domain)")
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
