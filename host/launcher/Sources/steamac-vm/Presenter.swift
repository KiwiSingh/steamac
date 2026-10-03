import AppKit
import Foundation
import Metal
import QuartzCore
import os

/// Main-thread side of the display path: takes frames from scanout 0, uploads them to the
/// renderer and redraws the view (if any). GPU-thread notifications are coalesced.
final class Presenter: DisplaySink {
    let display: DisplayBackend
    let renderer: Renderer
    weak var view: VMView?
    var onScanoutResize: ((Int, Int) -> Void)?
    private var lock = os_unfair_lock()
    private var pending = false
    private(set) var framesShown: UInt64 = 0

    init(display: DisplayBackend, renderer: Renderer) {
        self.display = display
        self.renderer = renderer
    }

    var scanout: Scanout { display.scanouts[0] }

    // DisplaySink (GPU thread)
    func scanoutConfigured(_ s: Scanout, changed: Bool) {
        guard s.id == 0, changed, let g = s.geometry else { return }
        DispatchQueue.main.async { [weak self] in self?.onScanoutResize?(g.width, g.height) }
    }

    func scanoutDisabled(_ s: Scanout) {
        guard s.id == 0 else { return }
        DispatchQueue.main.async { [weak self] in
            self?.renderer.dropTexture()
            self?.view?.redraw()
        }
    }

    func framePresented(_ s: Scanout) {
        guard s.id == 0 else { return }
        os_unfair_lock_lock(&lock)
        let schedule = !pending
        pending = true
        os_unfair_lock_unlock(&lock)
        if schedule {
            DispatchQueue.main.async { [weak self] in self?.consume() }
        }
    }

    /// Main thread.
    func consume() {
        os_unfair_lock_lock(&lock)
        pending = false
        os_unfair_lock_unlock(&lock)
        guard let f = scanout.take() else { return }
        renderer.upload(f)
        scanout.release(f)
        framesShown &+= 1
        view?.redraw()
    }
}

/// NSView backed by a CAMetalLayer showing the guest scanout, aspect-fit and Retina-aware.
final class VMView: NSView {
    let renderer: Renderer
    let metalLayer = CAMetalLayer()
    /// Fallback geometry for pointer mapping before the first frame.
    var contentPixelSize: CGSize
    weak var controller: WindowController?

    init(frame: NSRect, renderer: Renderer, contentPixelSize: CGSize) {
        self.renderer = renderer
        self.contentPixelSize = contentPixelSize
        super.init(frame: frame)
        metalLayer.device = renderer.device
        metalLayer.pixelFormat = Renderer.layerFormat
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        metalLayer.maximumDrawableCount = 3
        metalLayer.displaySyncEnabled = true
        metalLayer.allowsNextDrawableTimeout = true
        metalLayer.backgroundColor = NSColor.black.cgColor
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }

    required init?(coder: NSCoder) { fatalError() }

    override func makeBackingLayer() -> CALayer { metalLayer }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
    }

    // Mouse events go to the controller (window.acceptsMouseMovedEvents delivers mouseMoved here).
    override func mouseMoved(with e: NSEvent) { controller?.pointerMoved(e) }
    override func mouseDragged(with e: NSEvent) { controller?.pointerMoved(e) }
    override func rightMouseDragged(with e: NSEvent) { controller?.pointerMoved(e) }
    override func otherMouseDragged(with e: NSEvent) { controller?.pointerMoved(e) }
    override func mouseDown(with e: NSEvent) { controller?.pointerButton(e, down: true) }
    override func mouseUp(with e: NSEvent) { controller?.pointerButton(e, down: false) }
    override func rightMouseDown(with e: NSEvent) { controller?.pointerButton(e, down: true) }
    override func rightMouseUp(with e: NSEvent) { controller?.pointerButton(e, down: false) }
    override func otherMouseDown(with e: NSEvent) { controller?.pointerButton(e, down: true) }
    override func otherMouseUp(with e: NSEvent) { controller?.pointerButton(e, down: false) }
    override func scrollWheel(with e: NSEvent) { controller?.scroll(e) }

    private func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        let size = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
        if size != metalLayer.drawableSize && size.width > 0 && size.height > 0 {
            metalLayer.drawableSize = size
            redraw()
        }
    }

    func redraw() { renderer.draw(to: metalLayer) }

    /// The guest picture's rect in view points (same fit as the renderer).
    var fitRect: CGRect {
        let content = renderer.texture.map { CGSize(width: $0.width, height: $0.height) } ?? contentPixelSize
        return Renderer.fit(content: content, in: bounds)
    }

    /// Event location -> unit coordinates (top-left origin), clamped to the picture.
    func unitPoint(for event: NSEvent) -> (Double, Double) {
        let p = convert(event.locationInWindow, from: nil)
        let f = fitRect
        guard f.width > 0, f.height > 0 else { return (0, 0) }
        let ux = Double((p.x - f.minX) / f.width)
        let uy = 1 - Double((p.y - f.minY) / f.height)   // AppKit views are bottom-left origin
        return (min(1, max(0, ux)), min(1, max(0, uy)))
    }
}
