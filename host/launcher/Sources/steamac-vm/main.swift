import AppKit
import CKrun
import Darwin
import Foundation

// Finder / `open` launch of the .app: console + launcher log go to ~/Library/Logs/es.fxgam.steamac.
if !Supervisor.isChild { AppBundle.redirectOutputIfLaunchedFromFinder() }

let settings = LauncherSettings.shared
var options: Options
var settingsOverrides: [LauncherSettings.Key: String]
do {
    (options, settingsOverrides) = try Options.resolve(CommandLine.arguments, settings: settings)
} catch {
    FileHandle.standardError.write("steamac-vm: \(error)\n\n\(Options.usage)\n".data(using: .utf8)!)
    if AppBundle.resources != nil && getppid() == 1 {   // Finder launch (the log is not on screen)
        let alert = NSAlert()
        alert.messageText = "FX Steam Launcher cannot start"
        alert.informativeText = "\(error)"
        NSApplication.shared.setActivationPolicy(.regular)
        NSApp.activate()
        alert.runModal()
    }
    exit(2)
}

// MoltenVK (loaded by virglrenderer in this process) logs every instance/device creation at info
// level, which buries the guest console. Errors only, unless the user asks for more.
setenv("MVK_CONFIG_LOG_LEVEL", "1", 0)

if options.selftestDisplay { SelfTest.run(options) }
if options.selftestOverlay { OverlaySelfTest.run(options) }
if options.selftestSettings { SettingsSelfTest.run(options, overrides: settingsOverrides) }
if options.selftestProvision { ProvisionSelfTest.run(options) }
if options.createDisk != nil { CreateDiskCLI.run(options, settings: settings) }
if let disk = options.showSSHPassword {
    guard let id = GuestPassword.identity(ofDisk: disk) else { fatal("\(disk): not a GPT disk image") }
    guard let state = GuestPassword.state(disk: id), let pw = GuestPassword.password(disk: id) else {
        fatal("no generated SSH password for \(disk) (disk \(id)); enable SSH in Settings > Advanced")
    }
    print("user \(GuestPassword.user)\npassword \(pw)\nstate \(state.rawValue)\ndisk \(id)")
    exit(0)
}
// The process the user runs supervises one VM process per boot (see Supervisor); it re-reads
// the settings before every boot.
if !Supervisor.isChild {
    Supervisor.run { try Options.resolve(CommandLine.arguments, settings: LauncherSettings()).0 }
}
if options.needsDisk { FirstRun.run(settings: settings) }
settings.noteBoot(overrides: settingsOverrides, autoCapture: options.autoCapture)

// After a guest reboot, boot at the size the window had (the guest display followed it).
if let f = Supervisor.windowFrame, !f.isEmpty, !options.headless {
    let content = NSWindow.contentRect(forFrameRect: NSRectFromString(f), styleMask: [.titled, .closable, .miniaturizable, .resizable])
    let maxSide = VM.maxDisplaySide & ~1
    options.displayWidth = min(maxSide, max(Int(WindowController.minGuestSize.width), Int(content.width) & ~1))
    options.displayHeight = min(maxSide, max(Int(WindowController.minGuestSize.height), Int(content.height) & ~1))
}

// MARK: VM process (one boot)

let windowTitle = "FX Steam Launcher"

/// Graceful shutdown policy shared by window close, menu, signals and the console escape.
final class Lifecycle: NSObject, NSApplicationDelegate {
    /// Restored on our own exit() paths (libkrun's _exit skips atexit; the supervisor restores then).
    nonisolated(unsafe) static var console: Console?
    var vm: VM?
    var progress: BootProgress?
    weak var window: WindowController?
    var settingsWindow: SettingsWindowController?
    var settingsContext: SettingsContext?
    private var requestedAt: Date?
    /// SteamOS can take ~2 min to stop (systemd stop-job timeouts) before libkrun exits.
    static let gracePeriod: TimeInterval = 180

    /// Force quit: no relaunch even if a restart was pending.
    private func forceQuit() -> Never {
        log("force quit")
        if let dir = Supervisor.runDir { try? FileManager.default.removeItem(atPath: Supervisor.rebootMarker(dir)) }
        exit(1)
    }

    func requestShutdown(force: Bool = false) {
        if let at = requestedAt {
            // A terminal ^C reaches both the supervisor and us; its forwarded copy is not a second request.
            if !force && Date().timeIntervalSince(at) < 1 { return }
            forceQuit()
        }
        if force { forceQuit() }
        requestedAt = Date()
        guard let vm, vm.requestShutdown() else {
            log("no guest power key available; exiting")
            exit(0)
        }
        progress?.hostRequestedShutdown()
        log("power key sent to guest; repeat the request to force quit")
        window?.setStatus("shutting down… (close again to force quit)")
        startGraceTimer()
    }

    /// "Restart VM" (menu / Settings): power the guest off cleanly, then the supervisor boots it
    /// again with the current settings.
    func requestRestart() {
        guard requestedAt == nil, let vm, let progress else { return }
        requestedAt = Date()
        progress.hostRequestedRestart()   // onRebootIntent writes the supervisor's reboot marker
        guard vm.requestShutdown() else {
            log("no guest power key available; restarting the VM process")
            exit(0)
        }
        settingsContext?.restartRequested = true
        log("restart: power key sent to guest; the VM starts again once it is off")
        window?.setStatus("restarting… (close to force quit)")
        startGraceTimer()
    }

    private func startGraceTimer() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Lifecycle.gracePeriod) {
            log("guest did not power off within \(Int(Lifecycle.gracePeriod)) s; forcing exit")
            exit(1)
        }
    }

    /// Dock "Quit" / logout: shut the guest down instead of killing it.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        requestShutdown()
        return .terminateCancel
    }

    @objc func menuShutdown() { requestShutdown() }
    @objc func menuRestart() { requestRestart() }
    @objc func menuForceQuit() { requestShutdown(force: true) }
    @objc func menuFullscreen() { window?.window.toggleFullScreen(nil) }
    @objc func menuGrab() { window?.grabPointer() }
    @objc func menuOverlay() { window?.toggleOverlay() }
    @objc func menuSettings() { settingsWindow?.show() }
}

let lifecycle = Lifecycle()
let display = DisplayBackend()
var signalSources: [DispatchSourceSignal] = []

func onSignal(_ sig: Int32, _ handler: @escaping () -> Void) {
    signal(sig, SIG_IGN)
    let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    s.setEventHandler(handler: handler)
    s.resume()
    signalSources.append(s)
}

do {
    let console = try Console(logPath: options.logFile)
    console.onEscape = { force in DispatchQueue.main.async { lifecycle.requestShutdown(force: force) } }
    atexit { Lifecycle.console?.restoreTerminal() }
    Lifecycle.console = console

    let progress = BootProgress(restarting: Supervisor.bootNumber > 1)
    lifecycle.progress = progress
    console.onLine = { progress.consoleLine($0) }
    let progressPort = try ProgressPort()
    progressPort.start { progress.guestLine($0) }
    progress.onRebootIntent = {
        // Tell the supervisor to boot again once libkrun exits; remember where the window was
        // (unless Settings changed the default window size: then the next boot opens at that).
        guard let dir = Supervisor.runDir else { return }
        let frame = settings.windowSizeChanged ? "" : (lifecycle.window.map { NSStringFromRect($0.window.frame) } ?? "")
        FileManager.default.createFile(atPath: Supervisor.rebootMarker(dir), contents: Data(frame.utf8))
        log("guest is rebooting: the VM will be restarted")
    }
    progress.onGameName = { id, name in settings.setGameName(name, for: id) }
    progress.onProvision = { ok, reason in Provision.finished(ok: ok, reason: reason, payload: options.provisionPayload) }
    if let p = options.provisionPayload { log("provision: first boot of this disk: payload \(p) attached read-only, \(Provision.cmdlineFlag)") }
    progress.onConfig = { ok, reason in Provision.configFinished(ok: ok, reason: reason, payload: options.configPayload) }
    if let c = options.configPayload { log("config: new SteamOS password pending: \(c.path) attached read-only, \(Provision.configFlag)") }

    var inputs: VMInputs?
    if !options.headless {
        inputs = VMInputs(keyboard: InputDevices.keyboard(), tablet: InputDevices.tablet(),
                          mouse: InputDevices.mouse(), gamepad: options.gamepad ? InputDevices.xbox360Pad() : nil)
    }

    let vm = try VM(options: options, display: display, console: console, progressPort: progressPort,
                    inputs: inputs, netSocket: Supervisor.netSocket)
    lifecycle.vm = vm
    let sound = SoundControl()
    if vm.hasSound {
        sound.attach(ctx: vm.ctx, settings: settings)
        if let missing = sound.missingAPIReason { log("sound: live controls unavailable: \(missing)") }
    } else {
        sound.detach(reason: options.sound ? "This libkrun has no sound support (SND=1)." : "Sound was off when this VM started.")
    }

    for sig in [SIGINT, SIGTERM, SIGHUP] {
        onSignal(sig) { lifecycle.requestShutdown() }
    }
    // SIGUSR1: dump the guest's last frame (and, with a window, what the window shows:
    // <name>-window.png = Metal drawable, <name>-overlay.png = drawable + overlay at 2x).
    var windowController: WindowController?
    func dumpFrames(to path: String, done: (() -> Void)? = nil) {
        do {
            try display.dumpPNG(to: path)
            log("frame dumped to \(path)")
        } catch {
            log("frame dump failed: \(error)")
        }
        guard let wc = windowController else { done?(); return }
        let base = (path as NSString).deletingPathExtension
        wc.captureWindow { drawable, composite in
            do {
                if let drawable { try PNG.write(drawable, to: base + "-window.png") }
                if let composite { try PNG.write(composite, to: base + "-overlay.png") }
                log("window dumped to \(base)-window.png, \(base)-overlay.png (overlay \(wc.overlay.shown ? "shown" : "hidden"))")
            } catch {
                log("window dump failed: \(error)")
            }
            done?()
        }
    }
    onSignal(SIGUSR1) { dumpFrames(to: options.frameDumpPath) }
    // If the supervisor dies (e.g. SIGKILL), gvproxy goes with it: shut the guest down cleanly
    // instead of leaving an orphaned VM without networking.
    let supervisorWatch = DispatchSource.makeProcessSource(identifier: getppid(), eventMask: .exit, queue: .main)
    supervisorWatch.setEventHandler {
        log("launcher supervisor exited; shutting the guest down")
        lifecycle.requestShutdown()
    }
    supervisorWatch.resume()

    log("booting \(options.kernel) cpus=\(options.cpus) mem=\(options.memMiB)MiB display=\(options.displayWidth)x\(options.displayHeight)"
        + " cmdline=\"\(options.cmdline)\"" + (Supervisor.bootNumber > 1 ? " (boot #\(Supervisor.bootNumber))" : ""))
    PerfStats.setEnabled(options.perfStats)
    // Settings > General toggles the stats live unless --perf-stats / STEAMAC_PERF_STATS fixed them.
    let perfSubscription = settings.$perfStats.dropFirst().sink { on in
        if settingsOverrides[.perfStats] == nil { DispatchQueue.main.async { PerfStats.setEnabled(on) } }
    }

    if options.headless {
        console.start()
        vm.start()
        dispatchMain()
    }

    let app = SteamacApplication.shared as! SteamacApplication
    app.setActivationPolicy(.regular)
    let activity = ProcessInfo.processInfo.beginActivity(
        options: [.userInitiated, .latencyCritical, .idleSystemSleepDisabled], reason: "virtual machine running")
    app.delegate = lifecycle
    let renderer = Renderer()
    let presenter = Presenter(display: display, renderer: renderer)
    let wc = WindowController(title: windowTitle, width: options.displayWidth, height: options.displayHeight,
                              renderer: renderer, inputs: inputs, mouseMode: options.mouseMode)
    if let f = Supervisor.windowFrame, !f.isEmpty { wc.window.setFrame(NSRectFromString(f), display: false) }
    presenter.view = wc.view
    PerfStats.instance.attach(view: wc.view)
    wc.view.metalLayer.framebufferOnly = false   // SIGUSR1 can read back the presented drawable
    windowController = wc
    presenter.onScanoutResize = { [weak wc] w, h in wc?.scanoutResized(width: w, height: h) }
    display.sink = presenter
    app.router = wc
    lifecycle.window = wc
    wc.onCloseRequest = { lifecycle.requestShutdown() }
    wc.attach(progress: progress)
    wc.onGuestSizeRequest = { w, h in vm.resizeDisplay(width: w, height: h) }
    let settingsContext = SettingsContext(settings: settings, sound: sound, restart: { lifecycle.requestRestart() },
                                          vmHasPad: inputs?.gamepad != nil, vmHasSound: vm.hasSound,
                                          diskPath: options.disks.first?.path)
    let settingsWindow = SettingsWindowController(context: settingsContext)
    lifecycle.settingsContext = settingsContext
    lifecycle.settingsWindow = settingsWindow
    wc.onOpenSettings = { settingsWindow.show() }
    MainMenu.install(target: lifecycle, settings: #selector(Lifecycle.menuSettings), restart: #selector(Lifecycle.menuRestart),
                     shutdown: #selector(Lifecycle.menuShutdown), forceQuit: #selector(Lifecycle.menuForceQuit),
                     fullscreen: #selector(Lifecycle.menuFullscreen), grab: #selector(Lifecycle.menuGrab),
                     overlay: #selector(Lifecycle.menuOverlay))
    wc.installMouseMenu()
    log("input: mouse \(options.mouseMode.rawValue), \(settings.mouseSummary)")
    let gamepad = inputs?.gamepad.map { GamepadBridge(device: $0, settings: settings) }
    wc.show()
    if settings.showOverlay { wc.overlay.show() }
    if options.fullscreen && !wc.window.styleMask.contains(.fullScreen) { wc.window.toggleFullScreen(nil) }
    gamepad?.start()
    if let d = options.inputSelftestDelay { InputSelfTest.schedule(after: d, window: wc, gamepad: gamepad) }
    if let d = options.resizeSelftestDelay {
        ResizeSelfTest.start(after: d, window: wc, display: display, progress: progress,
                             base: (options.frameDumpPath as NSString).deletingPathExtension, dump: dumpFrames)
    }
    if let path = options.controlFifo {
        DebugControl.start(path: path, window: wc, progress: progress, settingsWindow: settingsWindow) { dumpFrames(to: $0) }
    }
    console.start()
    vm.start()
    withExtendedLifetime((presenter, gamepad, activity, progressPort, supervisorWatch, perfSubscription)) { app.run() }
} catch {
    fatal("\(error)")
}
