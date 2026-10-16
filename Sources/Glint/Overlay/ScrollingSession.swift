import AppKit

/// Scrolling capture after the area is chosen: everything but the selection dimmed 50%,
/// Cancel / Done under it, an Auto-Scroll pill inside its bottom edge, and a live preview of the stitched image on
/// its left. Frames are grabbed in a loop and stitched as you scroll; "Please slow down..." when tracking is lost.
final class ScrollingSession {
    private static var current: ScrollingSession?
    static var isRunning: Bool { current != nil }

    private let rect: CGRect // global, top-left points
    private let done: (CGImage) -> Void
    private let stitcher = Stitcher()
    private var running = true
    private var autoScroll = false, scrolledByHand = false
    private var unchangedTicks = 0

    private var windows: [NSWindow] = []
    private let dim: NSWindow
    private let preview = PreviewView()
    private let previewPanel: NSPanel
    private let message = NSTextField(labelWithString: "")
    private let messagePanel: NSPanel
    private let autoPanel: NSPanel

    static func start(_ rect: CGRect, done: @escaping (CGImage) -> Void) {
        guard current == nil else { return }
        let s = ScrollingSession(rect: rect, done: done)
        current = s
        HoverKeys.shared.install()
        s.loop()
    }

    /// Esc cancels, Return finishes (from the HoverKeys tap, so it works without focus).
    static func handleKey(_ event: CGEvent) -> Bool {
        guard let s = current else { return false }
        switch event.getIntegerValueField(.keyboardEventKeycode) {
        case 53: s.finish(keep: false)
        case 36, 76: s.finish(keep: true)
        default: return false
        }
        return true
    }

    private init(rect: CGRect, done: @escaping (CGImage) -> Void) {
        self.rect = rect
        self.done = done
        let screen = NSScreen.screens.first { $0.cgBounds.contains(CGPoint(x: rect.midX, y: rect.midY)) } ?? NSScreen.main!
        let sb = screen.cgBounds
        // AppKit rect (bottom-left origin) of the selection.
        let ak = CGRect(x: screen.frame.minX + rect.minX - sb.minX, y: screen.frame.maxY - (rect.maxY - sb.minY), width: rect.width, height: rect.height)

        dim = Self.panel(screen.frame, level: 103, clickThrough: true)
        let dimView = DimView(frame: CGRect(origin: .zero, size: screen.frame.size))
        dimView.hole = CGRect(x: ak.minX - screen.frame.minX, y: ak.minY - screen.frame.minY, width: ak.width, height: ak.height)
        dim.contentView = dimView

        // Cancel | Done, 200×40, 15pt under the selection (above it if there's no room).
        var barY = ak.minY - 15 - 40
        if barY < screen.frame.minY + 8 { barY = ak.maxY + 15 }
        let bar = Self.panel(CGRect(x: ak.midX - 100, y: barY, width: 200, height: 40), level: 104, clickThrough: false)
        let barView = NSView(frame: CGRect(x: 0, y: 0, width: 200, height: 40))
        let cancel = EButton(frame: CGRect(x: 0, y: 0, width: 96, height: 40), title: "Cancel", fill: Palette.capsule, tip: "Cancel (Esc)") { }
        let finish = EButton(frame: CGRect(x: 104, y: 0, width: 96, height: 40), title: "Done", fill: Palette.selected, tip: "Done (Return)") { }
        for b in [cancel, finish] { b.layer!.cornerRadius = 20; barView.addSubview(b) }
        bar.contentView = barView

        // Auto-Scroll pill just above the selection's bottom edge.
        autoPanel = Self.panel(CGRect(x: ak.midX - 60, y: ak.minY + 14, width: 120, height: 24), level: 104, clickThrough: false)
        let auto = EButton(frame: CGRect(x: 0, y: 0, width: 120, height: 24), title: "Auto-Scroll", fill: Palette.capsule.withAlphaComponent(0.9), tip: "Scroll automatically") { }
        auto.layer!.cornerRadius = 12
        autoPanel.contentView = auto

        // Message pill in the middle of the selection.
        messagePanel = Self.panel(CGRect(x: ak.midX - 150, y: ak.midY - 18, width: 300, height: 36), level: 104, clickThrough: true)
        let pill = NSView(frame: CGRect(x: 0, y: 0, width: 300, height: 36))
        pill.wantsLayer = true
        pill.layer!.backgroundColor = Palette.capsule.withAlphaComponent(0.92).cgColor
        pill.layer!.cornerRadius = 18
        message.font = .systemFont(ofSize: 13, weight: .semibold)
        message.textColor = .white
        message.alignment = .center
        message.frame = CGRect(x: 0, y: 9, width: 300, height: 18)
        pill.addSubview(message)
        messagePanel.contentView = pill

        // Live preview strip on the left of the selection (right if there's no room).
        let pw = min(170, max(90, rect.width * 0.25))
        var px = ak.minX - 16 - pw
        if px < screen.frame.minX + 8 { px = ak.maxX + 16 }
        previewPanel = Self.panel(CGRect(x: px, y: ak.minY, width: pw, height: ak.height), level: 104, clickThrough: true)
        preview.frame = CGRect(x: 0, y: 0, width: pw, height: ak.height)
        previewPanel.contentView = preview

        windows = [dim, bar, autoPanel, previewPanel]
        cancel.handler = { [weak self] in self?.finish(keep: false) }
        finish.handler = { [weak self] in self?.finish(keep: true) }
        auto.handler = { [weak self] in self?.startAutoScroll() }
        for w in windows { w.orderFrontRegardless() }
        show(nil)
    }

    private static func panel(_ frame: CGRect, level: Int, clickThrough: Bool) -> NSPanel {
        let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = NSWindow.Level(rawValue: level)
        p.ignoresMouseEvents = clickThrough
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.setFrame(frame, display: false)
        return p
    }

    private func show(_ text: String?) {
        guard let text else { return messagePanel.orderOut(nil) }
        message.stringValue = text
        messagePanel.orderFrontRegardless()
    }

    // MARK: capture loop

    private func loop() {
        Task { @MainActor in
            do {
                let grab = try await Capturer.regionGrabber(rect)
                while running {
                    let frame = try await grab()
                    guard running else { break }
                    handle(stitcher.add(frame))
                    if autoScroll { postScroll() }
                    try await Task.sleep(nanoseconds: 50_000_000)
                }
            } catch {
                log("scrolling capture failed: \(error)")
                finish(keep: false)
            }
        }
    }

    private func handle(_ r: Stitcher.Result) {
        switch r {
        case .first, .unchanged:
            unchangedTicks += 1
            if autoScroll, unchangedTicks > 16, stitcher.height > Int(rect.height) { finish(keep: true) } // reached the end
        case .appended:
            unchangedTicks = 0
            if !autoScroll, !scrolledByHand { scrolledByHand = true; autoPanel.orderOut(nil) } // hidden once you scroll yourself
            if !autoScroll || cursorInside { show(nil) }
            preview.slices = stitcher.slices
            if stitcher.isFull { finish(keep: true) }
        case .lost:
            show("Please slow down...")
        }
    }

    // MARK: auto-scroll (posts scroll events where the cursor is; needs Accessibility, which HoverKeys already has)

    private var cursorInside: Bool { rect.contains(CGEvent(source: nil)?.location ?? .zero) }

    private func startAutoScroll() {
        autoScroll = true
        autoPanel.orderOut(nil)
        show(cursorInside ? nil : "Move cursor here to start scrolling")
    }

    private func postScroll() {
        guard cursorInside else { return show("Move cursor here to start scrolling") }
        if message.stringValue == "Move cursor here to start scrolling" { show(nil) }
        let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -24, wheel2: 0, wheel3: 0)
        e?.post(tap: .cghidEventTap)
    }

    // MARK: finish

    private func finish(keep: Bool) {
        guard running else { return }
        running = false
        ScrollingSession.current = nil
        let image = keep ? stitcher.image() : nil
        for w in windows + [messagePanel] {
            NSAnimationContext.runAnimationGroup({ $0.duration = keep ? 0.27 : 0.075; w.animator().alphaValue = 0 }) { w.orderOut(nil) }
        }
        log("scrolling capture \(keep ? "done" : "cancelled") \(stitcher.width)x\(stitcher.height)")
        if let image { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.done(image) } }
    }
}

/// 50% dim with a clear hole and a thin white edge around the selection.
private final class DimView: NSView {
    var hole = CGRect.zero
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let p = CGMutablePath(); p.addRect(bounds); p.addRect(hole)
        ctx.addPath(p); ctx.setFillColor(CGColor(gray: 0, alpha: 0.5)); ctx.fillPath(using: .evenOdd)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.7)); ctx.setLineWidth(1); ctx.stroke(hole.insetBy(dx: -1.5, dy: -1.5))
    }
}

/// The stitched result scaled to the strip's width, newest rows at the bottom.
private final class PreviewView: NSView {
    var slices: [CGImage] = [] { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, let w = slices.first?.width else { return }
        let k = bounds.width / CGFloat(w)
        let total = CGFloat(slices.reduce(0) { $0 + $1.height }) * k
        let card = CGRect(x: 0, y: 0, width: bounds.width, height: min(total, bounds.height))
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 3), blur: 10, color: CGColor(gray: 0, alpha: 0.5))
        ctx.addPath(CGPath(roundedRect: card, cornerWidth: 6, cornerHeight: 6, transform: nil)); ctx.setFillColor(Palette.capsule.cgColor); ctx.fillPath()
        ctx.restoreGState()
        ctx.addPath(CGPath(roundedRect: card, cornerWidth: 6, cornerHeight: 6, transform: nil)); ctx.clip()
        var y = min(0, bounds.height - total) // scrolled so the latest rows stay visible
        for s in slices {
            let h = CGFloat(s.height) * k
            // Whole-pixel edges: fractional slice boundaries let the card show through as light seams.
            let top = y.rounded(), bottom = (y + h).rounded()
            if bottom > 0, bottom > top { Render.drawImage(s, in: CGRect(x: 0, y: top, width: bounds.width, height: bottom - top), ctx: ctx) }
            y += h
        }
    }
}
