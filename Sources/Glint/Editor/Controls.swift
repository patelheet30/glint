import AppKit
import UniformTypeIdentifiers

/// Rounded button used across the editor and overlays (fill, icon or title, optional chevron).
final class EButton: NSButton {
    var handler: () -> Void
    var handlerWithSelf: ((EButton) -> Void)?
    var fill: NSColor { didSet { layer?.backgroundColor = fill.cgColor } }
    var chevron = false { didSet { if let t = titleText { setTitle(t) } } }
    private var titleText: String?

    init(frame: CGRect, symbol: String? = nil, title: String? = nil, fill: NSColor = Palette.button, tip: String, handler: @escaping () -> Void) {
        self.handler = handler
        self.fill = fill
        super.init(frame: frame)
        isBordered = false
        wantsLayer = true
        layer!.backgroundColor = fill.cgColor
        layer!.cornerRadius = min(12, frame.height / 2)
        layer!.cornerCurve = .continuous
        toolTip = tip
        focusRingType = .none
        if let symbol {
            image = Icon.image(symbol, size: 18) ?? NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
            contentTintColor = Palette.icon
        }
        if let title { setTitle(title) }
        target = self
        action = #selector(fire)
    }
    required init?(coder: NSCoder) { fatalError() }

    func setTitle(_ t: String) {
        titleText = t
        if chevron { image = Icon.image("chevron", size: 10, color: NSColor(white: 1, alpha: 0.55)); imagePosition = .imageTrailing; imageHugsTitle = true }
        attributedTitle = NSAttributedString(string: chevron ? "\(t) " : t, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: Palette.icon])
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    @objc private func fire() { if let h = handlerWithSelf { h(self) } else { handler() } }
}

/// The tool rail's tool column: 36×32 cells stacked vertically, the selected tool on an accent tile.
final class ToolStrip: NSView, NSViewToolTipOwner {
    static let cell = CGSize(width: 36, height: 32)
    var onSelect: ((Tool) -> Void)?
    var selected = Tool.arrow { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override var intrinsicContentSize: NSSize { NSSize(width: Self.cell.width, height: Self.cell.height * CGFloat(Tool.toolbar.count)) }

    private func rect(_ i: Int) -> CGRect { CGRect(x: 0, y: CGFloat(i) * Self.cell.height, width: Self.cell.width, height: Self.cell.height) }

    override func viewDidMoveToWindow() {
        removeAllToolTips()
        // The owner is self: AppKit doesn't retain tooltip owners, so a temporary string would be read after it's freed.
        for i in Tool.toolbar.indices { addToolTip(rect(i), owner: self, userData: nil) }
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        let i = Int(point.y / Self.cell.height)
        guard Tool.toolbar.indices.contains(i) else { return "" }
        let t = Tool.toolbar[i]
        return "\(t.name) (\(t.key.uppercased()))"
    }

    override func draw(_ dirtyRect: NSRect) {
        for (i, t) in Tool.toolbar.enumerated() {
            let r = rect(i)
            if t == selected {
                Palette.accent.setFill()
                NSBezierPath(roundedRect: r.insetBy(dx: 3, dy: 2), xRadius: 8, yRadius: 8).fill()
            }
            guard let img = Icon.image(t.symbol, size: 18, color: t == selected ? .white : Palette.icon) else { continue }
            img.draw(in: CGRect(x: (r.midX - 9).rounded(), y: (r.midY - 9).rounded(), width: 18, height: 18)) // whole pixels: no blur
        }
    }

    override func mouseDown(with event: NSEvent) {
        let i = Int(convert(event.locationInWindow, from: nil).y / Self.cell.height)
        if Tool.toolbar.indices.contains(i) { onSelect?(Tool.toolbar[i]) }
    }
}

/// A floating rounded panel over the canvas (tool rail, inspector, zoom chip, background panel).
final class FloatingPanel: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer!.backgroundColor = Palette.capsule.withAlphaComponent(0.97).cgColor
        layer!.cornerRadius = 12
        layer!.cornerCurve = .continuous
        layer!.borderWidth = 0.5
        layer!.borderColor = Palette.panelBorder.cgColor
        shadow = { let s = NSShadow(); s.shadowColor = NSColor(white: 0, alpha: 0.35); s.shadowBlurRadius = 14; s.shadowOffset = NSSize(width: 0, height: -4); return s }()
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
}

/// Inline color row for the inspector: the swatches plus a custom-color wheel; the current color gets a ring.
final class SwatchRow: NSView {
    private let current: NSColor
    private let pick: (NSColor?) -> Void
    private static let pitch: CGFloat = 22

    init(current: NSColor, pick: @escaping (NSColor?) -> Void) {
        self.current = current
        self.pick = pick
        super.init(frame: CGRect(x: 0, y: 0, width: CGFloat(Palette.swatches.count + 1) * Self.pitch, height: 26))
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func rect(_ i: Int) -> CGRect { CGRect(x: CGFloat(i) * Self.pitch + 4, y: 6, width: 14, height: 14) }

    override func draw(_ dirtyRect: NSRect) {
        for (i, c) in Palette.swatches.enumerated() {
            let r = rect(i)
            if c.usingColorSpace(.sRGB) == current.usingColorSpace(.sRGB) {
                Palette.icon.setStroke()
                let ring = NSBezierPath(ovalIn: r.insetBy(dx: -3, dy: -3)); ring.lineWidth = 1.5; ring.stroke()
            }
            c.setFill(); NSBezierPath(ovalIn: r).fill()
            NSColor(white: 1, alpha: 0.18).setStroke(); NSBezierPath(ovalIn: r.insetBy(dx: 0.25, dy: 0.25)).stroke()
        }
        // Custom color: a conic-looking wheel from four quadrants.
        let r = rect(Palette.swatches.count)
        for (k, c) in [NSColor.systemRed, .systemYellow, .systemGreen, .systemBlue].enumerated() {
            let p = NSBezierPath()
            p.move(to: CGPoint(x: r.midX, y: r.midY))
            p.appendArc(withCenter: CGPoint(x: r.midX, y: r.midY), radius: r.width / 2, startAngle: CGFloat(k) * 90, endAngle: CGFloat(k + 1) * 90)
            p.close(); c.setFill(); p.fill()
        }
        toolTip = "Custom color"
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let i = (0...Palette.swatches.count).first(where: { rect($0).insetBy(dx: -4, dy: -6).contains(p) }) else { return }
        pick(i < Palette.swatches.count ? Palette.swatches[i] : nil)
    }
}

extension NSImage {
    func tinted(_ color: NSColor) -> NSImage {
        NSImage(size: size, flipped: false) { r in
            self.draw(in: r)
            color.set()
            r.fill(using: .sourceAtop)
            return true
        }
    }
}

/// Icons for the per-tool option buttons and menus.
enum OptionArt {
    static func withChevron(_ icon: NSImage) -> NSImage {
        NSImage(size: NSSize(width: 34, height: 22), flipped: false) { _ in
            icon.draw(in: CGRect(x: (2 + (20 - icon.size.width) / 2).rounded(), y: ((22 - icon.size.height) / 2).rounded(), width: icon.size.width, height: icon.size.height))
            Icon.image("chevron", size: 10, color: NSColor(white: 1, alpha: 0.55))?.draw(in: CGRect(x: 24, y: 6, width: 10, height: 10))
            return true
        }
    }

    /// Text-style glyph: a bold italic serif "A".
    static let italicA: NSImage = {
        let font = NSFont(name: "TimesNewRomanPS-BoldItalicMT", size: 19) ?? .systemFont(ofSize: 17, weight: .bold)
        let a = NSAttributedString(string: "A", attributes: [.font: font, .foregroundColor: Palette.icon])
        let s = a.size()
        return NSImage(size: s, flipped: false) { _ in a.draw(at: .zero); return true }
    }()

    static func dot(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 18, height: 18), flipped: false) { r in
            color.setFill()
            NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1)).fill()
            NSColor(white: 1, alpha: 0.85).setStroke()
            let ring = NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1)); ring.lineWidth = 1.5; ring.stroke()
            return true
        }
    }

    static func symbol(_ name: String) -> NSImage {
        Icon.image(name, size: 18) ?? (NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
            ?? NSImage()).tinted(Palette.icon)
    }

    /// Slanted line of the given weight.
    static func thickness(_ w: CGFloat, size: CGSize = CGSize(width: 20, height: 20)) -> NSImage {
        NSImage(size: size, flipped: false) { r in
            let p = NSBezierPath()
            p.move(to: CGPoint(x: r.minX + 4, y: r.minY + 4)); p.line(to: CGPoint(x: r.maxX - 4, y: r.maxY - 4))
            p.lineWidth = min(w, r.height / 2); p.lineCapStyle = .round
            Palette.icon.setStroke(); p.stroke()
            return true
        }
    }

    static func arrow(_ style: ArrowStyle) -> NSImage {
        if style == .standard, let icon = Icon.image("arrow", size: 18) { return icon }
        return NSImage(size: NSSize(width: 24, height: 20), flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            var it = Item(tool: .arrow, points: [CGPoint(x: 19, y: 3), CGPoint(x: 5, y: 17)], color: Palette.icon, width: 1.8, arrow: style)
            if style == .curved { it.points.append(CGPoint(x: 8, y: 7)) }
            Render.drawArrow(it, in: ctx)
            return true
        }
    }
}

final class ActionSlider: NSSlider {
    var handler: ((Double) -> Void)?
    convenience init(value: Double, minValue: Double, maxValue: Double, target: AnyObject?, action: Selector?) {
        self.init(frame: .zero)
        self.minValue = minValue; self.maxValue = maxValue; doubleValue = value
        isContinuous = true
        self.target = self
        self.action = #selector(changed)
    }
    @objc private func changed() { handler?(doubleValue) }
}

/// "Starting number" row inside the counter menu.
final class StepperRow: NSView {
    private let field = NSTextField(), stepper = NSStepper()
    private let change: (Int) -> Void

    init(title: String, value: Int, change: @escaping (Int) -> Void) {
        self.change = change
        super.init(frame: CGRect(x: 0, y: 0, width: 220, height: 30))
        let label = NSTextField(labelWithString: title)
        label.frame = CGRect(x: 20, y: 6, width: 110, height: 17)
        field.frame = CGRect(x: 134, y: 4, width: 44, height: 22)
        field.integerValue = value
        field.target = self; field.action = #selector(typed)
        stepper.frame = CGRect(x: 182, y: 3, width: 19, height: 24)
        stepper.minValue = 0; stepper.maxValue = 999; stepper.integerValue = value
        stepper.target = self; stepper.action = #selector(stepped)
        [label, field, stepper].forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func typed() { stepper.integerValue = field.integerValue; change(field.integerValue) }
    @objc private func stepped() { field.integerValue = stepper.integerValue; change(stepper.integerValue) }
}

/// The "Drag Me" pill: drags the flattened image out as a file.
/// The title bar's file name chip: drag it to drop the annotated screenshot into another app.
final class DragPill: NSView, NSDraggingSource {
    var provider: (() -> (URL, CGImage)?)?
    private let label = NSTextField(labelWithString: "")
    private let grip = NSImageView()

    init(frame: NSRect, title: String) {
        super.init(frame: frame)
        wantsLayer = true
        layer!.cornerRadius = 7
        layer!.cornerCurve = .continuous
        toolTip = "Drag to drop the screenshot into another app"
        grip.image = Icon.image("grip", size: 12, color: Palette.muted)
        grip.frame = CGRect(x: 8, y: (frame.height - 12) / 2, width: 12, height: 12)
        addSubview(grip)
        label.stringValue = title
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = Palette.icon
        label.lineBreakMode = .byTruncatingMiddle
        label.sizeToFit()
        addSubview(label)
    }

    var preferredWidth: CGFloat { label.fittingSize.width + 34 }

    override func layout() {
        super.layout()
        label.frame = CGRect(x: 24, y: (bounds.height - label.frame.height) / 2, width: bounds.width - 30, height: label.frame.height)
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { layer!.backgroundColor = Palette.button.cgColor }
    override func mouseExited(with event: NSEvent) { layer!.backgroundColor = nil }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }

    override func mouseDragged(with event: NSEvent) {
        guard let (url, img) = provider?() else { return }
        let p = convert(event.locationInWindow, from: nil)
        let w: CGFloat = 130, h = w * CGFloat(img.height) / CGFloat(img.width)
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(CGRect(x: p.x - w / 2, y: p.y - h / 2, width: w, height: h), contents: NSImage(cgImage: img, size: CGSize(width: w, height: h)))
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
}

/// Keeps the save panel's extension in step with the Format popup.
final class PanelFormat: NSObject {
    static let shared = PanelFormat()
    weak var panel: NSSavePanel?
    var formats: [String] = []
    @objc func changed(_ p: NSPopUpButton) {
        guard let type = UTType(formats[p.indexOfSelectedItem]) else { return }
        panel?.allowedContentTypes = [type]
    }
}


/// The crop bar's "Image size" popover: width/height in pixels, proportional by default.
final class ResizeView: NSView {
    private let w = NSTextField(), h = NSTextField(), lock = NSButton(checkboxWithTitle: "Keep proportions", target: nil, action: nil)
    private let ratio: CGFloat
    private let done: (Int?, Int?) -> Void

    init(width: Int, height: Int, done: @escaping (Int?, Int?) -> Void) {
        ratio = CGFloat(width) / CGFloat(height)
        self.done = done
        super.init(frame: CGRect(x: 0, y: 0, width: 300, height: 130))
        for (label, field, y, v) in [("Width:", w, 92.0, width), ("Height:", h, 62.0, height)] {
            let l = NSTextField(labelWithString: label)
            l.frame = CGRect(x: 16, y: y + 3, width: 60, height: 17); l.alignment = .right
            field.frame = CGRect(x: 84, y: y, width: 80, height: 22)
            field.integerValue = v
            field.target = self; field.action = #selector(edited(_:))
            let px = NSTextField(labelWithString: "pixels")
            px.frame = CGRect(x: 170, y: y + 3, width: 50, height: 17)
            [l, field, px].forEach(addSubview)
        }
        lock.state = .on
        lock.frame = CGRect(x: 84, y: 38, width: 160, height: 18)
        addSubview(lock)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.frame = CGRect(x: 120, y: 6, width: 80, height: 28)
        let ok = NSButton(title: "Resize", target: self, action: #selector(apply))
        ok.frame = CGRect(x: 204, y: 6, width: 80, height: 28)
        ok.keyEquivalent = "\r"
        [cancel, ok].forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func edited(_ f: NSTextField) {
        guard lock.state == .on else { return }
        if f === w { h.integerValue = Int((CGFloat(w.integerValue) / ratio).rounded()) }
        else { w.integerValue = Int((CGFloat(h.integerValue) * ratio).rounded()) }
    }
    @objc private func cancel() { done(nil, nil) }
    @objc private func apply() {
        edited(window?.firstResponder === h.currentEditor() ? h : w)
        guard w.integerValue > 0, h.integerValue > 0, w.integerValue <= 20000, h.integerValue <= 20000 else { return NSSound.beep() }
        done(w.integerValue, h.integerValue)
    }
}
