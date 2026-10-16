import AppKit

/// The Capture Bar: a level-103 overlay per display dimmed ~45%, "Drag to select capture area."
/// pill, remembered area pre-selected, white L brackets after release, and a control bar ~37pt below the selection.
/// Return captures the area, Esc cancels.
final class CaptureBar {
    enum Choice { case area(CGRect), fullscreen(CGRect), window, timer(CGRect), text(CGRect), scrolling(CGRect) }

    private static var current: CaptureBar?
    private var overlays: [AIOWindow] = []
    private let done: (Choice) -> Void
    /// Selection in global top-left points (CG space), or nil.
    var selection: CGRect?
    /// Scrolling Capture's selection step: its own hint and a single "↓ Start Capture" pill instead of the mode bar.
    private(set) var scrolling = false

    static func show(scrolling: Bool = false, _ done: @escaping (Choice) -> Void) {
        guard current == nil else { return }
        let c = CaptureBar(done: done)
        c.scrolling = scrolling
        current = c
        c.selection = Settings.lastArea.flatMap { r in NSScreen.screens.contains { $0.cgBounds.intersects(r) } ? r : nil }
        for s in NSScreen.screens {
            let w = AIOWindow(screen: s, owner: c)
            c.overlays.append(w)
            w.alphaValue = 0
            w.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.15; w.animator().alphaValue = 1 }
        }
        HoverKeys.shared.install()
        NSApp.activate(ignoringOtherApps: true)
        let mouse = NSEvent.mouseLocation
        (c.overlays.first { NSMouseInRect(mouse, $0.frame, false) } ?? c.overlays.first)?.makeKey()
        c.refresh()
    }

    private init(done: @escaping (Choice) -> Void) { self.done = done }

    /// Esc / Return from the HoverKeys event tap: works even when macOS refuses to make the overlay key
    /// (activation is only a request on macOS 14+), and wins over a pin or card under the cursor.
    static func handleKey(_ event: CGEvent) -> Bool {
        guard let c = current else { return false }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        switch code {
        case 53: c.finish(nil)
        case 36, 76:
            if let w = NSApp.keyWindow as? AIOWindow, w.firstResponder is NSTextView { return false } // typing W × H
            guard let s = c.selection, s.width >= 2, s.height >= 2 else { NSSound.beep(); return true }
            c.finish(c.scrolling ? .scrolling(s) : .area(s))
        default: return false
        }
        return true
    }

    func refresh() { overlays.forEach { $0.overlay.sync() } }

    func finish(_ choice: Choice?) {
        CaptureBar.current = nil
        for w in overlays { // overlays fade out (~150 ms), then the capture runs on a clean screen
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.15; w.animator().alphaValue = 0 }) { w.orderOut(nil) }
        }
        guard let choice else { return }
        if case .area(let r) = choice { Settings.lastArea = r }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.done(choice) }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID { deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0 }
    /// This screen in global top-left points (CG / screencapture space).
    var cgBounds: CGRect { CGDisplayBounds(displayID) }
}

final class AIOWindow: NSPanel {
    let overlay: AIOView

    init(screen: NSScreen, owner: CaptureBar) {
        overlay = AIOView(screen: screen, owner: owner)
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        level = NSWindow.Level(rawValue: 103)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true
        contentView = overlay
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { true }
}

final class AIOView: NSView {
    private unowned let owner: CaptureBar
    private let screenBounds: CGRect // CG space
    private enum Drag { case create(CGPoint), move(CGRect, CGPoint), handle(Int, CGRect) }
    private var drag: Drag?
    private let hint = NSTextField(labelWithString: "Drag to select capture area.")
    private let hintPill = NSView()
    private let bar = NSView()
    private let wField = NSTextField(), hField = NSTextField()

    init(screen: NSScreen, owner: CaptureBar) {
        self.owner = owner
        screenBounds = screen.cgBounds
        super.init(frame: CGRect(origin: .zero, size: screen.frame.size))
        if owner.scrolling { hint.stringValue = "Drag to capture the scrolling part of the screen." }
        buildHint()
        if owner.scrolling { buildStartPill() } else { buildBar() }
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    /// The shared selection in this view's coordinates, if it's on this screen.
    private var local: CGRect? {
        guard let s = owner.selection, s.intersects(screenBounds) else { return nil }
        return s.offsetBy(dx: -screenBounds.minX, dy: -screenBounds.minY)
    }

    private func setLocal(_ r: CGRect) {
        owner.selection = r.offsetBy(dx: screenBounds.minX, dy: screenBounds.minY)
        owner.refresh()
    }

    // MARK: chrome

    private func panel(_ v: NSView) {
        v.wantsLayer = true
        v.layer!.backgroundColor = Palette.capsule.withAlphaComponent(0.95).cgColor
        v.layer!.cornerRadius = 10
        v.layer!.cornerCurve = .continuous
        v.layer!.borderWidth = 1
        v.layer!.borderColor = Palette.panelBorder.cgColor
    }

    private func buildHint() {
        hint.font = .systemFont(ofSize: 14, weight: .medium)
        hint.textColor = .white
        hint.sizeToFit()
        let size = CGSize(width: hint.frame.width + 36, height: 38)
        hintPill.frame = CGRect(x: (bounds.width - size.width) / 2, y: 90, width: size.width, height: size.height)
        panel(hintPill)
        hintPill.layer!.cornerRadius = size.height / 2
        hint.frame.origin = CGPoint(x: 18, y: (size.height - hint.frame.height) / 2)
        hintPill.addSubview(hint)
        addSubview(hintPill)
    }

    private func buildBar() {
        // One panel: capture modes, a divider, then the size fields and expand.
        let modes = NSView(frame: CGRect(x: 0, y: 0, width: 6 * 64 + 8 + 1 + 186, height: 56))
        panel(modes)
        modes.layer!.cornerRadius = 14
        let items: [(String, String, () -> Void)] = [
            ("Area", "area", { [unowned self] in self.capture() }),
            ("Fullscreen", "fullscreen", { [unowned self] in self.owner.finish(.fullscreen(self.screenBounds)) }),
            ("Window", "window", { [unowned self] in self.owner.finish(.window) }),
            ("Scrolling", "scrolling", { [unowned self] in if let s = self.owner.selection { self.owner.finish(.scrolling(s)) } }),
            ("Timer", "timer", { [unowned self] in if let s = self.owner.selection { self.owner.finish(.timer(s)) } }),
            ("Text", "ocr", { [unowned self] in if let s = self.owner.selection { self.owner.finish(.text(s)) } }),
        ]
        for (i, (title, icon, action)) in items.enumerated() {
            let b = ModeButton(frame: CGRect(x: 4 + CGFloat(i) * 64, y: 4, width: 64, height: 48), title: title, icon: icon, action: action)
            b.highlighted = i == 0
            modes.addSubview(b)
        }
        let divider = NSView(frame: CGRect(x: 6 * 64 + 8, y: 12, width: 1, height: 32))
        divider.wantsLayer = true
        divider.layer!.backgroundColor = Palette.panelBorder.cgColor
        modes.addSubview(divider)
        let size = NSView(frame: CGRect(x: divider.frame.maxX + 4, y: 0, width: 182, height: 56))
        for (f, x) in [(wField, 12.0), (hField, 92.0)] {
            f.frame = CGRect(x: x, y: 16, width: 62, height: 24)
            f.alignment = .center
            f.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
            f.bezelStyle = .roundedBezel
            f.target = self
            f.action = #selector(sizeTyped)
            size.addSubview(f)
        }
        let times = NSTextField(labelWithString: "×")
        times.textColor = Palette.muted
        times.frame = CGRect(x: 77, y: 19, width: 14, height: 18)
        size.addSubview(times)
        let expand = EButton(frame: CGRect(x: 160, y: 14, width: 28, height: 28), symbol: "expand", fill: .clear, tip: "Select the whole screen") { [unowned self] in
            self.setLocal(CGRect(origin: .zero, size: self.bounds.size))
        }
        size.addSubview(expand)
        modes.addSubview(size)
        bar.frame = CGRect(x: 0, y: 0, width: modes.frame.width, height: 56)
        bar.addSubview(modes)
        bar.appearance = NSAppearance(named: .darkAqua)
        addSubview(bar)
    }

    /// Scrolling mode: a light "↓ Start Capture" pill, 15pt under the selection.
    private func buildStartPill() {
        let b = EButton(frame: CGRect(x: 0, y: 0, width: 150, height: 34), title: "↓  Start Capture", fill: Palette.accent, tip: "Start Capture (Return)") { [unowned self] in
            if let s = self.owner.selection { self.owner.finish(.scrolling(s)) }
        }
        b.layer!.cornerRadius = 17
        bar.frame = CGRect(x: 0, y: 0, width: 150, height: 34)
        bar.addSubview(b)
        addSubview(bar)
    }

    /// Re-layout from the shared selection.
    func sync() {
        let r = local
        let dragging: Bool = { if case .create = drag { return true }; return false }()
        hintPill.isHidden = dragging || (r != nil && r!.intersects(hintPill.frame.insetBy(dx: -10, dy: -10)))
        bar.isHidden = r == nil || dragging || r!.width < 2 || r!.height < 2
        if let r {
            // ~37pt below the selection, else above it, else inside its bottom edge.
            var y = r.maxY + (owner.scrolling ? 15 : 37)
            if y + bar.frame.height > bounds.height - 10 { y = r.minY - 37 - bar.frame.height }
            if y < 10 { y = r.maxY - bar.frame.height - 16 }
            let x = min(max(10, r.midX - bar.frame.width / 2), bounds.width - bar.frame.width - 10)
            bar.frame.origin = CGPoint(x: x, y: y)
            if window?.firstResponder !== wField.currentEditor() && window?.firstResponder !== hField.currentEditor() {
                wField.integerValue = Int(r.width.rounded()); hField.integerValue = Int(r.height.rounded())
            }
        }
        needsDisplay = true
    }

    // MARK: drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let dim = CGMutablePath(); dim.addRect(bounds)
        if let r = local { dim.addRect(r) }
        ctx.addPath(dim); ctx.setFillColor(CGColor(gray: 0, alpha: 0.45)); ctx.fillPath(using: .evenOdd)
        guard let r = local, r.width > 0 else { return }
        if case .create = drag { // a clean hairline while dragging
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.6)); ctx.setLineWidth(1); ctx.stroke(r.insetBy(dx: -0.5, dy: -0.5)); return
        }
        // Glint's selection: an accent border with round handles at the corners and edge midpoints.
        ctx.setStrokeColor(Palette.accent.cgColor); ctx.setLineWidth(1.5); ctx.stroke(r.insetBy(dx: -0.75, dy: -0.75))
        for (k, h) in handles(r).enumerated() where k % 2 == 0 || (r.width > 60 && r.height > 60) {
            let c = CGRect(x: h.x - 5, y: h.y - 5, width: 10, height: 10)
            ctx.setFillColor(.white); ctx.fillEllipse(in: c)
            ctx.setStrokeColor(Palette.accent.cgColor); ctx.setLineWidth(2); ctx.strokeEllipse(in: c.insetBy(dx: 1, dy: 1))
        }
    }

    // MARK: mouse

    private func handles(_ r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.midY),
         CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.midX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX, y: r.midY)]
    }

    override func mouseDown(with e: NSEvent) {
        window?.makeKey()
        window?.makeFirstResponder(self)
        let p = convert(e.locationInWindow, from: nil)
        if let r = local, let k = handles(r).firstIndex(where: { hypot($0.x - p.x, $0.y - p.y) < 12 }) {
            drag = .handle(k, r)
        } else if let r = local, r.contains(p) {
            if e.clickCount == 2 { return capture() } // double-click inside captures
            drag = .move(r, p)
        } else {
            drag = .create(p)
            owner.selection = nil
            owner.refresh()
        }
    }

    override func mouseDragged(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil).clamped(to: bounds)
        switch drag {
        case .create(let s):
            var q = p
            if e.modifierFlags.contains(.shift) { q = Geometry.square(s, p).clamped(to: bounds) }
            setLocal(CGRect(x: min(s.x, q.x), y: min(s.y, q.y), width: abs(q.x - s.x), height: abs(q.y - s.y)))
        case .move(let r, let s):
            var m = r.offsetBy(dx: p.x - s.x, dy: p.y - s.y)
            m.origin.x = min(max(0, m.minX), bounds.width - m.width)
            m.origin.y = min(max(0, m.minY), bounds.height - m.height)
            setLocal(m)
        case .handle(let k, let r):
            var (x0, y0, x1, y1) = (r.minX, r.minY, r.maxX, r.maxY)
            if [0, 6, 7].contains(k) { x0 = p.x }
            if [2, 3, 4].contains(k) { x1 = p.x }
            if [0, 1, 2].contains(k) { y0 = p.y }
            if [4, 5, 6].contains(k) { y1 = p.y }
            setLocal(CGRect(x: min(x0, x1), y: min(y0, y1), width: abs(x1 - x0), height: abs(y1 - y0)))
        case nil: break
        }
    }

    override func mouseUp(with e: NSEvent) {
        let wasCreate: Bool = { if case .create = drag { return true }; return false }()
        drag = nil
        if wasCreate, let r = local, r.width < 4 || r.height < 4 { owner.selection = nil } // a click, not a drag
        if let r = owner.selection { owner.selection = r.integral }
        owner.refresh()
    }

    override func keyDown(with e: NSEvent) {
        switch e.keyCode {
        case 36, 76: capture()     // Return
        case 53: owner.finish(nil) // Esc
        default: super.keyDown(with: e)
        }
    }

    private func capture() {
        guard let s = owner.selection, s.width >= 2, s.height >= 2 else { return NSSound.beep() }
        owner.finish(owner.scrolling ? .scrolling(s) : .area(s))
    }

    @objc private func sizeTyped() {
        guard let r = local else { return }
        let w = CGFloat(max(1, wField.integerValue)), h = CGFloat(max(1, hField.integerValue))
        setLocal(CGRect(x: r.minX, y: r.minY, width: min(w, bounds.width - r.minX), height: min(h, bounds.height - r.minY)))
        window?.makeFirstResponder(self)
    }
}

/// Icon-over-label mode button (64×48) in the Capture Bar bar.
final class ModeButton: NSView {
    private let action: () -> Void
    var highlighted = false { didSet { layer?.backgroundColor = highlighted ? NSColor(white: 1, alpha: 0.12).cgColor : nil } }

    init(frame: CGRect, title: String, icon: String, action: @escaping () -> Void) {
        self.action = action
        super.init(frame: frame)
        wantsLayer = true
        layer!.cornerRadius = 7
        let iv = NSImageView(frame: CGRect(x: (frame.width - 18) / 2, y: 25, width: 18, height: 18))
        iv.image = Icon.image(icon, size: 18)
        addSubview(iv)
        let l = NSTextField(labelWithString: title)
        l.font = .systemFont(ofSize: 11, weight: .medium)
        l.textColor = NSColor(white: 1, alpha: 0.85)
        l.alignment = .center
        l.frame = CGRect(x: 0, y: 5, width: frame.width, height: 15)
        addSubview(l)
        toolTip = title
    }
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
    override func mouseEntered(with event: NSEvent) { if !highlighted { layer?.backgroundColor = NSColor(white: 1, alpha: 0.08).cgColor } }
    override func mouseExited(with event: NSEvent) { layer?.backgroundColor = highlighted ? NSColor(white: 1, alpha: 0.12).cgColor : nil }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { if bounds.contains(convert(event.locationInWindow, from: nil)) { action() } }
}

extension CGPoint {
    func clamped(to r: CGRect) -> CGPoint { CGPoint(x: min(max(x, r.minX), r.maxX), y: min(max(y, r.minY), r.maxY)) }
}
