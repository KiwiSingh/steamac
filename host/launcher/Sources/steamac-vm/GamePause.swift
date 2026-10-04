import AppKit
import Combine
import Foundation

/// Settings > General "Pause the game" while FX Steam Launcher is in the background: when the
/// app resigns active and a game has the guest's focus, the guest agent freezes that game's
/// cgroup (`freeze-game <appid>` on fx.progress; Steam itself keeps running). While frozen the
/// launcher sends `still-background` every 2 s — the agent thaws on its own after 6 s without
/// one, so a killed launcher never leaves a game frozen. `thaw-game` when the app becomes
/// active again, the setting is turned off or the focus moves.
final class GamePause {
    static let keepaliveInterval: TimeInterval = 2
    /// Control FIFO `keepalive off`: stop the keepalives (tests of the guest's 6 s auto-thaw).
    nonisolated(unsafe) static var keepaliveSuppressed = false

    private let send: (String) -> Bool
    private var enabled: Bool
    private var appActive = true
    private var focus: GuestFocus = .steam
    /// App id the guest was asked to freeze.
    private(set) var frozen: Int?
    private var keepalive: DispatchSourceTimer?
    private var observers: [NSObjectProtocol] = []
    private var subscription: AnyCancellable?
    /// Paused state changed (stall indicator gate).
    var onChange: ((Bool) -> Void)?

    init(settings: LauncherSettings, progress: BootProgress, send: @escaping (String) -> Bool) {
        self.send = send
        enabled = settings.pauseInBackground
        let previousFocus = progress.onFocus
        progress.onFocus = { [weak self] f in previousFocus?(f); self?.focus = f; self?.update() }
        let nc = NotificationCenter.default
        observers = [
            nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                self?.setAppActive(false)
            },
            nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                self?.setAppActive(true)
            },
        ]
        // @Published emits the new value before it is stored: use the emitted value.
        subscription = settings.$pauseInBackground.dropFirst().removeDuplicates().sink { [weak self] on in
            self?.enabled = on
            self?.update()
        }
    }

    func setAppActive(_ active: Bool) {
        appActive = active
        update()
    }

    private func update() {
        var want: Int?
        if enabled, !appActive, case .game(let id) = focus, id > 0 { want = id }
        guard want != frozen else { return }
        if let id = frozen {
            keepalive?.cancel()
            keepalive = nil
            _ = send("thaw-game")
            log("game: resumed game \(id)")
        }
        frozen = want
        if let id = want {
            _ = send("freeze-game \(id)")
            log("game: paused game \(id) (launcher in the background)")
            let t = DispatchSource.makeTimerSource(queue: .main)
            t.schedule(deadline: .now() + GamePause.keepaliveInterval, repeating: GamePause.keepaliveInterval)
            t.setEventHandler { [weak self] in
                if !GamePause.keepaliveSuppressed { _ = self?.send("still-background") }
            }
            t.resume()
            keepalive = t
        }
        onChange?(frozen != nil)
    }
}
