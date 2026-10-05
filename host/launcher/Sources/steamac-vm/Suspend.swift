import AppKit
import CKrun
import Darwin
import Foundation
import QuartzCore

/// In-memory suspend of the running VM (Settings > General "When closing the window: Suspend",
/// menu Suspend / Ctrl+Cmd+S): krun_pause stops every vCPU and the guest's audio (libkrun patch
/// 0016), the window hides and a menu-bar item offers Resume / Shut Down SteamOS while the app
/// keeps running (Dock icon). Nothing is written to disk: the guest's memory and the host's GPU
/// state (virglrenderer, MoltenVK, Metal) cannot be saved, so the suspended state lives only as
/// long as this process. Resume (Dock icon, the menu-bar item, the app menu, opening the app
/// again) shows the window, continues the vCPUs and restores the mouse capture; a "Resuming…"
/// chip stays up until the guest's next frame, or 0.5 s if the guest does no GPU work (an idle
/// Steam UI draws nothing). The guest's monotonic clock does not see the
/// suspended time (libkrun shifts the virtual counter); its wall clock is set right after the
/// resume from this process's clock (ClockPort → fx-clock-sync.service in the guest).
final class SuspendController: NSObject, NSMenuDelegate {
    private let ctx: UInt32
    private let clock: ClockPort?
    private weak var window: WindowController?
    private let presenter: Presenter
    private let stall: StallMonitor
    private let gamePause: GamePause
    /// krun_gpu_get_activity (nil: no counters).
    private let gpuCounters: () -> StallMonitor.Counters?
    var onShutdown: (() -> Void)?
    /// After a suspend (true) / resume (false).
    var onSuspendedChange: ((Bool) -> Void)?
    private(set) var suspended = false
    /// The menu-bar item's button and menu (control FIFO `status`).
    var statusButton: NSStatusBarButton? { statusItem?.button }
    var statusMenu: NSMenu? { statusItem?.menu }
    private var suspendedAt: Date?
    private var wasCaptured = false
    private var wasFullScreen = false
    private var statusItem: NSStatusItem?
    private var memoryItem: NSMenuItem?
    private var chipTimers: [DispatchWorkItem] = []
    private var chipShownAt: CFTimeInterval = 0
    /// Longest the "Resuming…" chip waits for a guest frame.
    static let chipTimeout: TimeInterval = 2.5
    /// Without GPU work by then the guest is idle (a still Steam UI draws nothing): hide.
    static let chipIdleCheck: TimeInterval = 0.5

    init(ctx: UInt32, clock: ClockPort?, window: WindowController, presenter: Presenter, stall: StallMonitor,
         gamePause: GamePause, gpuCounters: @escaping () -> StallMonitor.Counters?) {
        self.ctx = ctx
        self.clock = clock
        self.window = window
        self.presenter = presenter
        self.stall = stall
        self.gamePause = gamePause
        self.gpuCounters = gpuCounters
    }

    /// Freeze the VM and hide the window. Returns false if it could not be paused.
    @discardableResult
    func suspend(origin: String) -> Bool {
        guard !suspended, let wc = window else { return false }
        wasCaptured = wc.pointerCaptured
        wc.releaseAll()   // key / button releases are queued before the guest stops
        gamePause.vmSuspended = true
        stall.stop()
        let t0 = CACurrentMediaTime()
        let r = krun_pause(ctx)
        guard r == 0 else {
            log("suspend: krun_pause failed: \(r) (\(String(cString: strerror(-r))))")
            gamePause.vmSuspended = false
            stall.resumeAfterSuspend()
            return false
        }
        suspended = true
        suspendedAt = Date()
        log("suspend: VM paused in \(String(format: "%.1f", (CACurrentMediaTime() - t0) * 1000)) ms (\(origin)); "
            + "\(SuspendController.memoryText() ?? "memory unknown")")
        wc.holdGuestSize = true
        endChip(nil)
        wasFullScreen = wc.window.styleMask.contains(.fullScreen)
        if wasFullScreen {
            // An ordered-out full-screen window would leave its empty Space behind.
            wc.onDidExitFullScreen = { [weak self, weak wc] in
                guard let self, self.suspended else { return }
                wc?.window.orderOut(nil)
            }
            wc.window.toggleFullScreen(nil)
        } else {
            wc.window.orderOut(nil)
        }
        showStatusItem()
        onSuspendedChange?(true)
        return true
    }

    /// Show the window and let the VM run again.
    func resume(origin: String) {
        guard suspended, let wc = window else { return }
        let seconds = suspendedAt.map { Date().timeIntervalSince($0) } ?? 0
        if quitPrompt != nil {
            log("quit while suspended: prompt closed, SteamOS resumes (\(origin))")
            closeQuitPrompt()
        }
        removeStatusItem()
        wc.onDidExitFullScreen = nil
        endChip(nil)
        wc.resumeChip.show()
        chipShownAt = CACurrentMediaTime()
        presenter.onNextFrame = { [weak self] in self?.endChip("first guest frame") }
        // The guest is still frozen: these are the counters it left off with.
        let before = gpuCounters()
        let idle = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let now = self.gpuCounters()
            if before?.ctrl == now?.ctrl && before?.ring == now?.ring { self.endChip("guest GPU idle") }
        }
        let timeout = DispatchWorkItem { [weak self] in self?.endChip("timeout") }
        chipTimers = [idle, timeout]
        DispatchQueue.main.asyncAfter(deadline: .now() + SuspendController.chipIdleCheck, execute: idle)
        DispatchQueue.main.asyncAfter(deadline: .now() + SuspendController.chipTimeout, execute: timeout)
        wc.show()
        if wasFullScreen && !wc.window.styleMask.contains(.fullScreen) { wc.window.toggleFullScreen(nil) }
        let r = krun_resume(ctx)
        if r != 0 { log("resume: krun_resume failed: \(r) (\(String(cString: strerror(-r))))") }
        else if let clock, !clock.sendTime() { log("resume: cannot send the time to the guest (fx.clock)") }
        suspended = false
        suspendedAt = nil
        wc.holdGuestSize = false
        stall.resumeAfterSuspend()
        gamePause.vmSuspended = false
        if wasCaptured { wc.grabPointer() }
        log("resume: VM running again after \(String(format: "%.1f", seconds)) s suspended (\(origin))")
        onSuspendedChange?(false)
    }

    /// Take the "Resuming…" chip down (`why` nil: without animation or log, e.g. on suspend).
    private func endChip(_ why: String?) {
        chipTimers.forEach { $0.cancel() }
        chipTimers = []
        presenter.onNextFrame = nil
        guard let wc = window else { return }
        guard let why else { return wc.resumeChip.hide(animated: false) }
        wc.resumeChip.hide()
        log("resume: \"Resuming…\" chip hidden after \(Int((CACurrentMediaTime() - chipShownAt) * 1000)) ms (\(why))")
    }

    // MARK: Quit while suspended

    private var quitPrompt: NSAlert?
    private var quitConfirmed: (() -> Void)?

    /// Cmd+Q / Dock Quit while suspended: "SteamOS is suspended" with Shut Down SteamOS / Cancel.
    /// A regular window, not NSAlert.runModal: the main queue keeps running (signals, the
    /// supervisor's reopen, control FIFO), and a resume by any other path closes it.
    func askQuit(onConfirm: @escaping () -> Void) {
        quitConfirmed = onConfirm
        NSApp.activate()
        if let shown = quitPrompt { return shown.window.makeKeyAndOrderFront(nil) }
        let alert = NSAlert()
        alert.messageText = "SteamOS is suspended"
        alert.informativeText = "Quitting FX Steam Launcher shuts SteamOS down: it resumes and shuts down cleanly. "
            + "The suspended state (and a running game's unsaved progress) is not kept."
        let shutdown = alert.addButton(withTitle: "Shut Down SteamOS")
        shutdown.target = self
        shutdown.action = #selector(quitPromptShutdown)
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.target = self
        cancel.action = #selector(quitPromptCancel)
        alert.layout()
        (alert.window as? NSPanel)?.hidesOnDeactivate = false
        alert.window.center()
        alert.window.makeKeyAndOrderFront(nil)
        quitPrompt = alert
        log("quit while suspended: asking (Shut Down SteamOS / Cancel)")
    }

    private func closeQuitPrompt() {
        quitPrompt?.window.orderOut(nil)
        quitPrompt = nil
        quitConfirmed = nil
    }

    @objc private func quitPromptShutdown() {
        let confirmed = quitConfirmed
        closeQuitPrompt()
        log("quit while suspended: shutting SteamOS down")
        confirmed?()
    }

    @objc private func quitPromptCancel() {
        closeQuitPrompt()
        log("quit while suspended: cancelled; SteamOS stays suspended")
    }

    /// Control FIFO `quit-prompt shutdown|cancel|dump PATH`: press a button / PNG of the prompt.
    func controlQuitPrompt(_ args: [String]) {
        guard let alert = quitPrompt else { return log("control: no quit prompt open") }
        switch args.first {
        case "shutdown": alert.buttons[0].performClick(nil)
        case "cancel": alert.buttons[1].performClick(nil)
        case "dump":
            let path = args.dropFirst().first ?? "quit-prompt.png"
            guard let view = alert.window.contentView?.superview ?? alert.window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]), (try? png.write(to: URL(fileURLWithPath: path))) != nil {
                log("control: quit prompt dumped to \(path) (window \(alert.window.windowNumber), visible \(alert.window.isVisible))")
            }
        default: log("control: quit-prompt shutdown|cancel|dump PATH")
        }
    }

    // MARK: menu-bar item

    private func showStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "pause.circle", accessibilityDescription: "SteamOS suspended")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "SteamOS suspended — FX Steam Launcher"
        }
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        let title = NSMenuItem(title: "SteamOS suspended", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        let memory = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        memory.isEnabled = false
        menu.addItem(memory)
        memoryItem = memory
        menu.addItem(.separator())
        let resume = NSMenuItem(title: "Resume", action: #selector(menuResume), keyEquivalent: "")
        resume.target = self
        menu.addItem(resume)
        let shutdown = NSMenuItem(title: "Shut Down SteamOS", action: #selector(menuShutdown), keyEquivalent: "")
        shutdown.target = self
        menu.addItem(shutdown)
        menu.addItem(.separator())
        let note = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        note.attributedTitle = NSAttributedString(
            string: "Suspended state is kept while FX Steam Launcher is running.",
            attributes: [.font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.secondaryLabelColor])
        note.isEnabled = false
        menu.addItem(note)
        item.menu = menu
        statusItem = item
        updateMemoryItem()
    }

    private func removeStatusItem() {
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
        memoryItem = nil
    }

    private func updateMemoryItem() {
        let since = suspendedAt.map { DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .short) } ?? "?"
        memoryItem?.title = "Since \(since) · \(SuspendController.memoryText() ?? "memory unknown")"
    }

    func menuWillOpen(_ menu: NSMenu) { updateMemoryItem() }

    @objc private func menuResume() { resume(origin: "menu bar") }
    @objc private func menuShutdown() { onShutdown?() }

    /// Control FIFO `status dump PATH`: the menu's items (logged) and the menu-bar button (PNG).
    func dumpStatusItem(to path: String) {
        guard let item = statusItem else { return log("control: no menu-bar item (not suspended)") }
        updateMemoryItem()
        let titles = item.menu?.items.map { i -> String in
            if i.isSeparatorItem { return "—" }
            let title = i.title.isEmpty ? i.attributedTitle?.string ?? "" : i.title
            return title + (i.isEnabled ? "" : " (disabled)")
        } ?? []
        log("control: menu-bar item: \(item.button?.toolTip ?? "") — menu: " + titles.joined(separator: " | "))
        guard let button = item.button, let rep = button.bitmapImageRepForCachingDisplay(in: button.bounds) else { return }
        button.cacheDisplay(in: button.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]), (try? png.write(to: URL(fileURLWithPath: path))) != nil {
            log("control: menu-bar button dumped to \(path)")
        }
    }

    /// "12.4 GB of memory in use" (this process's physical footprint: guest RAM touched so
    /// far plus the host GPU state).
    static func memoryText() -> String? {
        guard let bytes = footprint() else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory) + " of memory in use"
    }

    static func footprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? info.phys_footprint : nil
    }
}

/// The `fx.clock` virtio-console port (host → guest only): `time <unix_ns>` after every resume.
/// The guest's root service fx-clock-sync (guest/progress-agent/src/clock.rs) steps its wall
/// clock forward to it; the monotonic clock keeps hiding the suspended time.
final class ClockPort {
    static let name = "fx.clock"
    /// Handed to libkrun: host → guest data is read from here.
    let guestInputFd: Int32
    /// Handed to libkrun: the guest never writes; /dev/null.
    let guestOutputFd: Int32
    private let writeFd: Int32

    init() throws {
        var p: [Int32] = [0, 0]
        guard pipe(&p) == 0 else { throw OptionError("pipe: \(String(cString: strerror(errno)))") }
        guestInputFd = p[0]; writeFd = p[1]
        guestOutputFd = open("/dev/null", O_WRONLY | O_CLOEXEC)
        guard guestOutputFd >= 0 else { throw OptionError("/dev/null: \(String(cString: strerror(errno)))") }
        for fd in p { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        // Never block the main thread if the guest does not read (no service, older layer).
        _ = fcntl(writeFd, F_SETFL, fcntl(writeFd, F_GETFL) | O_NONBLOCK)
    }

    /// This process's wall clock, taken right before the write; false if the pipe did not take it.
    func sendTime() -> Bool {
        var ts = timespec()
        clock_gettime(CLOCK_REALTIME, &ts)
        let bytes = Array("time \(Int64(ts.tv_sec) * 1_000_000_000 + Int64(ts.tv_nsec))\n".utf8)
        var n: Int
        repeat { n = Darwin.write(writeFd, bytes, bytes.count) } while n < 0 && errno == EINTR
        return n == bytes.count
    }
}

/// "Resuming…" chip at the top of the VM picture (FX overlay style), from Resume until the
/// guest's next frame (0.5 s while the guest's GPU is idle, 2.5 s at most).
final class ResumeChipView: NSView {
    private let chip = CALayer()
    private let dot = CALayer()
    private let label = CATextLayer()
    private(set) var shown = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        autoresizingMask = [.width, .height]
        chip.backgroundColor = OverlayView.color(0x171a21, 0.88)
        chip.borderColor = OverlayView.color(0x66c0f4, 0.22)
        chip.borderWidth = 1
        dot.backgroundColor = OverlayView.color(0x66c0f4)
        label.alignmentMode = .left
        label.truncationMode = .end
        chip.addSublayer(dot)
        chip.addSublayer(label)
        layer!.addSublayer(chip)
        alphaValue = 0
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isOpaque: Bool { false }

    func show() {
        shown = true
        isHidden = false
        needsLayout = true
        layoutSubtreeIfNeeded()
        alphaValue = 1
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1
        pulse.toValue = 0.25
        pulse.duration = 0.6
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        dot.add(pulse, forKey: "pulse")
    }

    func hide(animated: Bool = true) {
        guard shown else { return }
        shown = false
        let done = { [weak self] in
            guard let self, !self.shown else { return }
            self.isHidden = true
            self.dot.removeAllAnimations()
        }
        guard animated else {
            alphaValue = 0
            done()
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            animator().alphaValue = 0
        }, completionHandler: done)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let s = max(0.85, min(1.6, min(bounds.width / 1280, bounds.height / 800)))
        let text = NSAttributedString(string: "Resuming…", attributes: [
            .font: NSFont.systemFont(ofSize: 13 * s, weight: .medium),
            .foregroundColor: OverlayView.color(0xc7d5e0)])
        let size = text.size()
        let padX = 14 * s, dotD = 8 * s, gap = 8 * s, h = ceil(size.height) + 12 * s
        let w = padX + dotD + gap + ceil(size.width) + padX
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        chip.frame = CGRect(x: (bounds.width - w) / 2, y: bounds.height - h - 18 * s, width: w, height: h)
        chip.cornerRadius = h / 2
        dot.frame = CGRect(x: padX, y: (h - dotD) / 2, width: dotD, height: dotD)
        dot.cornerRadius = dotD / 2
        label.string = text
        label.contentsScale = window?.backingScaleFactor ?? 2
        label.frame = CGRect(x: padX + dotD + gap, y: (h - ceil(size.height)) / 2, width: ceil(size.width) + 2, height: ceil(size.height))
        CATransaction.commit()
    }
}
