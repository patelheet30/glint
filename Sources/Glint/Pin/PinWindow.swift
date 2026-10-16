import AppKit

/// A screenshot pinned above everything (window level 103). Never takes focus: its shortcuts come through the
/// HoverKeys event tap while the cursor is over it, which also lets a locked (click-through) pin be unlocked with ⌘L.
final class PinWindow: NSPanel {
    private(set) static var all: [PinWindow] = []

    let image: CGImage
    let url: URL
    let pinView: PinView
    private let baseSize: CGSize // 100% zoom, in points
    private(set) var zoom: CGFloat = 1
    private(set) var opacity: CGFloat = 1
    private var lockTimer: Timer?

    var locked = false {
        didSet {
            ignoresMouseEvents = locked
            pinView.setChrome(visible: false)
            lockTimer?.invalidate()
            if locked { // opaque normally, 25% while the cursor is over it so you can see underneath
                lockTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                    guard let self else { return }
                    self.pinView.alphaValue = self.isUnderMouse ? 0.25 : self.opacity
                }
            } else {
                pinView.alphaValue = opacity
            }
        }
    }

    /// Opens a pin that springs out of `source` (screen rect) to the image's true size, centred and fitted to the screen.
    @discardableResult
    static func open(_ image: CGImage, url: URL, from source: CGRect?) -> PinWindow {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main!
        let pin = PinWindow(image: image, url: url, scale: screen.backingScaleFactor)
        let vf = screen.visibleFrame
        let fit = min(1, vf.width / pin.baseSize.width, vf.height / pin.baseSize.height)
        pin.zoom = fit
        let size = CGSize(width: pin.baseSize.width * fit, height: pin.baseSize.height * fit)
        let target = CGRect(x: vf.midX - size.width / 2, y: vf.midY - size.height / 2, width: size.width, height: size.height).integral
        pin.setFrame(source ?? target, display: false)
        pin.orderFrontRegardless()
        Tween.run(pin, to: target, duration: 0.34, curve: Tween.backOut(0.8))
        pin.pinView.updateZoomLabel()
        all.append(pin)
        HoverKeys.shared.install()
        return pin
    }

    private init(image: CGImage, url: URL, scale: CGFloat) {
        self.image = image
        self.url = url
        baseSize = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        pinView = PinView(frame: CGRect(origin: .zero, size: baseSize))
        super.init(contentRect: pinView.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = Settings.pinShadow
        level = NSWindow.Level(rawValue: 103)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        contentView = pinView
        pinView.pin = self
        pinView.show(image)
    }

    override var canBecomeKey: Bool { false }

    var isUnderMouse: Bool { NSMouseInRect(NSEvent.mouseLocation, frame, false) }

    // MARK: actions

    func close(animated: Bool = true) {
        lockTimer?.invalidate()
        PinWindow.all.removeAll { $0 === self }
        guard animated else { return orderOut(nil) }
        Tween.run(self, to: frame, alpha: 0, duration: 0.15, curve: { $0 }, alphaCurve: { $0 }) { [weak self] in self?.orderOut(nil) }
    }

    /// Zoom keeping `anchor` (screen point, default: centre) fixed. 10%–400%.
    func setZoom(_ z: CGFloat, anchor: CGPoint? = nil) {
        let z = min(4, max(0.1, z))
        let a = anchor ?? CGPoint(x: frame.midX, y: frame.midY)
        let k = z / zoom
        let size = CGSize(width: baseSize.width * z, height: baseSize.height * z)
        let origin = CGPoint(x: a.x - (a.x - frame.minX) * k, y: a.y - (a.y - frame.minY) * k)
        zoom = z
        Tween.cancel(self)
        setFrame(CGRect(origin: origin, size: size).integral, display: true)
        invalidateShadow()
        pinView.updateZoomLabel()
    }

    func setOpacity(_ value: CGFloat) {
        opacity = value
        if !locked { pinView.alphaValue = value }
    }

    func copyImage() { Output.copy(image, file: url) }
    func saveAs() { _ = Output.saveAs(image, name: url.lastPathComponent) }

    // MARK: keys (from the event tap) for the pin under the cursor, including locked ones

    static func handleKey(_ event: CGEvent) -> Bool {
        let mouse = NSEvent.mouseLocation
        // Newest pin is frontmost (NSApp.orderedWindows is empty for this background app).
        guard let pin = all.last(where: { NSMouseInRect(mouse, $0.frame, false) }) else { return false }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let mods = event.flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl])
        switch (code, mods) {
        case (53, []), (13, .maskCommand): pin.close()       // Esc, ⌘W
        case (14, .maskCommand): Editor.open(image: pin.image, url: pin.url) // ⌘E
        case (8, .maskCommand): pin.copyImage()                   // ⌘C
        case (1, .maskCommand): pin.saveAs()                 // ⌘S
        case (37, .maskCommand): pin.locked.toggle()         // ⌘L
        case (29, .maskCommand): pin.setZoom(1)              // ⌘0
        case (19, []): pin.setOpacity(0.2)                   // 2
        case (23, []): pin.setOpacity(0.5)                   // 5
        case (29, []): pin.setOpacity(1)                     // 0
        default: return false
        }
        return true
    }
}

// MARK: - Content

final class PinView: NSView, NSDraggingSource {
    weak var pin: PinWindow!
    private let imageLayer = CALayer()
    private let chrome = NSView()
    private let zoomLabel = NSTextField(labelWithString: "100%")
    private var lockButton: CardButton!

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        imageLayer.frame = bounds
        imageLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        imageLayer.contentsGravity = .resize
        imageLayer.cornerCurve = .continuous
        imageLayer.masksToBounds = true
        layer!.addSublayer(imageLayer)
        applyStyle()

        // Hover chrome: close top-left, lock top-right, zoom chip top-centre, drag grip bottom-centre.
        chrome.frame = bounds
        chrome.autoresizingMask = [.width, .height]
        chrome.alphaValue = 0
        let close = CardButton(style: .round, symbol: "close", frame: NSRect(x: 9, y: bounds.height - 33, width: 24, height: 24), tip: "Close (Esc)") {
            [weak self] in self?.pin.close() }
        close.autoresizingMask = [.minYMargin, .maxXMargin]
        lockButton = CardButton(style: .round, symbol: "lock", frame: NSRect(x: bounds.width - 33, y: bounds.height - 33, width: 24, height: 24),
                                tip: "Lock (⌘L)") { [weak self] in self?.pin.locked = true }
        lockButton.autoresizingMask = [.minYMargin, .minXMargin]
        let pill = NSView(frame: NSRect(x: (bounds.width - 52) / 2, y: bounds.height - 30, width: 52, height: 20))
        pill.wantsLayer = true
        pill.layer!.backgroundColor = Palette.chrome.withAlphaComponent(0.88).cgColor
        pill.layer!.cornerRadius = 7
        pill.autoresizingMask = [.minYMargin, .minXMargin, .maxXMargin]
        zoomLabel.frame = pill.bounds.offsetBy(dx: 0, dy: -3)
        zoomLabel.alignment = .center
        zoomLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        zoomLabel.textColor = .white
        pill.addSubview(zoomLabel)
        let grip = GripView(frame: NSRect(x: (bounds.width - 41) / 2, y: 6, width: 41, height: 15))
        grip.autoresizingMask = [.minXMargin, .maxXMargin, .maxYMargin]
        [close, lockButton, pill, grip].forEach { chrome.addSubview($0) }
        addSubview(chrome)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ image: CGImage) { imageLayer.contents = image }

    func applyStyle() {
        imageLayer.cornerRadius = Settings.pinRounded ? 10 : 0
        imageLayer.borderWidth = Settings.pinBorder ? 1 : 0
        imageLayer.borderColor = NSColor(white: 0.5, alpha: 0.5).cgColor
        pin?.hasShadow = Settings.pinShadow
        pin?.invalidateShadow()
    }

    func updateZoomLabel() { zoomLabel.stringValue = "\(Int((pin.zoom * 100).rounded()))%" }

    func setChrome(visible: Bool) {
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; chrome.animator().alphaValue = visible ? 1 : 0 }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { if !pin.locked { setChrome(visible: true) } }
    override func mouseExited(with event: NSEvent) { setChrome(visible: false) }

    // Scroll / pinch zoom around the cursor (5% per scroll step).
    override func scrollWheel(with event: NSEvent) {
        guard event.scrollingDeltaY != 0 else { return }
        pin.setZoom(pin.zoom * (event.scrollingDeltaY < 0 ? 1.05 : 1 / 1.05), anchor: NSEvent.mouseLocation)
    }

    override func magnify(with event: NSEvent) {
        pin.setZoom(pin.zoom * (1 + event.magnification), anchor: NSEvent.mouseLocation)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let pin else { return }
        let menu = NSMenu()
        menu.allowsContextMenuPlugIns = false
        menu.addItem(ActionItem("Close", key: "w") { pin.close() })
        menu.addItem(.separator())
        menu.addItem(ActionItem("Open Annotation Tool", key: "e") { Editor.open(image: pin.image, url: pin.url) })
        menu.addItem(ActionItem("Copy to Clipboard", key: "c") { pin.copyImage() })
        menu.addItem(ActionItem("Extract Text") { OCR.copyText(from: pin.image) })
        menu.addItem(ActionItem("Save As…", key: "s") { pin.saveAs() })
        menu.addItem(.separator())
        menu.addItem(ActionItem("Lock", key: "l") { pin.locked = true })
        menu.addItem(.separator())
        menu.addItem(header("Zoom"))
        for (title, z, key) in [("50%", 0.5, ""), ("100%", 1.0, "0"), ("200%", 2.0, "")] {
            menu.addItem(ActionItem(title, key: key) { pin.setZoom(z) })
        }
        menu.addItem(.separator())
        menu.addItem(header("Opacity"))
        for (title, o, key) in [("20%", 0.2, "2"), ("50%", 0.5, "5"), ("100%", 1.0, "0")] {
            menu.addItem(ActionItem(title, key: key, mods: []) { pin.setOpacity(o) })
        }
        menu.addItem(.separator())
        for (title, get, set) in [("Shadow", Settings.pinShadow, { Settings.pinShadow.toggle() }),
                                  ("Rounded Corners", Settings.pinRounded, { Settings.pinRounded.toggle() }),
                                  ("Border", Settings.pinBorder, { Settings.pinBorder.toggle() })] {
            let item = ActionItem(title) { set(); PinWindow.all.forEach { $0.pinView.applyStyle() } }
            item.state = get ? .on : .off
            menu.addItem(item)
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    private func header(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // Drag-out from the grip.
    func startFileDrag(_ event: NSEvent) {
        let drag = NSDraggingItem(pasteboardWriter: pin.url as NSURL)
        let p = convert(event.locationInWindow, from: nil)
        let w: CGFloat = 130, h = w * CGFloat(pin.image.height) / CGFloat(pin.image.width)
        drag.setDraggingFrame(NSRect(x: p.x - w / 2, y: p.y - h / 2, width: w, height: h),
                              contents: NSImage(cgImage: pin.image, size: NSSize(width: w, height: h)))
        beginDraggingSession(with: [drag], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
}

/// Bottom-centre grip: dragging it drags the image file out (dragging anywhere else moves the pin).
final class GripView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer!.backgroundColor = NSColor(white: 0.1, alpha: 0.7).cgColor
        layer!.cornerRadius = frame.height / 2
        let icon = NSImageView(frame: bounds.insetBy(dx: 12, dy: 2))
        icon.image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: "Drag")
        icon.contentTintColor = .white
        addSubview(icon)
        toolTip = "Drag to another app"
    }

    required init?(coder: NSCoder) { fatalError() }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    private var started = false
    override func mouseDown(with event: NSEvent) { started = false }
    override func mouseDragged(with event: NSEvent) {
        guard !started else { return }
        started = true
        (superview?.superview as? PinView)?.startFileDrag(event)
    }
}
