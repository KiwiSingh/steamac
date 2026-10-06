import Combine
import Foundation
import GameController
import IOKit
import IOKit.hid

/// The gamepad SteamOS sees: the virtio-input device's identity and layout, fixed at boot
/// (InputDevices.gamepad). Any connected controller drives it (GamepadBridge).
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

    /// Evdev key codes the device advertises. xpad: X/Y as BTN_X/BTN_Y. hid-playstation /
    /// hid-sony: the same codes by position (square BTN_WEST, triangle BTN_NORTH) plus digital
    /// L2/R2 next to the analog triggers.
    var buttonCodes: [UInt16] {
        let common = [BTN.SOUTH, BTN.EAST, BTN.NORTH, BTN.WEST, BTN.TL, BTN.TR,
                      BTN.SELECT, BTN.START, BTN.MODE, BTN.THUMBL, BTN.THUMBR]
        return sony ? common + [BTN.TL2, BTN.TR2] : common
    }

    /// The identity of this boot (logged with the reason).
    static func resolve(_ type: LauncherSettings.PadType) -> (GuestPad, String) {
        switch type {
        case .xbox360: return (.xbox360, "setting")
        case .dualSense: return (.dualSense, "setting")
        case .dualShock4: return (.dualShock4, "setting")
        case .auto:
            if let (pad, ids) = connectedSony() { return (pad, String(format: "auto: Sony %04x:%04x connected", ids.0, ids.1)) }
            return (.xbox360, "auto: no DualSense / DualShock 4 connected")
        }
    }

    /// A DualSense (Edge) / DualShock 4 among the Mac's HID devices. Read from the IORegistry:
    /// synchronous, unlike GameController's discovery (its controller list fills in only after the
    /// app has started, and the guest's devices must be fixed before the VM starts).
    static func connectedSony() -> (GuestPad, (Int, Int))? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(kIOHIDDeviceKey), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            func number(_ key: String) -> Int? {
                IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int
            }
            guard let vendor = number(kIOHIDVendorIDKey), vendor == 0x054c, let product = number(kIOHIDProductIDKey) else { continue }
            switch product {
            case 0x0ce6, 0x0df2: return (.dualSense, (vendor, product))              // DualSense, DualSense Edge
            case 0x05c4, 0x09cc, 0x0ba0: return (.dualShock4, (vendor, product))     // DualShock 4 v1, v2, USB adapter
            default: continue
            }
        }
        return nil
    }
}

/// Feeds the guest's virtual gamepad (GuestPad) from a GameController.framework extended gamepad
/// (Xbox, DualSense, DualShock, MFi, ...): Settings > Controller picks which one (first connected
/// by default), swaps A/B and X/Y for Nintendo-style layouts and applies a radial stick deadzone,
/// all while the VM runs.
final class GamepadBridge {
    private let device: InputDevice
    private let pad: GuestPad
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

    static let axisCodes: [UInt16] = [ABS.X, ABS.Y, ABS.Z, ABS.RX, ABS.RY, ABS.RZ, ABS.HAT0X, ABS.HAT0Y]

    init(device: InputDevice, pad: GuestPad, settings: LauncherSettings) {
        self.device = device
        self.pad = pad
        self.settings = settings
        state = GamepadBridge.rest(pad)
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
        apply(GamepadBridge.rest(self.pad))
        guard let pad = next?.extendedGamepad else {
            log("gamepad: none connected")
            return
        }
        log("gamepad active: \(next.map(GamepadBridge.displayName(of:)) ?? "?") -> virtual \(self.pad.title)")
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
        apply(GamepadBridge.read(pad, as: self.pad, swapABXY: settings.swapABXY, deadzone: Float(settings.stickDeadzone) / 100))
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
        let pressed = pad.buttonCodes.contains { next.buttons[$0]! && !state.buttons[$0]! }
        if let intercept, intercept(pressed) {
            // Nothing is queued for the paused guest; `state` stays what the guest last got, so
            // the first change after the wake sends the difference (a tapped wake button: none).
            return
        }
        var events: [(UInt16, UInt16, Int32)] = []
        for c in pad.buttonCodes where next.buttons[c] != state.buttons[c] {
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
