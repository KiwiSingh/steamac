import Combine
import Foundation
import GameController

/// Feeds the fixed virtual Xbox 360 pad from a GameController.framework extended gamepad (Xbox,
/// DualSense, DualShock, MFi, ...): Settings > Controller picks which one (first connected by
/// default), swaps A/B and X/Y for Nintendo-style layouts and applies a radial stick deadzone,
/// all while the VM runs.
final class GamepadBridge {
    private let device: InputDevice
    private let settings: LauncherSettings
    private var controller: GCController?
    private var state = PadState()
    private var observers: [NSObjectProtocol] = []
    private var subscriptions: [AnyCancellable] = []
    /// While the VM is paused (suspended, guest asleep): called before anything is sent, with
    /// whether a button went down; true = keep it from the guest (a press may wake it).
    var intercept: ((_ buttonPressed: Bool) -> Bool)?

    struct PadState: Equatable {
        var buttons: [UInt16: Bool] = [:]
        var axes: [UInt16: Int32] = [:]
    }

    static let buttonCodes: [UInt16] = [BTN.SOUTH, BTN.EAST, BTN.NORTH, BTN.WEST, BTN.TL, BTN.TR,
                                        BTN.SELECT, BTN.START, BTN.MODE, BTN.THUMBL, BTN.THUMBR]
    static let axisCodes: [UInt16] = [ABS.X, ABS.Y, ABS.Z, ABS.RX, ABS.RY, ABS.RZ, ABS.HAT0X, ABS.HAT0Y]

    init(device: InputDevice, settings: LauncherSettings) {
        self.device = device
        self.settings = settings
        for c in GamepadBridge.buttonCodes { state.buttons[c] = false }
        for a in GamepadBridge.axisCodes { state.axes[a] = 0 }
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
        subscriptions.append(settings.$swapABXY.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in self?.refresh() })
        subscriptions.append(settings.$stickDeadzone.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in self?.refresh() })
        GCController.startWirelessControllerDiscovery(completionHandler: nil)
        selectController()
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
        // Release everything the previous controller held.
        apply(PadState(buttons: Dictionary(uniqueKeysWithValues: GamepadBridge.buttonCodes.map { ($0, false) }),
                       axes: Dictionary(uniqueKeysWithValues: GamepadBridge.axisCodes.map { ($0, 0) })))
        guard let pad = next?.extendedGamepad else {
            log("gamepad: none connected")
            return
        }
        log("gamepad active: \(next.map(GamepadBridge.displayName(of:)) ?? "?") -> virtual Xbox 360 pad")
        // Keep the Home/PS button for the guest (Steam button) instead of macOS.
        pad.buttonHome?.preferredSystemGestureState = .disabled
        pad.buttonOptions?.preferredSystemGestureState = .disabled
        pad.buttonMenu.preferredSystemGestureState = .disabled
        pad.valueChangedHandler = { [weak self] pad, _ in self?.update(from: pad) }
        update(from: pad)
    }

    /// Swap / deadzone changed: resend the current state with the new mapping.
    private func refresh() {
        if let pad = controller?.extendedGamepad { update(from: pad) }
    }

    private func update(from pad: GCExtendedGamepad) {
        apply(GamepadBridge.read(pad, swapABXY: settings.swapABXY, deadzone: Float(settings.stickDeadzone) / 100))
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

    static func read(_ p: GCExtendedGamepad, swapABXY: Bool, deadzone: Float) -> PadState {
        var s = PadState()
        let (south, east) = swapABXY ? (p.buttonB, p.buttonA) : (p.buttonA, p.buttonB)
        let (west, north) = swapABXY ? (p.buttonY, p.buttonX) : (p.buttonX, p.buttonY)
        s.buttons[BTN.SOUTH] = south.isPressed
        s.buttons[BTN.EAST] = east.isPressed
        s.buttons[BTN.NORTH] = west.isPressed    // xpad: Xbox "X" (west position) is BTN_X
        s.buttons[BTN.WEST] = north.isPressed    // xpad: Xbox "Y" (north position) is BTN_Y
        s.buttons[BTN.TL] = p.leftShoulder.isPressed
        s.buttons[BTN.TR] = p.rightShoulder.isPressed
        s.buttons[BTN.SELECT] = p.buttonOptions?.isPressed ?? false
        s.buttons[BTN.START] = p.buttonMenu.isPressed
        s.buttons[BTN.MODE] = p.buttonHome?.isPressed ?? false
        s.buttons[BTN.THUMBL] = p.leftThumbstickButton?.isPressed ?? false
        s.buttons[BTN.THUMBR] = p.rightThumbstickButton?.isPressed ?? false
        // xpad reports Y axes inverted relative to GameController (up = negative).
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
        let pressed = GamepadBridge.buttonCodes.contains { next.buttons[$0]! && !state.buttons[$0]! }
        if let intercept, intercept(pressed) {
            // Nothing is queued for the paused guest; `state` stays what the guest last got, so
            // the first change after the wake sends the difference (a tapped wake button: none).
            return
        }
        var events: [(UInt16, UInt16, Int32)] = []
        for c in GamepadBridge.buttonCodes where next.buttons[c] != state.buttons[c] {
            events.append((EV.KEY, c, next.buttons[c]! ? 1 : 0))
        }
        for a in GamepadBridge.axisCodes where next.axes[a] != state.axes[a] {
            events.append((EV.ABS, a, next.axes[a]!))
        }
        state = next
        device.send(events)
    }

    /// --input-selftest: press/release A and push the left stick right, then return to rest.
    func injectTestSequence() {
        var s = state
        s.buttons[BTN.SOUTH] = true
        s.axes[ABS.X] = 32767
        apply(s)
        s.buttons[BTN.SOUTH] = false
        s.axes[ABS.X] = 0
        apply(s)
    }
}
