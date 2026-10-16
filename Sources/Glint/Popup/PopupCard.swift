import AppKit
import QuartzCore

/// One popup card: a borderless, non-activating panel (never steals focus from the app you paste into).
/// Glint's card: the screenshot inset in a dark frame; hovering reveals a size chip, close, and a bottom action bar.
final class PopupCard: NSPanel {
    static let size = CGSize(width: 216, height: 152)
    static let margin: CGFloat = 40 // transparent room around the card for its shadow

    private(set) var image: CGImage
    let url: URL
    let cardView: CardView
    var isTucked = false // "Temporarily Hide"
    var isClosing = false // ignore hover/keys once leaving (moving the window re-fires mouseEntered → flicker)
    private var autoCloseTimer: Timer?

    init(image: CGImage, url: URL) {
        self.image = image
        self.url = url
        let s = Self.size, m = Self.margin
        cardView = CardView(frame: NSRect(x: 0, y: 0, width: s.width + 2 * m, height: s.height + 2 * m))
        super.init(contentRect: cardView.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        contentView = cardView
        cardView.card = self
        cardView.show(image)
    }

    override var canBecomeKey: Bool { false }

    static func windowFrame(forCard r: CGRect) -> CGRect { r.insetBy(dx: -margin, dy: -margin) }
    var cardFrame: CGRect { frame.insetBy(dx: Self.margin, dy: Self.margin) }

    func replaceImage(_ new: CGImage) {
        image = new
        cardView.show(new)
        if let data = Output.png(new) { try? data.write(to: url) }
    }

    // MARK: auto-close (paused while hovered)

    func startAutoClose() {
        autoCloseTimer?.invalidate()
        guard Settings.autoClose else { return }
        autoCloseTimer = Timer.scheduledTimer(withTimeInterval: Settings.autoCloseSeconds, repeats: false) { [weak self] _ in
            guard let self else { return }
            if Settings.autoCloseSaves { PopupManager.shared.save(self) } else { PopupManager.shared.close(self) }
        }
    }

    func pauseAutoClose() { autoCloseTimer?.invalidate() }
}

// MARK: - Card view

final class CardView: NSView, NSDraggingSource {
    weak var card: PopupCard!
    private let shadowLayer = CALayer()
    private let imageLayer = CALayer()
    private let frameLayer = CALayer()
    private let sizeChip = SizeChip()
    private let curtain = NSView()
    private let tab = NSView()
    private var downPoint: NSPoint?
    private var dragging = false
    private var popover: NSPopover?
    private var copyButton: CardButton!
    private var saveButton: CardButton!

    var cardRect: CGRect { bounds.insetBy(dx: PopupCard.margin, dy: PopupCard.margin) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let r = cardRect, path = CGPath(roundedRect: r, cornerWidth: 16, cornerHeight: 16, transform: nil)

        shadowLayer.frame = bounds
        shadowLayer.shadowPath = path
        shadowLayer.shadowColor = NSColor.black.cgColor
        shadowLayer.shadowOpacity = 0.4
        shadowLayer.shadowRadius = 16
        shadowLayer.shadowOffset = CGSize(width: 0, height: -10)
        layer!.addSublayer(shadowLayer)

        // Frame: a dark rounded card with a hairline edge; the screenshot sits 6pt inside it.
        frameLayer.frame = r
        frameLayer.backgroundColor = Palette.capsule.cgColor
        frameLayer.cornerRadius = 16
        frameLayer.cornerCurve = .continuous
        frameLayer.borderWidth = 0.5
        frameLayer.borderColor = Palette.panelBorder.cgColor
        layer!.addSublayer(frameLayer)

        imageLayer.frame = r.insetBy(dx: 6, dy: 6)
        imageLayer.cornerRadius = 11
        imageLayer.cornerCurve = .continuous
        imageLayer.masksToBounds = true
        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.backgroundColor = Self.checkerboard
        layer!.addSublayer(imageLayer)

        // Hover chrome (curtain): transparent, so the screenshot stays visible behind the controls.
        curtain.frame = r
        curtain.alphaValue = 0
        let s = PopupCard.size
        sizeChip.frame = NSRect(x: 12, y: s.height - 32, width: 80, height: 20)
        curtain.addSubview(sizeChip)
        curtain.addSubview(CardButton(style: .round, symbol: "close", frame: NSRect(x: s.width - 32, y: s.height - 32, width: 20, height: 20),
                                      tip: "Close (⌘W)") { [weak self] in PopupManager.shared.close(self!.card) })

        let bar = NSView(frame: NSRect(x: 11, y: 11, width: s.width - 22, height: 32))
        bar.wantsLayer = true
        bar.layer!.backgroundColor = Palette.chrome.withAlphaComponent(0.94).cgColor
        bar.layer!.cornerRadius = 9
        bar.layer!.cornerCurve = .continuous
        copyButton = CardButton(style: .accent, title: "Copy", frame: NSRect(x: 5, y: 5, width: 45, height: 22)) {
            [weak self] in PopupManager.shared.copy(self!.card) }
        saveButton = CardButton(style: .secondary, title: "Save", frame: NSRect(x: 54, y: 5, width: 45, height: 22)) {
            [weak self] in PopupManager.shared.save(self!.card) }
        bar.addSubview(copyButton)
        bar.addSubview(saveButton)
        let icons: [(String, String, (PopupCard) -> Void)] = [
            ("pencil", "Annotate (double-click)", { Editor.open(card: $0) }),
            ("pin.fill", "Pin to the Screen", { PopupManager.shared.pin($0) }),
            ("ocr", "Extract Text", { OCR.copyText(from: $0.image) }),
        ]
        for (k, (icon, tip, action)) in icons.enumerated() {
            bar.addSubview(CardButton(style: .icon, symbol: icon, frame: NSRect(x: 103 + CGFloat(k) * 30, y: 5, width: 26, height: 22), tip: tip) {
                [weak self] in if let card = self?.card { action(card) } })
        }
        curtain.addSubview(bar)
        addSubview(curtain)

        // Tab left peeking above the screen edge while tucked away.
        tab.frame = NSRect(x: r.minX, y: r.maxY - 30, width: r.width, height: 30)
        tab.wantsLayer = true
        tab.layer!.backgroundColor = Palette.capsule.cgColor
        tab.layer!.cornerRadius = 16
        tab.layer!.cornerCurve = .continuous
        tab.layer!.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        let chevron = NSImageView(frame: NSRect(x: (r.width - 18) / 2, y: 6, width: 18, height: 18))
        chevron.image = Icon.image("chevron.up", size: 18)
        tab.addSubview(chevron)
        tab.isHidden = true
        addSubview(tab)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ image: CGImage) {
        imageLayer.contents = image
        sizeChip.text = "\(image.width) × \(image.height)"
    }

    /// Feedback: the pressed button turns into a ✓ before the card leaves.
    func confirm(save: Bool) {
        curtain.alphaValue = 1
        (save ? saveButton : copyButton).showTick()
    }

    func hideCurtain() { fadeCurtain(to: 0, duration: 0.25) }

    func setTucked(_ tucked: Bool) {
        tab.isHidden = !tucked
        curtain.alphaValue = 0
    }

    // Clicks in the transparent shadow margin fall through to whatever is behind.
    override func hitTest(_ point: NSPoint) -> NSView? {
        cardRect.contains(convert(point, from: superview)) ? super.hitTest(point) : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: hover

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: cardRect, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        guard !card.isClosing else { return }
        PopupManager.shared.hovered = card
        card.pauseAutoClose()
        guard !card.isTucked else { return }
        fadeCurtain(to: 1, duration: 0.2)
    }

    override func mouseExited(with event: NSEvent) {
        guard !card.isClosing else { return }
        if PopupManager.shared.hovered === card { PopupManager.shared.hovered = nil }
        card.startAutoClose()
        fadeCurtain(to: 0, duration: 0.25)
    }

    private func fadeCurtain(to alpha: CGFloat, duration: Double) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            curtain.animator().alphaValue = alpha
        }
    }

    // MARK: click / drag out

    override func mouseDown(with event: NSEvent) { downPoint = convert(event.locationInWindow, from: nil) }

    override func mouseUp(with event: NSEvent) {
        if card.isTucked { PopupManager.shared.untuck(card) }
        else if event.clickCount == 2 { Editor.open(card: card) } // double-click opens the editor; the popup stays
        downPoint = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard !card.isTucked, !dragging, let start = downPoint else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard hypot(p.x - start.x, p.y - start.y) > 4 else { return }
        dragging = true
        let drag = NSDraggingItem(pasteboardWriter: card.url as NSURL)
        let w: CGFloat = 130, h = w * CGFloat(card.image.height) / CGFloat(card.image.width)
        drag.setDraggingFrame(NSRect(x: p.x - w / 2, y: p.y - h / 2, width: w, height: h),
                              contents: NSImage(cgImage: card.image, size: NSSize(width: w, height: h)))
        beginDraggingSession(with: [drag], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragging = false
        downPoint = nil
        log("drag ended operation=\(operation.rawValue)")
        // ⌥ inverts "close after dragging".
        if operation != [], Settings.closeAfterDragging != NSEvent.modifierFlags.contains(.option) {
            PopupManager.shared.close(card)
        }
    }

    // MARK: swipe toward the screen edge to dismiss

    override func scrollWheel(with event: NSEvent) {
        if !card.isTucked { PopupManager.shared.swipe(event, starting: card) }
    }

    // MARK: context menu

    override func rightMouseDown(with event: NSEvent) {
        guard let card else { return }
        let m = PopupManager.shared
        let menu = NSMenu()
        menu.allowsContextMenuPlugIns = false // no system-injected "Ask Siri" item
        menu.addItem(ActionItem("Copy") { m.copy(card) })
        menu.addItem(ActionItem("Save") { m.save(card) })
        menu.addItem(ActionItem("Save As…") { m.saveAs(card) })
        menu.addItem(ActionItem("Pin to the Screen") { m.pin(card) })
        menu.addItem(ActionItem("Annotate", key: "e") { Editor.open(card: card) })
        menu.addItem(ActionItem("Extract Text") { OCR.copyText(from: card.image) })
        menu.addItem(.separator())
        menu.addItem(ActionItem("Quick Look", key: " ", mods: []) { [weak self] in self?.toggleQuickLook() })
        menu.addItem(ActionItem("Rotate Left") { m.transform(card, rotateLeft: true) })
        menu.addItem(ActionItem("Flip Horizontal") { m.transform(card, rotateLeft: false) })
        menu.addItem(.separator())
        menu.addItem(ActionItem("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([card.url]) })
        menu.addItem(ActionItem("Move to Trash") { m.trash(card) })
        menu.addItem(.separator())
        menu.addItem(ActionItem("Temporarily Hide") { m.tuck(card) })
        menu.addItem(ActionItem("Close", key: "w") { m.close(card) })
        menu.addItem(ActionItem("Close All") { m.closeAll() })
        menu.addItem(ActionItem("Save All") { m.saveAll() })
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    // MARK: Quick Look (popover beside the card; Space toggles while hovered)

    func toggleQuickLook() {
        if let p = popover, p.isShown { p.close(); return }
        let screen = card.screen ?? NSScreen.main!
        let scale = screen.backingScaleFactor
        let maxW = min(1370, screen.visibleFrame.width - PopupCard.size.width - 120), maxH = min(782, screen.visibleFrame.height - 80)
        let px = CGSize(width: CGFloat(card.image.width) / scale, height: CGFloat(card.image.height) / scale)
        let k = min(maxW / px.width, maxH / px.height, 1)
        let size = CGSize(width: (px.width * k).rounded(), height: (px.height * k).rounded())

        let content = NSView(frame: NSRect(origin: .zero, size: CGSize(width: size.width + 24, height: size.height + 24)))
        let iv = NSImageView(frame: NSRect(x: 12, y: 12, width: size.width, height: size.height))
        iv.image = NSImage(cgImage: card.image, size: size)
        iv.imageScaling = .scaleProportionallyUpOrDown
        content.addSubview(iv)
        let p = NSPopover()
        content.addSubview(CardButton(style: .round, symbol: "close", frame: NSRect(x: 20, y: content.frame.height - 44, width: 24, height: 24),
                                      tip: "Close") { p.close() })
        let vc = NSViewController()
        vc.view = content
        p.contentViewController = vc
        p.behavior = .applicationDefined
        p.show(relativeTo: cardRect, of: self, preferredEdge: Settings.popupOnLeft ? .maxX : .minX)
        popover = p
    }

    func closeQuickLook() { popover?.close() }

    private static let checkerboard: CGColor = {
        let img = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { _ in
            NSColor(white: 0.78, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: 16, height: 16).fill()
            NSColor(white: 0.62, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: 8, height: 8).fill(); NSRect(x: 8, y: 8, width: 8, height: 8).fill()
            return true
        }
        return NSColor(patternImage: img).cgColor
    }()
}

// MARK: - Small helpers

/// Light-gray circle (symbol) or pill (title) button that works on first click in an inactive app.
final class CardButton: NSButton {
    enum Style { case accent, secondary, icon, round }
    private let handler: () -> Void
    private let style: Style

    init(style: Style, symbol: String? = nil, title: String? = nil, frame: NSRect, tip: String? = nil, _ handler: @escaping () -> Void) {
        self.handler = handler
        self.style = style
        super.init(frame: frame)
        isBordered = false
        wantsLayer = true
        layer!.cornerRadius = style == .round ? frame.height / 2 : 6
        layer!.cornerCurve = .continuous
        layer!.backgroundColor = switch style {
        case .accent: Palette.accent.cgColor
        case .secondary: Palette.button.cgColor
        case .icon: NSColor.clear.cgColor
        case .round: Palette.chrome.withAlphaComponent(0.88).cgColor
        }
        if let symbol {
            image = Icon.image(symbol, size: style == .round ? 14 : 16)
            imagePosition = .imageOnly
        }
        if let title {
            attributedTitle = NSAttributedString(string: title, attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.white])
        }
        toolTip = tip
        target = self
        action = #selector(fire)
    }

    required init?(coder: NSCoder) { fatalError() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    @objc private func fire() { handler() }

    /// Dim immediately while the mouse is down so the click visibly lands (super runs the tracking loop until mouse-up).
    override func mouseDown(with event: NSEvent) {
        alphaValue = 0.55
        super.mouseDown(with: event)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }
    }

    /// The label fades to a faint ghost and a wide, heavy ✓ draws itself in (custom path; the SF glyph read too thin).
    func showTick() {
        let c = CGPoint(x: bounds.midX, y: bounds.midY), up: CGFloat = isFlipped ? -1 : 1 // NSButton is flipped
        let path = CGMutablePath()
        path.move(to: CGPoint(x: c.x - 6, y: c.y + 0.5 * up))      // short arm
        path.addLine(to: CGPoint(x: c.x - 1.8, y: c.y - 3.6 * up)) // bottom
        path.addLine(to: CGPoint(x: c.x + 6.5, y: c.y + 4.6 * up)) // long arm
        let tick = CAShapeLayer()
        tick.frame = bounds
        tick.path = path
        tick.fillColor = nil
        tick.strokeColor = NSColor.white.cgColor
        tick.lineWidth = 2.2
        tick.lineCap = .round
        tick.lineJoin = .round
        tick.contentsScale = window?.backingScaleFactor ?? 2
        layer!.addSublayer(tick)

        let draw = CABasicAnimation(keyPath: "strokeEnd")
        draw.fromValue = 0
        draw.toValue = 1
        draw.duration = 0.3
        draw.timingFunction = CAMediaTimingFunction(name: .easeOut)
        tick.add(draw, forKey: "draw")

        // The label stays as a faint ghost under the ✓.
        let faded = NSMutableAttributedString(attributedString: attributedTitle)
        faded.addAttribute(.foregroundColor, value: NSColor(white: 1, alpha: 0.12), range: NSRange(location: 0, length: faded.length))
        attributedTitle = faded
        alphaValue = 1
    }
}

final class ActionItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, key: String = "", mods: NSEvent.ModifierFlags = .command, _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        keyEquivalentModifierMask = mods
        target = self
    }

    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { handler() }
}

/// "1920 × 1080" pill in the card's top-left corner while hovered.
final class SizeChip: NSView {
    private let label = NSTextField(labelWithString: "")
    var text = "" { didSet { label.stringValue = text; label.sizeToFit(); layout() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer!.backgroundColor = Palette.chrome.withAlphaComponent(0.88).cgColor
        layer!.cornerRadius = 6
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        label.textColor = Palette.icon
        addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        frame.size.width = label.frame.width + 14
        label.frame.origin = CGPoint(x: 7, y: (frame.height - label.frame.height) / 2)
    }
}
