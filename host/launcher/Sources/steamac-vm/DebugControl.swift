import AppKit
import Carbon.HIToolbox
import Foundation

/// `--control-fifo PATH`: scripted window input for automated tests, on the main thread. Pointer
/// moves and buttons are synthesized NSEvents dispatched through NSApplication.sendEvent (the
/// same AppKit routing real mouse events take: window → first responder / hit-tested VMView);
/// wheel, `rel` and keys call the controller directly:
///   move UX UY            pointer to (UX, UY) in 0..1 picture coordinates (top-left origin)
///   button B down|up      B = left | right | middle (at the last `move` position)
///   click B               button down + up
///   wheel N               N wheel notches (positive = up)
///   rel DX DY             relative motion in points (as when the mouse is captured)
///   key KEYCODE           macOS virtual key code, press + release
///   grab | release        capture / release the mouse
///   menu game|global      toggle Mouse > Capture Mouse in This Game / Auto-Capture Mouse in Games
///   guest LINE            handle LINE as if the guest had sent it on fx.progress
///   dump PATH             frame + window dump (as SIGUSR1, to PATH)
enum DebugControl {
    static func start(path: String, window wc: WindowController, progress: BootProgress,
                      dump: @escaping (String) -> Void) {
        unlink(path)
        guard mkfifo(path, 0o600) == 0 else {
            log("control: cannot create FIFO \(path): \(String(cString: strerror(errno)))")
            return
        }
        log("control: accepting commands on \(path)")
        let t = Thread {
            while true {
                // Re-open after each writer closes (echo cmd > fifo).
                guard let f = fopen(path, "r") else { return }
                var line: UnsafeMutablePointer<CChar>?
                var cap = 0
                while getline(&line, &cap, f) > 0 {
                    let cmd = String(cString: line!).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !cmd.isEmpty {
                        DispatchQueue.main.sync { handle(cmd, wc, progress, dump) }
                    }
                }
                free(line)
                fclose(f)
            }
        }
        t.name = "control-fifo"
        t.start()
    }

    nonisolated(unsafe) private static var lastPoint = NSPoint.zero

    private static func windowPoint(_ ux: Double, _ uy: Double, _ wc: WindowController) -> NSPoint {
        let fit = wc.view.fitRect
        let p = NSPoint(x: fit.minX + CGFloat(ux) * fit.width, y: fit.maxY - CGFloat(uy) * fit.height)
        return wc.view.convert(p, to: nil)
    }

    private static func mouseEvent(_ type: NSEvent.EventType, _ wc: WindowController, button: Int = 0) -> NSEvent? {
        NSEvent.mouseEvent(with: type, location: lastPoint, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: wc.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                           pressure: type == .leftMouseDown ? 1 : 0)
    }

    private static func buttonEvent(_ name: String, down: Bool, _ wc: WindowController) {
        let type: NSEvent.EventType
        switch name {
        case "right": type = down ? .rightMouseDown : .rightMouseUp
        case "middle": type = down ? .otherMouseDown : .otherMouseUp
        default: type = down ? .leftMouseDown : .leftMouseUp
        }
        if let e = mouseEvent(type, wc) { NSApp.sendEvent(e) }
    }

    private static func handle(_ cmd: String, _ wc: WindowController, _ progress: BootProgress, _ dump: (String) -> Void) {
        let p = cmd.split(separator: " ", maxSplits: 1).map(String.init)
        let args = p.count > 1 ? p[1].split(separator: " ").map(String.init) : []
        log("control: \(cmd)")
        switch p[0] {
        case "move":
            guard args.count == 2, let ux = Double(args[0]), let uy = Double(args[1]) else { break }
            lastPoint = windowPoint(ux, uy, wc)
            if let e = mouseEvent(.mouseMoved, wc) { NSApp.sendEvent(e) }
        case "button":
            guard args.count == 2 else { break }
            buttonEvent(args[0], down: args[1] == "down", wc)
        case "click":
            buttonEvent(args.first ?? "left", down: true, wc)
            buttonEvent(args.first ?? "left", down: false, wc)
        case "wheel":
            guard let n = Double(args.first ?? "") else { break }
            if let e = mouseEvent(.mouseMoved, wc) { NSApp.sendEvent(e) }
            wc.sendWheel(hiResY: n * 120, hiResX: 0)
        case "rel":
            guard args.count == 2, let dx = Double(args[0]), let dy = Double(args[1]) else { break }
            wc.moveRelative(dx: dx, dy: dy)
        case "key":
            guard let code = UInt16(args.first ?? "") else { break }
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: wc.window.windowNumber, context: nil, characters: "",
                                            charactersIgnoringModifiers: "", isARepeat: false, keyCode: code) {
                    _ = wc.processKey(e)
                }
            }
        case "grab": wc.grabPointer()
        case "menu":   // menu game | menu global: toggle like the Mouse menu items
            if args.first == "game" { wc.toggleGameAutoCapture(nil) } else { wc.toggleGlobalAutoCapture(nil) }
        case "release": wc.releasePointer()
        case "guest": progress.guestLine(p.count > 1 ? p[1] : "")
        case "dump": dump(args.first ?? "control-dump.png")
        default: log("control: unknown command")
        }
    }
}
