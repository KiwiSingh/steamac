import AppKit
import CKrun
import Darwin
import Foundation

// MARK: cleanup for our own exit() paths (errors, force quit). When the guest stops, libkrun
// _exit()s without running atexit handlers; Reaper covers that case.

enum Teardown {
    nonisolated(unsafe) static var console: Console?
    nonisolated(unsafe) static var gvproxy: Gvproxy?
    nonisolated(unsafe) static var cleaned = false

    static func cleanup() {
        guard !cleaned else { return }
        cleaned = true
        console?.restoreTerminal()
        gvproxy?.stop()
    }
}

atexit { Teardown.cleanup() }

let options: Options
do {
    options = try Options.parse(CommandLine.arguments)
} catch {
    FileHandle.standardError.write("steamac-vm: \(error)\n\n\(Options.usage)\n".data(using: .utf8)!)
    exit(2)
}

if options.selftestDisplay { SelfTest.run(options) }

/// Graceful shutdown policy shared by window close, menu, signals and the console escape.
final class Lifecycle: NSObject, NSApplicationDelegate {
    var vm: VM?
    weak var window: WindowController?
    private var requested = false
    static let gracePeriod: TimeInterval = 90

    func requestShutdown(force: Bool = false) {
        if force || requested {
            log("force quit")
            exit(1)
        }
        requested = true
        guard let vm, vm.requestShutdown() else {
            log("no guest power key available; exiting")
            exit(0)
        }
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
    Teardown.console = console
    console.onEscape = { force in DispatchQueue.main.async { lifecycle.requestShutdown(force: force) } }

    var network: Gvproxy?
    if options.network {
        guard let bin = Gvproxy.locate(explicit: options.gvproxyPath) else {
            throw OptionError("gvproxy not found (run host/launcher/fetch-gvproxy.sh, pass --gvproxy PATH, or --no-net)")
        }
        let g = try Gvproxy()
        Teardown.gvproxy = g
        try g.start(binary: bin, sshPort: options.sshPort)
        network = g
    }

    var inputs: VMInputs?
    if !options.headless {
        inputs = VMInputs(keyboard: InputDevices.keyboard(), tablet: InputDevices.tablet(),
                          mouse: InputDevices.mouse(), gamepad: options.gamepad ? InputDevices.xbox360Pad() : nil)
    }

    let vm = try VM(options: options, display: display, console: console, inputs: inputs, network: network)
    lifecycle.vm = vm

    for sig in [SIGINT, SIGTERM, SIGHUP] {
        onSignal(sig) { lifecycle.requestShutdown() }
    }
    // SIGUSR1: dump the guest's last frame (and, with a window, the drawable the window presented).
    var windowView: VMView?
    onSignal(SIGUSR1) {
        do {
            try display.dumpPNG(to: options.frameDumpPath)
            log("frame dumped to \(options.frameDumpPath)")
        } catch {
            log("frame dump failed: \(error)")
        }
        guard let view = windowView else { return }
        let path = (options.frameDumpPath as NSString).deletingPathExtension + "-window.png"
        view.renderer.captureNextDraw = { bytes, w, h in
            do {
                try PNG.write(bgrxLike: Data(bytes), width: w, height: h,
                              format: UInt32(KRUN_DISPLAY_FORMAT_B8G8R8A8_UNORM), to: path)
                log("window drawable (\(w)x\(h)) dumped to \(path)")
            } catch {
                log("window dump failed: \(error)")
            }
        }
        view.redraw()
    }

    log("booting \(options.kernel) cpus=\(options.cpus) mem=\(options.memMiB)MiB display=\(options.displayWidth)x\(options.displayHeight)"
        + " cmdline=\"\(options.cmdline)\"")

    try Reaper.start(gvproxy: network, restoreTerminal: Console.ownsTerminal)

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
    let wc = WindowController(title: "steamac-vm", width: options.displayWidth, height: options.displayHeight,
                              renderer: renderer, inputs: inputs, mouseMode: options.mouseMode)
    presenter.view = wc.view
    wc.view.metalLayer.framebufferOnly = false   // SIGUSR1 can read back the presented drawable
    windowView = wc.view
    presenter.onScanoutResize = { [weak wc] w, h in wc?.scanoutResized(width: w, height: h) }
    display.sink = presenter
    app.router = wc
    lifecycle.window = wc
    wc.onCloseRequest = { lifecycle.requestShutdown() }
    MainMenu.install(target: lifecycle, shutdown: #selector(Lifecycle.menuShutdown),
                     forceQuit: #selector(Lifecycle.menuForceQuit),
                     fullscreen: #selector(Lifecycle.menuFullscreen), grab: #selector(Lifecycle.menuGrab))
    let gamepad = inputs?.gamepad.map { GamepadBridge(device: $0) }
    wc.show()
    gamepad?.start()
    if let d = options.inputSelftestDelay { InputSelfTest.schedule(after: d, window: wc, gamepad: gamepad) }
    console.start()
    vm.start()
    withExtendedLifetime((presenter, gamepad, activity)) { app.run() }
} catch {
    fatal("\(error)")
}
