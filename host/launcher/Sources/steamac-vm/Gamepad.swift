import Combine
import Darwin
import Foundation
import GameController

/// The gamepad SteamOS sees, created by the guest's fx-pad service as a uinput device (PadPort):
/// the identity and capabilities the real controller's kernel driver exposes, so SDL's GUID-based
/// mapping (bus, vendor, product, version) and Steam recognise it, plus FF_RUMBLE (Rumble):
/// - xbox360: drivers/input/joystick/xpad.c, XTYPE_XBOX360 (dpad as hat, triggers as axes);
/// - dualSense / dualShock4: hid-playstation / hid-sony for a USB pad (version 0x8111, face
///   buttons by position, digital L2/R2 besides ABS_Z/ABS_RZ) — SDL's
///   030000004c050000{e60c,cc09}000011810000 mappings; Steam shows PlayStation glyphs.
///   Touchpad, gyro, lightbar and adaptive triggers are HID features this evdev device lacks.
enum GuestPad: Equatable {
    case xbox360, dualSense, dualShock4

    var sony: Bool { self != .xbox360 }

    var title: String {
        switch self {
        case .xbox360: return "Xbox 360 controller"
        case .dualSense: return "DualSense"
        case .dualShock4: return "DualShock 4"
        }
    }

    var identity: (name: String, bus: UInt16, vendor: UInt16, product: UInt16, version: UInt16) {
        switch self {
        case .xbox360: return ("Microsoft X-Box 360 pad", BUS.USB, 0x045e, 0x028e, 0x0114)
        case .dualSense: return ("Sony Interactive Entertainment DualSense Wireless Controller", BUS.USB, 0x054c, 0x0ce6, 0x8111)
        case .dualShock4: return ("Sony Interactive Entertainment Wireless Controller", BUS.USB, 0x054c, 0x09cc, 0x8111)
        }
    }

    /// Evdev key codes the device advertises. xpad: X/Y as BTN_X/BTN_Y. hid-playstation /
    /// hid-sony: the same codes by position (square BTN_WEST, triangle BTN_NORTH) plus digital
    /// L2/R2 next to the analog triggers.
    var buttonCodes: [UInt16] {
        let common = [BTN.SOUTH, BTN.EAST, BTN.NORTH, BTN.WEST, BTN.TL, BTN.TR,
                      BTN.SELECT, BTN.START, BTN.MODE, BTN.THUMBL, BTN.THUMBR]
        return sony ? common + [BTN.TL2, BTN.TR2, BTN.SONY_TOUCHPAD_CLICK] : common
    }

    /// Axes (the same for all three): sticks, analog triggers, the dpad as a hat.
    static let axes: [(code: UInt16, info: AbsAxis)] = {
        let stick = AbsAxis(min: -32768, max: 32767, fuzz: 16, flat: 128)
        let trigger = AbsAxis(min: 0, max: 255)
        let hat = AbsAxis(min: -1, max: 1)
        return [(ABS.X, stick), (ABS.Y, stick), (ABS.Z, trigger), (ABS.RX, stick), (ABS.RY, stick),
                (ABS.RZ, trigger), (ABS.HAT0X, hat), (ABS.HAT0Y, hat)]
    }()

    /// fx.pad `create <bus> <vendor> <product> <version> <keys> <axes> <name>`.
    var createLine: String {
        let id = identity
        let keys = buttonCodes.map(String.init).joined(separator: ",")
        let axes = GuestPad.axes.map { "\($0.code):\($0.info.min):\($0.info.max):\($0.info.fuzz):\($0.info.flat)" }
            .joined(separator: ",")
        return String(format: "create %04x %04x %04x %04x ", id.bus, id.vendor, id.product, id.version)
            + "\(keys) \(axes) \(id.name)"
    }

    /// Automatic: the same kind as the controller (its GameController profile).
    static func matching(_ c: GCController) -> GuestPad {
        switch c.extendedGamepad {
        case is GCDualSenseGamepad: return .dualSense
        case is GCDualShockGamepad: return .dualShock4
        default: return .xbox360
        }
    }
}

/// The `fx.pad` virtio-console port to the guest's root service fx-pad (`fx-progress-agent pad`,
/// guest/progress-agent/src/pad.rs), which owns the guest's gamepad as a uinput device:
///   host → guest  `create <bus> <vendor> <product> <version> <keys> <axes> <name>` (GuestPad),
///                 `remove`, `ev <type>:<code>:<value> …` (one input frame),
///                 `battery <percent> <state>` (controller battery; state is unknown/discharging/charging/full)
///   guest → host  `hello` (the service started, without a pad), `rumble <strong> <weak>` (0…65535)
final class PadPort {
    static let name = "fx.pad"
    /// Handed to libkrun: guest → host data is written here.
    let guestOutputFd: Int32
    /// Handed to libkrun: host → guest data is read from here.
    let guestInputFd: Int32
    private let readFd: Int32
    private let writeFd: Int32

    init() throws {
        var out: [Int32] = [0, 0], inp: [Int32] = [0, 0]
        guard pipe(&out) == 0, pipe(&inp) == 0 else { throw OptionError("pipe: \(String(cString: strerror(errno)))") }
        readFd = out[0]; guestOutputFd = out[1]
        guestInputFd = inp[0]; writeFd = inp[1]
        for fd in out + inp { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        // Never block the main thread if the guest stops reading; a lost frame is followed by
        // the next one (each carries the changed values) or a full resend after `hello`.
        _ = fcntl(writeFd, F_SETFL, fcntl(writeFd, F_GETFL) | O_NONBLOCK)
    }

    /// One host → guest line; false if the pipe did not take it whole.
    func send(_ line: String) -> Bool {
        ClockPort.write(writeFd, line)
    }

    /// Reader thread: every complete line goes to `handler` on the main queue.
    func start(_ handler: @escaping (String) -> Void) {
        let t = Thread { [readFd] in
            var splitter = LineSplitter()
            var buf = [UInt8](repeating: 0, count: 512)
            while true {
                let n = Darwin.read(readFd, &buf, buf.count)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { break }
                buf.withUnsafeBytes { p in
                    splitter.feed(UnsafeRawBufferPointer(rebasing: p[0..<n])) { line in
                        let line = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !line.isEmpty { DispatchQueue.main.async { handler(line) } }
                    }
                }
            }
        }
        t.name = "fx.pad"
        t.start()
    }
}

/// Feeds the guest's gamepad (GuestPad over PadPort) from a GameController.framework extended
/// gamepad (Xbox, DualSense, DualShock, MFi, ...) and plays its rumble on that controller.
/// Settings > Controller picks which controller (first connected by default), whether SteamOS
/// gets a pad and what kind ("Appears in SteamOS as"; Automatic = the controller's own kind),
/// swaps A/B and X/Y for Nintendo-style layouts and applies a radial stick deadzone, all while
/// the VM runs: the guest's pad comes and goes with the controller and changes kind with it.
final class GamepadBridge {
    private let port: PadPort
    private let settings: LauncherSettings
    /// `--pad` for this run (wins over the setting).
    private let typeOverride: LauncherSettings.PadType?
    private var controller: GCController?
    /// The pad the guest has (created over fx.pad), nil = none.
    private var guestPad: GuestPad?
    /// What the guest last got (or, without a pad, the controller's last state).
    private var state = PadState()
    /// The guest's fx-pad service said `hello`: it can create a pad.
    private var serviceReady = false
    /// --input-selftest, control `pad on`: a pad even without a controller.
    private var testPad = false
    private let rumble = Rumble()
    private var observers: [NSObjectProtocol] = []
    private var subscriptions: [AnyCancellable] = []
    /// While the VM is paused (suspended, guest asleep): called before anything is sent, with
    /// whether a button went down; true = keep it from the guest (a press may wake it).
    var intercept: ((_ buttonPressed: Bool) -> Bool)?

    struct PadState: Equatable {
        var buttons: [UInt16: Bool] = [:]
        var axes: [UInt16: Int32] = [:]
    }

    static let axisCodes: [UInt16] = GuestPad.axes.map(\.code)

    init(port: PadPort, settings: LauncherSettings, typeOverride: LauncherSettings.PadType?) {
        self.port = port
        self.settings = settings
        self.typeOverride = typeOverride
    }

    /// Everything released, sticks centred.
    static func rest(_ pad: GuestPad) -> PadState {
        PadState(buttons: Dictionary(uniqueKeysWithValues: pad.buttonCodes.map { ($0, false) }),
                 axes: Dictionary(uniqueKeysWithValues: axisCodes.map { ($0, 0) }))
    }

    /// Settings identifier of a controller: "<vendorName>|<productCategory>".
    static func identifier(of c: GCController) -> String {
        "\(c.vendorName ?? "?")|\(c.productCategory)"
    }

    static func displayName(of c: GCController) -> String {
        let vendor = c.vendorName ?? "Controller"
        return vendor == c.productCategory ? vendor : "\(vendor) (\(c.productCategory))"
    }

    /// Extended gamepads in connection order.
    static var connected: [GCController] {
        GCController.controllers().filter { $0.extendedGamepad != nil }
    }

    func start() {
        GCController.shouldMonitorBackgroundEvents = true
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] n in
            if let c = n.object as? GCController { log("gamepad connected: \(c.vendorName ?? "?") (\(c.productCategory))") }
            self?.selectController()
        })
        observers.append(nc.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] n in
            if let c = n.object as? GCController { log("gamepad disconnected: \(c.vendorName ?? "?")") }
            self?.selectController()
        })
        observers.append(nc.addObserver(forName: .GCControllerDidBecomeCurrent, object: nil, queue: .main) { [weak self] _ in
            self?.selectController()
        })
        // @Published emits before the property changes: re-read on the next main-queue turn.
        subscriptions.append(settings.$controllerID.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.selectController()
        })
        for p in [settings.$virtualPad.map { _ in () }.eraseToAnyPublisher(), settings.$padType.map { _ in () }.eraseToAnyPublisher()] {
            subscriptions.append(p.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] in self?.reconcile() })
        }
        subscriptions.append(settings.$swapABXY.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in self?.refresh() })
        subscriptions.append(settings.$stickDeadzone.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in self?.refresh() })
        port.start { [weak self] line in self?.guestLine(line) }
        GCController.startWirelessControllerDiscovery(completionHandler: nil)
        selectController()
    }

    /// The VM was paused (suspend, guest sleep) / runs again: no rumble while nothing runs.
    func vmPaused(_ paused: Bool) {
        rumble.paused = paused
    }

    private func guestLine(_ line: String) {
        let w = line.split(separator: " ").map(String.init)
        if w == ["hello"] {
            // A (re)started service has no pad: create it again.
            log("gamepad: the guest's pad service is ready")
            serviceReady = true
            guestPad = nil
            rumble.set(strong: 0, weak: 0)
            reconcile()
        } else if w.count == 3, w[0] == "rumble", let strong = UInt16(w[1]), let weak = UInt16(w[2]) {
            rumble.set(strong: strong, weak: weak)
        } else {
            log("gamepad: unknown line \"\(line)\" on \(PadPort.name)")
        }
    }

    private func selectController() {
        let candidates = GamepadBridge.connected
        let next: GCController?
        if !settings.controllerID.isEmpty,
           let chosen = candidates.first(where: { GamepadBridge.identifier(of: $0) == settings.controllerID }) {
            next = chosen
        } else {
            // First connected (the chosen one is not connected: fall back to it as well).
            next = candidates.first
        }
        if next === controller { return }
        controller?.extendedGamepad?.valueChangedHandler = nil
        controller = next
        rumble.attach(next)
        if let c = next, let pad = c.extendedGamepad {
            log("gamepad active: \(GamepadBridge.displayName(of: c))")
            // Keep the Home/PS button for the guest (Steam button) instead of macOS.
            pad.buttonHome?.preferredSystemGestureState = .disabled
            pad.buttonOptions?.preferredSystemGestureState = .disabled
            pad.buttonMenu.preferredSystemGestureState = .disabled
            pad.valueChangedHandler = { [weak self] pad, _ in self?.update(from: pad) }
        } else {
            log("gamepad: none connected")
        }
        let before = guestPad
        reconcile()
        if let pad = guestPad, pad == before {
            // Same pad, another controller: release what the previous one held.
            apply(GamepadBridge.rest(pad))
            refresh()
        }
    }

    /// The pad the guest should have: none without a controller or with "Virtual controller"
    /// off; else the kind from "Appears in SteamOS as" (`--pad`), Automatic = the controller's.
    private func wanted() -> (pad: GuestPad, why: String)? {
        guard settings.virtualPad, controller != nil || testPad else { return nil }
        switch typeOverride ?? settings.padType {
        case .xbox360: return (.xbox360, typeOverride == nil ? "setting" : "--pad")
        case .dualSense: return (.dualSense, typeOverride == nil ? "setting" : "--pad")
        case .dualShock4: return (.dualShock4, typeOverride == nil ? "setting" : "--pad")
        case .auto:
            guard let c = controller else { return (.xbox360, "automatic, no controller") }
            return (GuestPad.matching(c), "automatic, like \(GamepadBridge.displayName(of: c))")
        }
    }

    /// Create, replace or remove the guest's pad to match `wanted()`.
    private func reconcile() {
        guard serviceReady else { return }
        let want = wanted()
        guard want?.pad != guestPad else { return }
        if let old = guestPad {
            _ = port.send("remove")
            log("gamepad: removed the \(old.title) from SteamOS")
        }
        guestPad = nil
        rumble.set(strong: 0, weak: 0)
        guard let want else { return }
        guard port.send(want.pad.createLine) else {
            log("gamepad: cannot write to \(PadPort.name)")
            return
        }
        guestPad = want.pad
        log("gamepad: SteamOS sees a \(want.pad.title) (\(want.why))")
        // The new device is at rest; send the controller's current state.
        state = GamepadBridge.rest(want.pad)
        refresh()
    }

    /// Swap / deadzone changed, new pad: resend the current state with the current mapping.
    private func refresh() {
        if let pad = controller?.extendedGamepad { update(from: pad) }
    }

    private func update(from pad: GCExtendedGamepad) {
        apply(GamepadBridge.read(pad, as: guestPad ?? .xbox360, swapABXY: settings.swapABXY,
                                 deadzone: Float(settings.stickDeadzone) / 100))
        sendBattery()
    }

    /// Forward the physical controller's battery state to native-HID guest pads.
    /// GameController reports level as 0...1; the guest translates that to the
    /// coarser battery representation used by the DualSense HID protocol.
    private var lastBatteryReport: (percent: Int, state: String)?

    private func sendBattery() {
        guard guestPad?.sony == true, let battery = controller?.battery else { return }

        let percent = Int((max(0, min(1, battery.batteryLevel)) * 100).rounded())
        let state: String
        switch battery.batteryState {
        case .discharging:
            state = "discharging"
        case .charging:
            state = "charging"
        case .full:
            state = "full"
        default:
            state = "unknown"
        }

        let report = (percent: percent, state: state)
        guard lastBatteryReport?.percent != report.percent ||
              lastBatteryReport?.state != report.state else { return }

        if port.send("battery \(percent) \(state)") {
            lastBatteryReport = report
        }
    }

    private static func axis(_ v: Float) -> Int32 {
        Int32((max(-1, min(1, v)) * 32767).rounded())
    }

    /// Radial deadzone `dz` (0..1), rescaled so the stick still reaches full deflection.
    static func deadzoned(_ x: Float, _ y: Float, _ dz: Float) -> (Float, Float) {
        guard dz > 0 else { return (x, y) }
        let m = (x * x + y * y).squareRoot()
        guard m > dz else { return (0, 0) }
        let scale = min(1, (m - dz) / (1 - dz)) / m
        return (x * scale, y * scale)
    }

    /// The guest pad's state for this controller state. GameController names the face buttons
    /// by position (A south, B east, X west, Y north), like the guest's codes for a Sony pad; xpad
    /// reports Xbox X (west) as BTN_X (= BTN_NORTH's code) and Y (north) as BTN_Y (= BTN_WEST's).
    static func read(_ p: GCExtendedGamepad, as pad: GuestPad, swapABXY: Bool, deadzone: Float) -> PadState {
        var s = PadState()
        let (south, east) = swapABXY ? (p.buttonB, p.buttonA) : (p.buttonA, p.buttonB)
        let (west, north) = swapABXY ? (p.buttonY, p.buttonX) : (p.buttonX, p.buttonY)
        s.buttons[BTN.SOUTH] = south.isPressed
        s.buttons[BTN.EAST] = east.isPressed
        if pad.sony {
            s.buttons[BTN.WEST] = west.isPressed
            s.buttons[BTN.NORTH] = north.isPressed
            s.buttons[BTN.TL2] = p.leftTrigger.isPressed
            s.buttons[BTN.TR2] = p.rightTrigger.isPressed

            if let dualSense = p as? GCDualSenseGamepad {
                s.buttons[BTN.SONY_TOUCHPAD_CLICK] = dualSense.touchpadButton.isPressed
            } else if let dualShock = p as? GCDualShockGamepad {
                s.buttons[BTN.SONY_TOUCHPAD_CLICK] = dualShock.touchpadButton.isPressed
            }
        } else {
            s.buttons[BTN.NORTH] = west.isPressed
            s.buttons[BTN.WEST] = north.isPressed
        }
        s.buttons[BTN.TL] = p.leftShoulder.isPressed
        s.buttons[BTN.TR] = p.rightShoulder.isPressed
        s.buttons[BTN.SELECT] = p.buttonOptions?.isPressed ?? false
        s.buttons[BTN.START] = p.buttonMenu.isPressed
        s.buttons[BTN.MODE] = p.buttonHome?.isPressed ?? false
        s.buttons[BTN.THUMBL] = p.leftThumbstickButton?.isPressed ?? false
        s.buttons[BTN.THUMBR] = p.rightThumbstickButton?.isPressed ?? false
        // xpad and hid-playstation report Y axes inverted relative to GameController (up = negative).
        let l = deadzoned(p.leftThumbstick.xAxis.value, p.leftThumbstick.yAxis.value, deadzone)
        let r = deadzoned(p.rightThumbstick.xAxis.value, p.rightThumbstick.yAxis.value, deadzone)
        s.axes[ABS.X] = axis(l.0)
        s.axes[ABS.Y] = -axis(l.1)
        s.axes[ABS.RX] = axis(r.0)
        s.axes[ABS.RY] = -axis(r.1)
        s.axes[ABS.Z] = Int32((max(0, min(1, p.leftTrigger.value)) * 255).rounded())
        s.axes[ABS.RZ] = Int32((max(0, min(1, p.rightTrigger.value)) * 255).rounded())
        let d = p.dpad
        s.axes[ABS.HAT0X] = d.left.isPressed ? -1 : (d.right.isPressed ? 1 : 0)
        s.axes[ABS.HAT0Y] = d.up.isPressed ? -1 : (d.down.isPressed ? 1 : 0)
        return s
    }

    private func apply(_ next: PadState) {
        let pressed = next.buttons.contains { $0.value && state.buttons[$0.key] != true }
        if let intercept, intercept(pressed) {
            // Nothing is queued for the paused guest; `state` stays what the guest last got, so
            // the first change after the wake sends the difference (a tapped wake button: none).
            return
        }
        guard let pad = guestPad else {
            state = next
            return
        }
        var events: [String] = []
        for c in pad.buttonCodes where next.buttons[c] != state.buttons[c] {
            events.append("\(EV.KEY):\(c):\(next.buttons[c] == true ? 1 : 0)")
        }
        for a in GamepadBridge.axisCodes where next.axes[a] != state.axes[a] {
            events.append("\(EV.ABS):\(a):\(next.axes[a] ?? 0)")
        }
        state = next
        if !events.isEmpty { _ = port.send("ev " + events.joined(separator: " ")) }
    }

    /// --input-selftest: a pad even without a controller, press/release A and push the left stick
    /// right, then return to rest.
    func injectTestSequence() {
        testPad = true
        reconcile()
        guard guestPad != nil else {
            log("input selftest: no guest pad (the guest's \(PadPort.name) service has not said hello)")
            return
        }
        var s = state
        s.buttons[BTN.SOUTH] = true
        s.axes[ABS.X] = 32767
        apply(s)
        s.buttons[BTN.SOUTH] = false
        s.axes[ABS.X] = 0
        apply(s)
    }

    /// --control-fifo `pad on|off|test|state` (DebugControl).
    func control(_ args: [String]) {
        switch args.first {
        case "on", "off":
            testPad = args.first == "on"
            reconcile()
        case "test":
            injectTestSequence()
        case "state":
            log("control: pad \(guestPad?.title ?? "none"), service \(serviceReady ? "ready" : "not ready"), "
                + "controller \(controller.map(GamepadBridge.displayName(of:)) ?? "none"), rumble \(rumble.level.strong) \(rumble.level.weak)")
        default:
            log("control: pad on|off|test|state")
        }
    }
}
