import AppKit
import CKrun
import Darwin
import Foundation

var options: Options
do {
    options = try Options.parse(CommandLine.arguments)
} catch {
    FileHandle.standardError.write("steamac-vm: \(error)\n\n\(Options.usage)\n".data(using: .utf8)!)
    exit(2)
}

// MoltenVK (loaded by virglrenderer in this process) logs every instance/device creation at info
// level, which buries the guest console. Errors only, unless the user asks for more.
setenv("MVK_CONFIG_LOG_LEVEL", "1", 0)

if options.selftestDisplay { SelfTest.run(options) }
if options.selftestOverlay { OverlaySelfTest.run(options) }
// The process the user runs supervises one VM process per boot (see Supervisor).
if !Supervisor.isChild { Supervisor.run(options) }

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
    private var requestedAt: Date?
    /// SteamOS can take ~2 min to stop (systemd stop-job timeouts) before libkrun exits.
    static let gracePeriod: TimeInterval = 180

    func requestShutdown(force: Bool = false) {
        if let at = requestedAt {
            // A terminal ^C reaches both the supervisor and us; its forwarded copy is not a second request.
            if !force && Date().timeIntervalSince(at) < 1 { return }
            log("force quit")
            exit(1)
        }
        if force {
            log("force quit")
            exit(1)
        }
        requestedAt = Date()
        guard let vm, vm.requestShutdown() else {
            log("no guest power key available; exiting")
            exit(0)
        }
        progress?.hostRequestedShutdown()
        log("power key sent to guest; repeat the request to force quit")
        window?.setStatus("shutting down… (close again to force quit)")
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
    @objc func menuForceQuit() { requestShutdown(force: true) }
    @objc func menuFullscreen() { window?.window.toggleFullScreen(nil) }
    @objc func menuGrab() { window?.grabPointer() }
    @objc func menuOverlay() { window?.toggleOverlay() }
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
        // Tell the supervisor to boot again once libkrun exits; remember where the window was.
        guard let dir = Supervisor.runDir else { return }
        let frame = lifecycle.window.map { NSStringFromRect($0.window.frame) } ?? ""
        FileManager.default.createFile(atPath: Supervisor.rebootMarker(dir), contents: Data(frame.utf8))
        log("guest is rebooting: the VM will be restarted")
    }

    var inputs: VMInputs?
    if !options.headless {
        inputs = VMInputs(keyboard: InputDevices.keyboard(), tablet: InputDevices.tablet(),
                          mouse: InputDevices.mouse(), gamepad: options.gamepad ? InputDevices.xbox360Pad() : nil)
    }

    let vm = try VM(options: options, display: display, console: console, progressPort: progressPort,
                    inputs: inputs, netSocket: Supervisor.netSocket)
    lifecycle.vm = vm

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
    PerfStats.shared?.start()

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
    PerfStats.shared?.attach(view: wc.view)
    wc.view.metalLayer.framebufferOnly = false   // SIGUSR1 can read back the presented drawable
    windowController = wc
    presenter.onScanoutResize = { [weak wc] w, h in wc?.scanoutResized(width: w, height: h) }
    display.sink = presenter
    app.router = wc
    lifecycle.window = wc
    wc.onCloseRequest = { lifecycle.requestShutdown() }
    wc.attach(progress: progress)
    wc.onGuestSizeRequest = { w, h in vm.resizeDisplay(width: w, height: h) }
    MainMenu.install(target: lifecycle, shutdown: #selector(Lifecycle.menuShutdown),
                     forceQuit: #selector(Lifecycle.menuForceQuit),
                     fullscreen: #selector(Lifecycle.menuFullscreen), grab: #selector(Lifecycle.menuGrab),
                     overlay: #selector(Lifecycle.menuOverlay))
    wc.mouseSettings = MouseSettings(runOverride: options.autoCapture)
    wc.installMouseMenu()
    log("input: mouse \(options.mouseMode.rawValue), \(wc.mouseSettings.summary)")
    let gamepad = inputs?.gamepad.map { GamepadBridge(device: $0) }
    wc.show()
    wc.overlay.show()
    gamepad?.start()
    if let d = options.inputSelftestDelay { InputSelfTest.schedule(after: d, window: wc, gamepad: gamepad) }
    if let d = options.resizeSelftestDelay {
        ResizeSelfTest.start(after: d, window: wc, display: display, progress: progress,
                             base: (options.frameDumpPath as NSString).deletingPathExtension, dump: dumpFrames)
    }
    if let path = options.controlFifo {
        DebugControl.start(path: path, window: wc, progress: progress) { dumpFrames(to: $0) }
    }
    console.start()
    vm.start()
    withExtendedLifetime((presenter, gamepad, activity, progressPort, supervisorWatch)) { app.run() }
} catch {
    fatal("\(error)")
}
