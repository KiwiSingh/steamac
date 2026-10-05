import AppKit
import Combine
import CoreAudio
import GameController
import SwiftUI

/// What the Settings window needs from the running VM process (all optional: --selftest-settings
/// and the first-run sheet have no VM).
final class SettingsContext: ObservableObject {
    let settings: LauncherSettings
    /// Live audio controls; nil without a VM.
    let sound: SoundControl?
    /// Graceful guest power-off + relaunch with the new settings; nil without a VM.
    var restart: (() -> Void)?
    /// Whether the running VM has the virtual Xbox pad / a sound device (next-start state).
    var vmHasPad: Bool
    var vmHasSound: Bool
    /// The running VM's main disk (nil without a VM).
    let diskPath: String?
    /// Opens Report a Problem over the Settings window (nil without a VM; set after the window exists).
    @Published var reportProblem: (() -> Void)?
    @Published var restartRequested = false

    init(settings: LauncherSettings, sound: SoundControl?, restart: (() -> Void)?, vmHasPad: Bool, vmHasSound: Bool,
         diskPath: String? = nil) {
        self.settings = settings
        self.sound = sound
        self.restart = restart
        self.vmHasPad = vmHasPad
        self.vmHasSound = vmHasSound
        self.diskPath = diskPath
    }
}

/// App menu "FX Steam Launcher → Settings…" (Cmd+,): toolbar-style tabs, one SwiftUI form each.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    enum Tab: Int, CaseIterable {
        case general, display, mouse, controller, sound, advanced

        var title: String {
            switch self {
            case .general: return "General"
            case .display: return "Display"
            case .mouse: return "Mouse"
            case .controller: return "Controller"
            case .sound: return "Sound"
            case .advanced: return "Advanced"
            }
        }

        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .display: return "display"
            case .mouse: return "computermouse"
            case .controller: return "gamecontroller"
            case .sound: return "speaker.wave.2"
            case .advanced: return "slider.horizontal.3"
            }
        }

        /// Fixed content height per tab (grouped forms scroll beyond it).
        var height: CGFloat {
            switch self {
            case .general: return 680
            case .display: return 600
            case .mouse: return 470
            case .controller: return 620
            case .sound: return 440
            case .advanced: return 720
            }
        }
    }

    static let width: CGFloat = 600
    let window: NSWindow
    private let tabs: SettingsTabController
    let context: SettingsContext

    init(context: SettingsContext) {
        self.context = context
        tabs = SettingsTabController()
        tabs.tabStyle = .toolbar
        for tab in Tab.allCases {
            let root = SettingsTabRoot(tab: tab).environmentObject(context).environmentObject(context.settings)
            let host = NSHostingController(rootView: AnyView(root))
            host.sizingOptions = []
            host.view.frame = NSRect(x: 0, y: 0, width: SettingsWindowController.width, height: tab.height)
            host.title = tab.title
            let item = NSTabViewItem(viewController: host)
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
            tabs.addTabViewItem(item)
        }
        window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("FXSettings")
        super.init()
        window.delegate = self
        tabs.didSelect = { [weak self] tab in self?.fit(tab) }
        fit(.general)
    }

    private func fit(_ tab: Tab) {
        let size = NSSize(width: SettingsWindowController.width, height: tab.height)
        let frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        var f = window.frame
        f.origin.y += f.height - frame.height
        f.size = frame.size
        window.setFrame(f, display: true, animate: window.isVisible)
        window.title = tab.title
    }

    func show(tab: Tab? = nil) {
        if let tab { select(tab) }
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func select(_ tab: Tab) {
        tabs.selectedTabViewItemIndex = tab.rawValue
        fit(tab)
    }

    /// The window as drawn (title bar + toolbar + content) at the screen's backing scale, for
    /// --selftest-settings and the control FIFO.
    func snapshot() -> NSBitmapImageRep? { SettingsWindowController.snapshot(window) }

    static func snapshot(_ window: NSWindow) -> NSBitmapImageRep? {
        guard let frameView = window.contentView?.superview else { return nil }
        frameView.layoutSubtreeIfNeeded()
        let scale = window.backingScaleFactor
        let size = frameView.bounds.size
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                                         pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        return rep
    }
}

private final class SettingsTabController: NSTabViewController {
    var didSelect: ((SettingsWindowController.Tab) -> Void)?

    override func tabView(_ tabView: NSTabView, didSelect item: NSTabViewItem?) {
        super.tabView(tabView, didSelect: item)
        if let item, let tab = SettingsWindowController.Tab(rawValue: tabView.indexOfTabViewItem(item)) { didSelect?(tab) }
    }
}

// MARK: - shared bits

private struct SettingsTabRoot: View {
    let tab: SettingsWindowController.Tab
    @EnvironmentObject var settings: LauncherSettings

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch tab {
                case .general: GeneralTab()
                case .display: DisplayTab()
                case .mouse: MouseTab()
                case .controller: ControllerTab()
                case .sound: SoundTab()
                case .advanced: AdvancedTab()
                }
            }
            .formStyle(.grouped)
            RestartBar()
        }
        .frame(width: SettingsWindowController.width, height: tab.height)
    }
}

/// "applies now" / "applies on next start" + the command-line override note.
private struct Applies: View {
    let now: Bool
    var key: LauncherSettings.Key? = nil
    @EnvironmentObject var settings: LauncherSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(now ? "applies now" : "applies on next start")
                .font(.caption)
                .foregroundStyle(now ? Color.secondary : Color.orange.opacity(0.9))
            if let key, let flag = settings.overrides[key] {
                Text("overridden by command line (\(flag))")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }
}

/// A labelled row: title, optional explanation, the "applies" tag.
private struct Label2: View {
    let title: String
    var detail: String? = nil
    let now: Bool
    var key: LauncherSettings.Key? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            Applies(now: now, key: key)
        }
    }
}

private struct RestartBar: View {
    @EnvironmentObject var settings: LauncherSettings
    @EnvironmentObject var context: SettingsContext

    var body: some View {
        if settings.restartPending || context.restartRequested {
            HStack(spacing: 10) {
                Image(systemName: "arrow.clockwise.circle.fill").foregroundStyle(.orange).font(.title2)
                VStack(alignment: .leading, spacing: 1) {
                    Text(context.restartRequested ? "Restarting the VM…" : "Some changes apply on the next start.")
                        .font(.callout.weight(.medium))
                    Text(context.restart == nil ? "No VM is running in this window."
                         : "SteamOS shuts down cleanly and boots again with the new settings.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Restart VM to apply") {
                    context.restartRequested = true
                    context.restart?()
                }
                .disabled(context.restart == nil || context.restartRequested)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(.bar)
        }
    }
}

private func intBinding(_ b: Binding<Int>, _ range: ClosedRange<Int>) -> Binding<Int> {
    Binding(get: { b.wrappedValue }, set: { b.wrappedValue = min(range.upperBound, max(range.lowerBound, $0)) })
}

// MARK: - General

private struct GeneralTab: View {
    @EnvironmentObject var settings: LauncherSettings
    @EnvironmentObject var context: SettingsContext

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $settings.showOverlay) {
                    Label2(title: "Show boot and shutdown overlay",
                           detail: "FX progress screen while SteamOS starts, restarts and shuts down.", now: true)
                }
                Toggle(isOn: $settings.showStallIndicator) {
                    Label2(title: "Show indicator when the GPU goes idle",
                           detail: "\"Still working\" card over the picture after 2 s without GPU work from SteamOS (loading, shader compiles).",
                           now: true)
                }
                Toggle(isOn: $settings.openFullscreen) {
                    Label2(title: "Open in full screen", now: false, key: .openFullscreen)
                }
            }
            Section {
                Toggle(isOn: $settings.muteInBackground) {
                    Label2(title: "Mute sound", detail: "Short fade; the volume comes back when you switch back.", now: true)
                }
                Toggle(isOn: $settings.pauseInBackground) {
                    Label2(title: "Pause the game",
                           detail: "Freezes the focused game (Steam, downloads and updates keep running). "
                               + "Online games may disconnect while paused.",
                           now: true)
                }
            } header: {
                Text("When FX Steam Launcher is in the background")
            }
            Section {
                CrashReportsToggle(settings: settings, showsApplies: true)
                Toggle(isOn: $settings.perfStats) {
                    Label2(title: "Log frame-pacing statistics",
                           detail: "Every 5 s: guest flush and on-screen frame intervals, latency, dropped frames.",
                           now: true, key: .perfStats)
                }
            } footer: {
                if AppBundle.resources != nil {
                    Text("Log: \((AppBundle.logPath as NSString).abbreviatingWithTildeInPath)")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            Section {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Report a Problem")
                        Text("Describe what went wrong and send it with the logs you choose to the developers "
                             + "(works with crash reports off, too).")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("Report a Problem…") { context.reportProblem?() }
                        .disabled(context.reportProblem == nil)
                }
            }
        }
    }
}

// MARK: - Display

private struct DisplayTab: View {
    @EnvironmentObject var settings: LauncherSettings
    static let refreshRates = [30, 48, 50, 60, 72, 75, 90, 100, 120, 144]
    /// Largest window that fits the screen the VM window opens on (when the tab appears).
    @State private var fit = LauncherSettings.fitToScreenSize()

    /// Choosing a preset writes its W/H; "Fit to screen" writes the current fit (re-evaluated at
    /// each start); "Custom…" keeps W/H and shows the fields.
    private var preset: Binding<String> {
        Binding(get: { settings.windowSizePreset }, set: { id in
            if id == LauncherSettings.fitPreset {
                (settings.windowWidth, settings.windowHeight) = fit
            } else if let p = LauncherSettings.sizePresets.first(where: { $0.id == id }) {
                (settings.windowWidth, settings.windowHeight) = (p.width, p.height)
            }
            settings.windowSizePreset = id
        })
    }

    private func presetTitle(_ p: LauncherSettings.SizePreset) -> String {
        "\(p.width) × \(p.height) (\(p.label))" + (p.width > fit.0 || p.height > fit.1 ? " — larger than this screen" : "")
    }

    var body: some View {
        Form {
            Section {
                Picker(selection: $settings.dpiSource) {
                    Text("Auto (from the screen)").tag(LauncherSettings.DPISource.auto)
                    Text("Fixed DPI").tag(LauncherSettings.DPISource.dpi)
                    Text("Fixed size (mm)").tag(LauncherSettings.DPISource.mm)
                } label: {
                    Label2(title: "Physical size source",
                           detail: "Sets the guest's UI scale. Auto = the window's real size on this Mac's screen.",
                           now: false, key: .dpiSource)
                }
                if settings.dpiSource == .dpi {
                    Stepper(value: intBinding($settings.fixedDPI, 50...600), in: 50...600, step: 5) {
                        Text("DPI: \(settings.fixedDPI)")
                    }
                }
                if settings.dpiSource == .mm {
                    HStack {
                        Text("Size at the default window size")
                        Spacer()
                        TextField("W", value: intBinding($settings.fixedWidthMM, 10...5000), format: .number.grouping(.never))
                            .frame(width: 60).multilineTextAlignment(.trailing)
                        Text("×")
                        TextField("H", value: intBinding($settings.fixedHeightMM, 10...5000), format: .number.grouping(.never))
                            .frame(width: 60).multilineTextAlignment(.trailing)
                        Text("mm")
                    }
                }
                Picker(selection: $settings.refreshRate) {
                    ForEach(DisplayTab.refreshRates, id: \.self) { Text("\($0) Hz").tag($0) }
                    if !DisplayTab.refreshRates.contains(settings.refreshRate) {
                        Text("\(settings.refreshRate) Hz").tag(settings.refreshRate)
                    }
                } label: {
                    Label2(title: "Refresh rate", now: false, key: .refreshRate)
                }
            }
            Section {
                Toggle(isOn: $settings.followWindowSize) {
                    Label2(title: "Guest display follows the window size",
                           detail: "Off: the guest keeps its resolution and the picture is scaled to the window.",
                           now: true)
                }
                Picker(selection: preset) {
                    ForEach(LauncherSettings.sizePresets) { Text(presetTitle($0)).tag($0.id) }
                    Divider()
                    Text(verbatim: "Fit to screen (\(fit.0) × \(fit.1))").tag(LauncherSettings.fitPreset)
                    Text(verbatim: "Custom…").tag(LauncherSettings.customPreset)
                } label: {
                    Label2(title: "Default window size", detail: "Guest pixels = window points; at least 800 × 500.",
                           now: false, key: .windowSizePreset)
                }
                if settings.windowSizePreset == LauncherSettings.customPreset {
                    HStack {
                        Text("Custom size")
                        Spacer()
                        TextField("W", value: intBinding($settings.windowWidth, 800...4094), format: .number.grouping(.never))
                            .frame(width: 64).multilineTextAlignment(.trailing)
                        Text("×")
                        TextField("H", value: intBinding($settings.windowHeight, 500...4094), format: .number.grouping(.never))
                            .frame(width: 64).multilineTextAlignment(.trailing)
                        Text("pt")
                    }
                }
            }
            Section {
                Toggle(isOn: $settings.metalHUD) {
                    Label2(title: "Metal Performance HUD",
                           detail: "Apple's frame-rate overlay in the top-right corner of the window: FPS, frame "
                               + "interval, GPU time, memory (Ctrl+Cmd+P, View menu).",
                           now: true)
                }
            }
        }
    }
}

// MARK: - Mouse

private struct MouseTab: View {
    @EnvironmentObject var settings: LauncherSettings

    private func choice(_ g: LauncherSettings.Game) -> Binding<Int> {
        Binding(get: { g.autoCapture.map { $0 ? 1 : 2 } ?? 0 },
                set: { settings.setAutoCapture($0 == 0 ? nil : $0 == 1, for: g.appid) })
    }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $settings.autoCaptureGames) {
                    Label2(title: "Capture the mouse in games",
                           detail: "While a game has focus, a click captures the pointer (relative motion for mouse-look).",
                           now: true, key: .autoCaptureGames)
                }
                LabeledContent("Release the mouse") { Text("Ctrl+Option  (Ctrl+Cmd+G toggles)").foregroundStyle(.secondary) }
                LabeledContent("Steam UI and desktop") {
                    Text("pointer follows the Mac cursor 1:1 (fixed)").foregroundStyle(.secondary)
                }
            }
            Section {
                if settings.games.isEmpty {
                    Text("Games appear here after you play them in SteamOS.")
                        .foregroundStyle(.secondary)
                }
                ForEach(settings.games) { g in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(g.name ?? "Unknown game")
                            Text("App ID \(String(g.appid))").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker("", selection: choice(g)) {
                            Text(settings.globalAutoCapture ? "Default (Auto)" : "Default (Off)").tag(0)
                            Text("Auto").tag(1)
                            Text("Off").tag(2)
                        }
                        .labelsHidden()
                        .fixedSize()
                        Button {
                            settings.removeGame(g.appid)
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Forget this game")
                    }
                }
            } header: {
                HStack {
                    Text("Per game")
                    Spacer()
                    Applies(now: true)
                }
            }
        }
    }
}

// MARK: - Controller

/// Connected GameController gamepads, updated on connect/disconnect.
final class ControllerMonitor: ObservableObject {
    @Published private(set) var controllers: [GCController] = []
    private var observers: [NSObjectProtocol] = []

    init() {
        let nc = NotificationCenter.default
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.reload() })
        }
        GCController.shouldMonitorBackgroundEvents = true
        GCController.startWirelessControllerDiscovery(completionHandler: nil)
        reload()
    }

    private func reload() { controllers = GamepadBridge.connected }
}

private struct ControllerTab: View {
    @EnvironmentObject var settings: LauncherSettings
    @EnvironmentObject var context: SettingsContext
    @StateObject private var monitor = ControllerMonitor()

    private var feeding: GCController? {
        monitor.controllers.first { GamepadBridge.identifier(of: $0) == settings.controllerID } ?? monitor.controllers.first
    }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $settings.virtualPad) {
                    Label2(title: "Controller bridge",
                           detail: "Connect before boot. Restart after changing models. Buttons and sticks; no raw HID features.",
                           now: false, key: .virtualPad)
                }
                Picker(selection: $settings.controllerID) {
                    Text("First connected").tag("")
                    ForEach(monitor.controllers, id: \.self) { c in
                        Text(GamepadBridge.displayName(of: c)).tag(GamepadBridge.identifier(of: c))
                    }
                    if !settings.controllerID.isEmpty,
                       !monitor.controllers.contains(where: { GamepadBridge.identifier(of: $0) == settings.controllerID }) {
                        Text("\(settings.controllerID.replacingOccurrences(of: "|", with: " · ")) (not connected)")
                            .tag(settings.controllerID)
                    }
                } label: {
                    Label2(title: "Controller that drives it", detail: "Identity applies on next start.", now: false, key: .controllerID)
                }
                Toggle(isOn: $settings.swapABXY) {
                    Label2(title: "Swap A/B and X/Y", detail: "For Nintendo-style button layouts.", now: true)
                }
                VStack(alignment: .leading) {
                    HStack {
                        Label2(title: "Stick deadzone", now: true)
                        Spacer()
                        Text("\(settings.stickDeadzone) %").monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(value: Binding(get: { Double(settings.stickDeadzone) },
                                          set: { settings.stickDeadzone = Int($0.rounded()) }), in: 0...30, step: 1)
                }
            }
            Section {
                if monitor.controllers.isEmpty {
                    Text("No controller connected. Pair one in System Settings › Bluetooth or plug it in via USB.")
                        .foregroundStyle(.secondary)
                }
                ForEach(monitor.controllers, id: \.self) { c in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(GamepadBridge.displayName(of: c)).font(.headline)
                            if c === feeding && context.vmHasPad {
                                Text("drives the virtual pad").font(.caption)
                                    .padding(.horizontal, 6).padding(.vertical, 1)
                                    .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                            }
                            Spacer()
                            if let b = c.battery {
                                Text("\(Int(b.batteryLevel * 100)) %").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if let pad = c.extendedGamepad { PadTestView(pad: pad) }
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                HStack {
                    Text("Connected controllers — live input test")
                    Spacer()
                    Applies(now: true)
                }
            }
        }
    }
}

/// Live sticks / triggers / buttons of one controller (polled at display rate; does not take
/// the controller's value handler, which feeds the guest).
private struct PadTestView: View {
    let pad: GCExtendedGamepad

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
            HStack(alignment: .center, spacing: 18) {
                StickView(x: pad.leftThumbstick.xAxis.value, y: pad.leftThumbstick.yAxis.value,
                          pressed: pad.leftThumbstickButton?.isPressed ?? false, label: "L")
                VStack(spacing: 4) {
                    TriggerView(label: "LT", value: pad.leftTrigger.value)
                    TriggerView(label: "RT", value: pad.rightTrigger.value)
                }
                VStack(spacing: 4) {
                    HStack(spacing: 4) {
                        Dot("LB", pad.leftShoulder.isPressed); Dot("RB", pad.rightShoulder.isPressed)
                    }
                    HStack(spacing: 4) {
                        Dot("◀︎", pad.dpad.left.isPressed); Dot("▲", pad.dpad.up.isPressed)
                        Dot("▼", pad.dpad.down.isPressed); Dot("▶︎", pad.dpad.right.isPressed)
                    }
                    HStack(spacing: 4) {
                        Dot("View", pad.buttonOptions?.isPressed ?? false); Dot("Home", pad.buttonHome?.isPressed ?? false)
                        Dot("Menu", pad.buttonMenu.isPressed)
                    }
                }
                VStack(spacing: 2) {
                    Dot("Y", pad.buttonY.isPressed)
                    HStack(spacing: 2) { Dot("X", pad.buttonX.isPressed); Dot("B", pad.buttonB.isPressed) }
                    Dot("A", pad.buttonA.isPressed)
                }
                StickView(x: pad.rightThumbstick.xAxis.value, y: pad.rightThumbstick.yAxis.value,
                          pressed: pad.rightThumbstickButton?.isPressed ?? false, label: "R")
            }
            .frame(maxWidth: .infinity)
        }
    }
}

private struct StickView: View {
    let x: Float, y: Float, pressed: Bool, label: String
    var body: some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.5), lineWidth: 1)
            Circle().fill(pressed ? Color.accentColor : Color.primary.opacity(0.75))
                .frame(width: 12, height: 12)
                .offset(x: CGFloat(x) * 20, y: CGFloat(-y) * 20)
            Text(label).font(.system(size: 8)).foregroundStyle(.secondary).offset(y: 22)
        }
        .frame(width: 52, height: 52)
    }
}

private struct TriggerView: View {
    let label: String, value: Float
    var body: some View {
        HStack(spacing: 4) {
            Text(label).font(.caption2).frame(width: 18)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                Capsule().fill(Color.accentColor).frame(width: 46 * CGFloat(max(0, min(1, value))))
            }
            .frame(width: 46, height: 6)
        }
    }
}

private struct Dot: View {
    let label: String, on: Bool
    init(_ label: String, _ on: Bool) { self.label = label; self.on = on }
    var body: some View {
        Text(label)
            .font(.system(size: 9, weight: .semibold))
            .frame(minWidth: 18, minHeight: 16)
            .padding(.horizontal, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(on ? Color.accentColor : Color.secondary.opacity(0.18)))
            .foregroundStyle(on ? Color.white : Color.primary)
    }
}

// MARK: - Sound

/// CoreAudio output devices, refreshed when devices or the default output change.
final class AudioDeviceMonitor: ObservableObject {
    @Published private(set) var devices: [AudioDevices.Device] = []
    @Published private(set) var defaultName: String?
    private var listener: AudioObjectPropertyListenerBlock?

    init() {
        reload()
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.reload() }
        listener = block
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice] {
            var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main, block)
        }
    }

    deinit {
        guard let listener else { return }
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice] {
            var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main, listener)
        }
    }

    private func reload() {
        devices = AudioDevices.outputs()
        defaultName = AudioDevices.defaultOutputName()
    }
}

private struct SoundTab: View {
    @EnvironmentObject var settings: LauncherSettings
    @EnvironmentObject var context: SettingsContext
    @StateObject private var monitor = AudioDeviceMonitor()

    private var probe: SoundControl { context.sound ?? SoundControl() }

    /// Why the live controls cannot act on this VM (nil = they do).
    private var liveProblem: String? {
        if let r = probe.missingAPIReason { return r }
        if context.sound == nil { return "No VM is running in this window." }
        if !context.vmHasSound { return context.sound?.noDeviceReason ?? "This boot has no sound device." }
        return nil
    }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $settings.soundEnabled) {
                    Label2(title: "Sound", detail: "Guest audio device (virtio-snd → CoreAudio).",
                           now: false, key: .soundEnabled)
                }
            }
            Section {
                Picker(selection: $settings.soundOutputUID) {
                    Text("System default" + (monitor.defaultName.map { " (\($0))" } ?? "")).tag("")
                    ForEach(monitor.devices) { Text($0.name).tag($0.uid) }
                    if !settings.soundOutputUID.isEmpty, !monitor.devices.contains(where: { $0.uid == settings.soundOutputUID }) {
                        Text("\(settings.soundOutputUID) (not connected)").tag(settings.soundOutputUID)
                    }
                } label: {
                    Label2(title: "Output device", detail: "System default follows changes in macOS.", now: true)
                }
                .disabled(!probe.canSelectDevice)
                VStack(alignment: .leading) {
                    HStack {
                        Label2(title: "Volume", detail: "On top of the guest's own volume.", now: true)
                        Spacer()
                        Text(settings.soundMute ? "muted" : "\(Int((settings.soundVolume * 100).rounded())) %")
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                    HStack {
                        Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                        Slider(value: $settings.soundVolume, in: 0...1)
                        Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                    }
                }
                .disabled(!probe.canSetVolume)
                Toggle(isOn: $settings.soundMute) { Label2(title: "Mute", now: true) }
                    .disabled(!probe.canSetVolume)
                Picker(selection: $settings.soundLatency) {
                    Text("Low (10 ms)").tag(LauncherSettings.Latency.low)
                    Text("Normal (20 ms)").tag(LauncherSettings.Latency.normal)
                    Text("Safe (60 ms)").tag(LauncherSettings.Latency.safe)
                } label: {
                    Label2(title: "Buffer", detail: "Lower = less latency; Safe avoids crackling under load.", now: true)
                }
                .disabled(!probe.canSetBuffer)
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if let p = liveProblem {
                        Label(p, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                    }
                    Text("Microphone: the guest records from the macOS default input; macOS asks for permission the first time.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Advanced

private struct AdvancedTab: View {
    @EnvironmentObject var settings: LauncherSettings
    @EnvironmentObject var context: SettingsContext
    @State private var confirmReset = false
    @StateObject private var password = GuestPasswordModel()
    static let maxCPUs = ProcessInfo.processInfo.activeProcessorCount
    static let maxGiB = max(4, Int(ProcessInfo.processInfo.physicalMemory >> 30) - 4)

    /// The disk the next start boots (its generated SSH password is shown): Settings value, else
    /// the running VM's disk, else the default location.
    private var nextDisk: String? {
        settings.diskImage.isEmpty ? (context.diskPath ?? AppBundle.defaultDisk()) : settings.diskImage
    }

    private var diskStatus: (String, Bool) {
        if !settings.diskImage.isEmpty {
            let ok = FileManager.default.isReadableFile(atPath: settings.diskImage)
            return ((settings.diskImage as NSString).abbreviatingWithTildeInPath + (ok ? "" : " (not found)"), ok)
        }
        if let d = AppBundle.defaultDisk() { return ("Default: " + (d as NSString).abbreviatingWithTildeInPath, true) }
        return ("Default: none found", false)
    }

    var body: some View {
        Form {
            Section {
                Stepper(value: intBinding($settings.cpus, 1...AdvancedTab.maxCPUs), in: 1...AdvancedTab.maxCPUs) {
                    HStack {
                        Label2(title: "Virtual CPUs", now: false, key: .cpus)
                        Spacer()
                        Text("\(settings.cpus)").monospacedDigit()
                    }
                }
                Stepper(value: Binding(get: { settings.memMiB / 1024 },
                                       set: { settings.memMiB = min(AdvancedTab.maxGiB, max(2, $0)) * 1024 }),
                        in: 2...AdvancedTab.maxGiB) {
                    HStack {
                        Label2(title: "Memory", now: false, key: .memMiB)
                        Spacer()
                        Text("\(settings.memMiB / 1024) GB").monospacedDigit()
                    }
                }
            }
            Section {
                Toggle(isOn: Binding(get: { settings.sshEnabled }, set: { on in
                    settings.sshEnabled = on
                    if on { password.ensure() }
                })) {
                    Label2(title: "Enable SSH", detail: "Off: no port on the Mac and sshd masked in SteamOS. Turning it on "
                           + "sets the default password for the user steamos if none is saved (kept on, but unused, when SSH is off).",
                           now: false, key: .sshEnabled)
                }
                HStack {
                    Label2(title: "SSH port", now: false, key: .sshPort)
                    Spacer()
                    TextField("", value: Binding(get: { settings.sshPort },
                                                 set: { if (1024...65535).contains($0) { settings.sshPort = $0 } }),
                              format: .number.grouping(.never))
                        .frame(width: 70).multilineTextAlignment(.trailing)
                }
                .disabled(!settings.sshEnabled)
                if password.disk == nil {
                    LabeledContent("Login") { Text("no disk image").foregroundStyle(.secondary) }
                } else if let state = password.state {
                    LabeledContent("User") { Text(GuestPassword.user).textSelection(.enabled) }
                    LabeledContent("Password") {
                        HStack {
                            Text(password.shown ?? "••••••••••••••••••••").font(.body.monospaced()).textSelection(.enabled)
                            Button(password.shown == nil ? "Show" : "Hide") { password.toggleShown() }
                            Button("Copy") { password.copy(password: true, port: settings.sshPort) }
                        }
                    }
                    LabeledContent("Command") {
                        HStack {
                            Text("ssh -p \(settings.sshPort) \(GuestPassword.user)@127.0.0.1").font(.callout.monospaced())
                                .textSelection(.enabled)
                            Button("Copy") { password.copy(password: false, port: settings.sshPort) }
                        }
                    }
                    HStack {
                        Text(state == .applied ? "Password applied in SteamOS" : "Password will apply on next start")
                            .font(.caption).foregroundStyle(state == .applied ? Color.secondary : Color.orange)
                        Spacer()
                        Button("Reset to Default Password") { password.regenerate() }
                    }
                } else {
                    HStack {
                        Text("Default login: steamos / password. No saved password for this disk.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Set Default Password") { password.ensure() }
                    }
                }
                if let error = password.error { Text(error).font(.caption).foregroundStyle(.red) }
                Toggle(isOn: $settings.network) {
                    Label2(title: "Network", detail: "Off: no virtio-net / gvproxy (offline guest, also no SSH).",
                           now: false, key: .network)
                }
            }
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Label2(title: "Disk image", detail: "SteamOS raw GPT disk, used in place (never copied). "
                           + "Create New Disk… downloads SteamOS from Valve (no Docker needed).",
                           now: false, key: .diskImage)
                    HStack {
                        Text(diskStatus.0)
                            .font(.callout).foregroundStyle(diskStatus.1 ? Color.secondary : Color.red)
                            .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        Spacer()
                    }
                    HStack {
                        Spacer()
                        Button("Create New Disk…") { CreateDiskWindowController.show(settings: settings) }
                        Button("Use Existing Disk…") { chooseDisk() }
                        Button("Use Default") { settings.diskImage = "" }.disabled(settings.diskImage.isEmpty)
                    }
                }
                LabeledContent("Steam client branch") {
                    Text("set inside SteamOS (/etc/steamac/steam-client-branch)").foregroundStyle(.secondary)
                }
            }
            Section {
                HStack {
                    Spacer()
                    Button("Reset All Settings…", role: .destructive) { confirmReset = true }
                }
            }
        }
        .onAppear { password.load(disk: nextDisk) }
        .onChange(of: settings.diskImage) { password.load(disk: nextDisk) }
        .confirmationDialog("Reset all FX Steam Launcher settings to their defaults?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) { settings.resetAll() }
        } message: {
            Text("Per-game mouse settings and the chosen disk image are forgotten too.")
        }
    }

    private func chooseDisk() {
        let panel = NSOpenPanel()
        panel.title = "Choose a SteamOS disk image"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if !settings.diskImage.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: (settings.diskImage as NSString).deletingLastPathComponent)
        }
        if panel.runModal() == .OK, let url = panel.url { settings.diskImage = url.path }
    }
}

/// Settings > Advanced view of the next-start disk's generated SSH password (GuestPassword).
/// The plaintext is read from the Keychain only for Show/Copy.
private final class GuestPasswordModel: ObservableObject {
    @Published private(set) var disk: String?
    @Published private(set) var state: GuestPassword.State?
    @Published private(set) var shown: String?
    @Published private(set) var error: String?

    func load(disk path: String?) {
        disk = path.flatMap { GuestPassword.identity(ofDisk: $0) }
        shown = nil
        error = nil
        refresh()
    }

    private func refresh() { state = disk.flatMap { GuestPassword.state(disk: $0) } }

    /// SSH switched on: a disk without a generated password gets one.
    func ensure() {
        guard let disk, GuestPassword.state(disk: disk) == nil else { return }
        regenerate()
    }

    func regenerate() {
        guard let disk else { return }
        do {
            let pw = try GuestPassword.generate(disk: disk)
            if shown != nil { shown = pw }
            error = nil
        } catch {
            self.error = "\(error)"
        }
        refresh()
    }

    func toggleShown() {
        if shown != nil { shown = nil; return }
        guard let disk else { return }
        shown = GuestPassword.password(disk: disk)
        if shown == nil { error = "The password could not be read from the Keychain." }
    }

    func copy(password: Bool, port: Int) {
        let text: String?
        if password { text = disk.flatMap { GuestPassword.password(disk: $0) } }
        else { text = "ssh -p \(port) \(GuestPassword.user)@127.0.0.1" }
        guard let text else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
