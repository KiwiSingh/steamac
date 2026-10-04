// OS-level mouse input for launcher tests (goes through the window server like a real mouse).
// usage: cgpost <window-title-substring> <command>...
//   move UX UY        cursor to (UX, UY) in 0..1 of the window's content area (top-left origin)
//   click left|right  press + release at the current position
//   wheel N           N line notches (positive = up)
//   sleep S
// Window geometry comes from CGWindowListCopyWindowInfo (content = frame minus the title bar).
import CoreGraphics
import Foundation

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2 else { print("usage: cgpost TITLE cmd..."); exit(2) }
let title = args[0]

func windowBounds() -> CGRect? {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    for w in list {
        let name = w[kCGWindowName as String] as? String ?? ""
        let owner = w[kCGWindowOwnerName as String] as? String ?? ""
        guard name.contains(title) || owner.contains(title),
              let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
        return CGRect(x: b["X"]!, y: b["Y"]!, width: b["Width"]!, height: b["Height"]!)
    }
    return nil
}

guard let frame = windowBounds() else { print("window not found"); exit(1) }
let titleBar: CGFloat = 28
let content = CGRect(x: frame.minX, y: frame.minY + titleBar, width: frame.width, height: frame.height - titleBar)
print("window frame \(frame), content \(content)")
var pos = CGPoint(x: content.midX, y: content.midY)
let src = CGEventSource(stateID: .hidSystemState)

func post(_ e: CGEvent?) { e?.post(tap: .cghidEventTap); usleep(8000) }

var i = 1
while i < args.count {
    switch args[i] {
    case "move":
        let ux = Double(args[i + 1])!, uy = Double(args[i + 2])!
        i += 2
        let target = CGPoint(x: content.minX + content.width * ux, y: content.minY + content.height * uy)
        // 10 intermediate steps, like a real mouse.
        for s in 1...10 {
            let t = Double(s) / 10
            let p = CGPoint(x: pos.x + (target.x - pos.x) * t, y: pos.y + (target.y - pos.y) * t)
            post(CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left))
        }
        pos = target
    case "click":
        let right = args[i + 1] == "right"
        i += 1
        post(CGEvent(mouseEventSource: src, mouseType: right ? .rightMouseDown : .leftMouseDown, mouseCursorPosition: pos, mouseButton: right ? .right : .left))
        post(CGEvent(mouseEventSource: src, mouseType: right ? .rightMouseUp : .leftMouseUp, mouseCursorPosition: pos, mouseButton: right ? .right : .left))
    case "wheel":
        let n = Int32(args[i + 1])!
        i += 1
        post(CGEvent(scrollWheelEvent2Source: src, units: .line, wheelCount: 1, wheel1: n, wheel2: 0, wheel3: 0))
    case "sleep":
        usleep(useconds_t(Double(args[i + 1])! * 1_000_000))
        i += 1
    default:
        print("unknown \(args[i])"); exit(2)
    }
    i += 1
}
print("posted; cursor at \(pos)")
