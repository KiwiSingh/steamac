import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Routes key events to the guest before AppKit's key-equivalent/menu machinery (which would
/// otherwise swallow Cmd-combos and their keyUps).
final class SteamacApplication: NSApplication {
    weak var router: WindowController?

    override func sendEvent(_ event: NSEvent) {
        if let router, router.handleKeyEvent(event) { return }
        super.sendEvent(event)
    }
}

final class WindowController: NSObject, NSWindowDelegate {
    let window: NSWindow
    let view: VMView
    private let inputs: VMInputs?
    private let mouseMode: MouseMode
    private let baseTitle: String
    var onCloseRequest: (() -> Void)?
    /// FX boot/shutdown overlay, layered over the Metal view.
    let overlay: OverlayView
    private var progress: BootProgress?
    private var overlayDismissed = false

    private var pressedKeys = Set<UInt16>()
    private var tabletButtons = Set<UInt16>()
    private var mouseButtons = Set<UInt16>()
    private var lastAbs: (Int32, Int32) = (-1, -1)
    private var captured = false
    private var relRemainder = (0.0, 0.0)
    private var wheelHiRemainder = (0.0, 0.0)   // (vertical, horizontal) in 1/120 notch units
    private var wheelLoAccum: (Int32, Int32) = (0, 0)
    private var scanoutSize: (Int, Int)
    /// Guest display should become (width, height) px: the window's content size in points.
    var onGuestSizeRequest: ((Int, Int) -> Void)?
    private var requestedGuestSize: (Int, Int)
    private var guestResizeWork: DispatchWorkItem?
    private var inFullScreenTransition = false
    static let minGuestSize = NSSize(width: 800, height: 500)
    /// Settle time after the last size change before the guest is asked to switch modes.
    static let guestResizeDebounce: TimeInterval = 0.25

    init(title: String, width: Int, height: Int, renderer: Renderer, inputs: VMInputs?, mouseMode: MouseMode) {
        self.inputs = inputs
        self.mouseMode = mouseMode
        self.baseTitle = title
        self.scanoutSize = (width, height)
        self.requestedGuestSize = (width, height)
        let rect = NSRect(x: 0, y: 0, width: width, height: height)
        let screen = WindowController.targetScreen()
        window = NSWindow(contentRect: rect, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false, screen: screen)
        view = VMView(frame: rect, renderer: renderer, contentPixelSize: CGSize(width: width, height: height))
        overlay = OverlayView(frame: rect)
        super.init()
        window.title = title
        window.contentView = view
        window.delegate = self
        window.collectionBehavior = [.fullScreenPrimary, .managed]
        window.acceptsMouseMovedEvents = true
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        window.contentMinSize = WindowController.minGuestSize
        fitToScreen(width: width, height: height)
        window.center()
        view.controller = self
        overlay.frame = view.bounds
        view.addSubview(overlay)
        updateTitle()
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(self.view)
        NSApp.activate()
    }

    /// The screen the window opens on: the one under the mouse pointer, else the main screen.
    static func targetScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }

    /// Initial content size: one guest pixel = one point (Retina: 2x2 physical pixels), shrunk to fit
    /// the screen's visible area below the title bar. Also the basis of the default EDID size.
    static func initialContentSize(width: Int, height: Int, screen: NSScreen?) -> NSSize {
        var size = NSSize(width: width, height: height)
        if let vf = screen?.visibleFrame {
            let chrome = NSWindow.frameRect(forContentRect: NSRect(origin: .zero, size: size),
                                            styleMask: [.titled, .closable, .miniaturizable, .resizable]).height - size.height
            let s = min(1, vf.width / size.width, (vf.height - chrome) / size.height)
            size = NSSize(width: (size.width * s).rounded(.down), height: (size.height * s).rounded(.down))
        }
        return size
    }

    private func fitToScreen(width: Int, height: Int) {
        window.setContentSize(WindowController.initialContentSize(width: width, height: height,
                                                                  screen: window.screen ?? NSScreen.main))
    }

    /// The guest switched its scanout size. The window does not follow (the guest follows the
    /// window); frames of any size are scaled to fit, so old-size frames bridge the switch.
    func scanoutResized(width: Int, height: Int) {
        view.contentPixelSize = CGSize(width: width, height: height)
        scanoutSize = (width, height)
        view.redraw()
    }

    /// Guest size for the current window: content size in points (one guest pixel per point),
    /// rounded down to even, clamped to [minGuestSize, VM.maxDisplaySide].
    func guestSizeForWindow() -> (Int, Int) {
        let s = view.bounds.size
        let maxSide = VM.maxDisplaySide & ~1
        let w = min(maxSide, max(Int(WindowController.minGuestSize.width), Int(s.width) & ~1))
        let h = min(maxSide, max(Int(WindowController.minGuestSize.height), Int(s.height) & ~1))
        return (w, h)
    }

    /// Debounced: never during a live drag or a fullscreen transition (the last frame is scaled
    /// meanwhile); fires once the size has been stable for `guestResizeDebounce`.
    private func scheduleGuestResize() {
        guestResizeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.window.inLiveResize, !self.inFullScreenTransition else { return }
            let size = self.guestSizeForWindow()
            guard size != self.requestedGuestSize else { return }
            self.requestedGuestSize = size
            self.onGuestSizeRequest?(size.0, size.1)
        }
        guestResizeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + WindowController.guestResizeDebounce, execute: work)
    }

    func windowDidEndLiveResize(_ notification: Notification) { scheduleGuestResize() }

    /// Programmatic / zoom-button resizes (no live resize session).
    func windowDidResize(_ notification: Notification) {
        if !window.inLiveResize && !inFullScreenTransition { scheduleGuestResize() }
    }

    func windowWillEnterFullScreen(_ notification: Notification) { inFullScreenTransition = true }
    func windowWillExitFullScreen(_ notification: Notification) { inFullScreenTransition = true }
    func windowDidEnterFullScreen(_ notification: Notification) { inFullScreenTransition = false; scheduleGuestResize() }
    func windowDidExitFullScreen(_ notification: Notification) { inFullScreenTransition = false; scheduleGuestResize() }
    func windowDidFailToEnterFullScreen(_ window: NSWindow) { inFullScreenTransition = false }
    func windowDidFailToExitFullScreen(_ window: NSWindow) { inFullScreenTransition = false }

    func setStatus(_ status: String?) {
        window.title = status.map { "\(baseTitle) — \($0)" } ?? baseTitle
    }

    private func updateTitle() {
        if captured {
            setStatus("pointer grabbed (Ctrl+Option releases)")
        } else if inputs != nil && mouseMode == .capture {
            setStatus("click to grab pointer")
        } else {
            setStatus(nil)
        }
    }

    // MARK: overlay

    /// Boot overlay follows `progress`: hides on `ready` (or when the user clicks / presses a key,
    /// or after 15 minutes), comes back for shutdown/reboot.
    func attach(progress: BootProgress) {
        self.progress = progress
        overlay.update(progress.state)
        let previous = progress.onChange
        progress.onChange = { [weak self] s in previous?(s); self?.overlay.update(s) }
        let previousReady = progress.onReady
        progress.onReady = { [weak self] in previousReady?(); self?.overlay.hide() }
        let previousShutdown = progress.onShutdown
        progress.onShutdown = { [weak self] reboot in
            previousShutdown?(reboot)
            self?.overlayDismissed = false
            self?.overlay.show()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15 * 60) { [weak self] in
            guard let self, let p = self.progress, p.state.phase == .boot, self.overlay.shown else { return }
            log("overlay: still booting after 15 min, hiding the overlay")
            self.overlay.hide()
        }
    }

    /// Menu "Show Boot Overlay".
    func toggleOverlay() {
        if overlay.shown { overlay.hide() } else { overlay.show() }
    }

    /// The user interacted with the guest: a visible overlay gets out of the way (input still goes through).
    private func userInput() {
        guard overlay.shown, !overlayDismissed else { return }
        overlayDismissed = true
        overlay.hide()
    }

    /// Read back the next presented drawable; `composite` = drawable with the overlay on top, at 2x.
    func captureWindow(_ done: @escaping (_ drawable: CGImage?, _ composite: CGImage?) -> Void) {
        view.renderer.captureNextDraw = { [weak self] bytes, w, h in
            DispatchQueue.main.async {
                let drawable = PNG.image(bgra: bytes, width: w, height: h)
                done(drawable, self?.overlay.renderImage(scale: 2, under: drawable))
            }
        }
        view.redraw()
    }

    // MARK: NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        onCloseRequest?()
        return false
    }

    func windowDidResignKey(_ notification: Notification) { releaseAll() }
    func windowDidMiniaturize(_ notification: Notification) { releaseAll() }

    // MARK: keyboard

    /// Returns true if the event was consumed (only while our window is key).
    func handleKeyEvent(_ e: NSEvent) -> Bool {
        guard e.type == .keyDown || e.type == .keyUp || e.type == .flagsChanged,
              e.window === window || (e.window == nil && window.isKeyWindow), window.isKeyWindow else { return false }
        return processKey(e)
    }

    /// Key/flags event -> host shortcut or guest evdev key.
    func processKey(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)

        switch e.type {
        case .keyDown:
            userInput()
            if mods.contains([.control, .command]) {
                switch Int(e.keyCode) {
                case kVK_ANSI_F: toggleFullScreen(); return true
                case kVK_ANSI_G: captured ? releasePointer() : grabPointer(); return true
                default: break
                }
            }
            if e.isARepeat { return true }   // guest does autorepeat
            guard let code = Keymap.linuxKey(e.keyCode) else { return true }
            if pressedKeys.insert(code).inserted { sendKey(code, true) }
            return true
        case .keyUp:
            guard let code = Keymap.linuxKey(e.keyCode) else { return true }
            if pressedKeys.remove(code) != nil { sendKey(code, false) }
            return true
        default: // flagsChanged
            if Int(e.keyCode) == kVK_CapsLock {
                // macOS reports the lock *state*; evdev wants a key press each time.
                sendKey(KEY.CAPSLOCK, true)
                sendKey(KEY.CAPSLOCK, false)
            } else if let mask = Keymap.modifierMask(e.keyCode), let code = Keymap.linuxKey(e.keyCode) {
                let down = (UInt(e.modifierFlags.rawValue) & mask) != 0
                if down, pressedKeys.insert(code).inserted { sendKey(code, true) }
                if !down, pressedKeys.remove(code) != nil { sendKey(code, false) }
            }
            if captured && mods.contains([.control, .option]) { releasePointer() }
            return true
        }
    }

    private func sendKey(_ code: UInt16, _ down: Bool) {
        inputs?.keyboard.send([(EV.KEY, code, down ? 1 : 0)])
    }

    private func toggleFullScreen() {
        window.toggleFullScreen(nil)
    }

    // MARK: pointer

    func grabPointer() {
        guard inputs != nil, !captured else { return }
        releaseButtons()
        captured = true
        relRemainder = (0, 0)
        CGAssociateMouseAndMouseCursorPosition(0)
        NSCursor.hide()
        updateTitle()
    }

    func releasePointer() {
        guard captured else { return }
        releaseButtons()
        captured = false
        CGAssociateMouseAndMouseCursorPosition(1)
        NSCursor.unhide()
        lastAbs = (-1, -1)
        updateTitle()
    }

    private func releaseButtons() {
        for b in tabletButtons { inputs?.tablet.send([(EV.KEY, b, 0)]) }
        for b in mouseButtons { inputs?.mouse.send([(EV.KEY, b, 0)]) }
        tabletButtons.removeAll()
        mouseButtons.removeAll()
    }

    func releaseAll() {
        for k in pressedKeys { sendKey(k, false) }
        pressedKeys.removeAll()
        releasePointer()
        releaseButtons()
    }

    private func button(for e: NSEvent) -> UInt16 {
        switch e.type {
        case .leftMouseDown, .leftMouseUp: return BTN.LEFT
        case .rightMouseDown, .rightMouseUp: return BTN.RIGHT
        default:
            switch e.buttonNumber {
            case 2: return BTN.MIDDLE
            case 3: return BTN.SIDE
            default: return BTN.EXTRA
            }
        }
    }

    private func inPicture(_ e: NSEvent) -> Bool {
        view.fitRect.contains(view.convert(e.locationInWindow, from: nil))
    }

    private func moveAbsolute(_ e: NSEvent) {
        guard let inputs else { return }
        let (ux, uy) = view.unitPoint(for: e)
        let x = Int32((ux * Double(InputDevices.absMax)).rounded())
        let y = Int32((uy * Double(InputDevices.absMax)).rounded())
        guard (x, y) != lastAbs else { return }
        lastAbs = (x, y)
        inputs.tablet.send([(EV.ABS, ABS.X, x), (EV.ABS, ABS.Y, y)])
    }

    private func moveRelative(_ e: NSEvent) {
        guard let inputs else { return }
        let fx = Double(e.deltaX) + relRemainder.0
        let fy = Double(e.deltaY) + relRemainder.1
        let dx = Int32(fx.rounded(.towardZero)), dy = Int32(fy.rounded(.towardZero))
        relRemainder = (fx - Double(dx), fy - Double(dy))
        var ev: [(UInt16, UInt16, Int32)] = []
        if dx != 0 { ev.append((EV.REL, REL.X, dx)) }
        if dy != 0 { ev.append((EV.REL, REL.Y, dy)) }
        inputs.mouse.send(ev)
    }

    func pointerMoved(_ e: NSEvent) {
        if captured { moveRelative(e) } else { moveAbsolute(e) }
    }

    func pointerButton(_ e: NSEvent, down: Bool) {
        guard let inputs else { return }
        let b = button(for: e)
        if down { userInput() }
        // Captured: everything on the relative mouse. Absolute mode: side/extra buttons also go
        // there, because the tablet only advertises LEFT/RIGHT/MIDDLE (see InputDevices).
        let viaMouse = captured || !InputDevices.tabletButtons.contains(b)
        if viaMouse && (captured || !down || inPicture(e)) {
            if down ? mouseButtons.insert(b).inserted : mouseButtons.remove(b) != nil {
                inputs.mouse.send([(EV.KEY, b, down ? 1 : 0)])
            }
            return
        }
        if down {
            guard inPicture(e) else { return }
            if mouseMode == .capture {
                grabPointer()   // the grabbing click itself is not forwarded
                return
            }
            moveAbsolute(e)
            if tabletButtons.insert(b).inserted { inputs.tablet.send([(EV.KEY, b, 1)]) }
        } else {
            if tabletButtons.remove(b) != nil { inputs.tablet.send([(EV.KEY, b, 0)]) }
        }
    }

    func scroll(_ e: NSEvent) {
        guard inputs != nil else { return }
        if !captured && !inPicture(e) { return }
        if !captured { moveAbsolute(e) }
        // 120 = one wheel notch. Precise (trackpad) deltas are points: ~30 pt per notch.
        let scale = e.hasPreciseScrollingDeltas ? 4.0 : 120.0
        sendWheel(hiResY: Double(e.scrollingDeltaY) * scale, hiResX: -Double(e.scrollingDeltaX) * scale)
    }

    /// Wheel motion in 1/120-notch units (positive y = up, positive x = right), emitted as
    /// REL_*_HI_RES plus whole REL_WHEEL/REL_HWHEEL notches.
    func sendWheel(hiResY: Double, hiResX: Double) {
        guard let inputs else { return }
        let vy = hiResY + wheelHiRemainder.0
        let vx = hiResX + wheelHiRemainder.1
        let hy = Int32(vy.rounded(.towardZero)), hx = Int32(vx.rounded(.towardZero))
        wheelHiRemainder = (vy - Double(hy), vx - Double(hx))
        wheelLoAccum.0 += hy
        wheelLoAccum.1 += hx
        let ly = wheelLoAccum.0 / 120, lx = wheelLoAccum.1 / 120
        wheelLoAccum.0 -= ly * 120
        wheelLoAccum.1 -= lx * 120
        var ev: [(UInt16, UInt16, Int32)] = []
        if hy != 0 { ev.append((EV.REL, REL.WHEEL_HI_RES, hy)) }
        if hx != 0 { ev.append((EV.REL, REL.HWHEEL_HI_RES, hx)) }
        if ly != 0 { ev.append((EV.REL, REL.WHEEL, ly)) }
        if lx != 0 { ev.append((EV.REL, REL.HWHEEL, lx)) }
        (captured ? inputs.mouse : inputs.tablet).send(ev)
    }
}

enum MainMenu {
    static func install(target: AnyObject, shutdown: Selector, forceQuit: Selector,
                        fullscreen: Selector, grab: Selector, overlay: Selector) {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(item("Shut Down Guest", shutdown, target))
        appMenu.addItem(item("Force Quit", forceQuit, target))
        let viewItem = NSMenuItem()
        main.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        viewItem.submenu = viewMenu
        viewMenu.addItem(item("Toggle Full Screen (Ctrl+Cmd+F)", fullscreen, target))
        viewMenu.addItem(item("Grab Pointer (Ctrl+Cmd+G; Ctrl+Option releases)", grab, target))
        viewMenu.addItem(item("Show Boot Overlay", overlay, target))
        NSApp.mainMenu = main
    }

    private static func item(_ title: String, _ action: Selector, _ target: AnyObject) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = target
        return i
    }
}
