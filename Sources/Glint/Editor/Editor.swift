import AppKit

/// The annotate editor: a canvas-first window. A slim title bar holds the file name and the export actions; tools float
/// in a rail on the left, the current tool's options float in an inspector at the bottom (crop controls replace them in
/// crop mode), and the background panel (B) floats on the right.
final class Editor: NSObject, NSWindowDelegate {
    private(set) static var open: [Editor] = []
    static var clipboard: Item? // ⌘C / ⌘V of objects, shared by all editors

    let window: EditorWindow
    let source: URL
    private weak var card: PopupCard?
    var doc: Doc { didSet { docChanged() } }
    private var undoStack: [Doc] = [], redoStack: [Doc] = []
    private var dirty = false

    struct Crop { var rect: CGRect; var ratio: CGFloat?; var snap = true; var start: Doc }
    var crop: Crop?

    // Current tool and styles (applied to new items and to the selected one).
    var tool: Tool = (UserDefaults.standard.object(forKey: "editorTool") as? Int).flatMap(Tool.init(rawValue:)) ?? .arrow
    var color = Palette.red, width: CGFloat = 4, arrowStyle = ArrowStyle.standard
    var fontSize: CGFloat = 30, textStyle = TextStyle.standard, spot = SpotShape.rounded, counterStart = 1

    let canvas: CanvasView
    let scroll = EditorScrollView()
    private let root = EditorRoot()
    private let titleBar = Bar()
    private let titleLine = NSView()
    private let rail = FloatingPanel()
    private let strip = ToolStrip()
    private let inspector = FloatingPanel()
    private let options = FlippedView()   // tool options (inspector content)
    private let cropTools = FlippedView() // crop controls (inspector content in crop mode)
    private let zoomPanel = FloatingPanel()
    private var backgroundButton: EButton!
    private var zoomButton: EButton!
    private var titleChip: DragPill!
    private var sidebar: BackgroundPanel?
    private var cropSizeButton: EButton!, cropW = NSTextField(), cropH = NSTextField(), revertButton: EButton!
    private var ratioPopup = NSPopUpButton()

    static let titleHeight: CGFloat = 40
    /// Room kept clear around the image for the floating rail and inspector when fitting.
    static let fitMargins = CGSize(width: 168, height: 136)

    static let zoomSteps: [CGFloat] = [0.1, 0.25, 0.5, 1, 2, 4, 8, 16, 32]

    // MARK: open

    static func open(card: PopupCard) { open(image: card.image, url: card.url, card: card) }

    static func open(image: CGImage, url: URL, card: PopupCard? = nil) {
        if let e = open.first(where: { $0.source == url }) {
            NSApp.activate(ignoringOtherApps: true); e.window.makeKeyAndOrderFront(nil); e.window.orderFrontRegardless(); return
        }
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main!
        let e = Editor(doc: Doc(image: image, scale: screen.backingScaleFactor), url: url, card: card)
        open.append(e)
        e.show(on: screen)
    }

    private init(doc: Doc, url: URL, card: PopupCard?) {
        self.doc = doc
        source = url
        self.card = card
        window = EditorWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        canvas = CanvasView()
        super.init()
        canvas.editor = self
        build()
    }

    private func show(on screen: NSScreen) {
        // Window fits the image at ≤100% within the screen, with room for the floating rail and inspector.
        let vf = screen.visibleFrame, img = doc.layout.canvas, m = Editor.fitMargins
        let z = min(1, (vf.height - Editor.titleHeight - m.height - 40) / img.height, (vf.width * 0.85 - m.width) / img.width)
        let size = CGSize(width: max(760, (img.width * z).rounded() + m.width),
                          height: max(600, (img.height * z).rounded() + m.height + Editor.titleHeight))
        let frame = CGRect(x: vf.midX - size.width / 2, y: vf.midY - size.height / 2, width: size.width, height: size.height).integral
        window.setFrame(frame, display: true)
        window.layoutIfNeeded()
        root.layout()
        fit()

        // Opening: ~98% → 100% with a small overshoot (~200 ms).
        let small = frame.insetBy(dx: frame.width * 0.01, dy: frame.height * 0.01)
        window.setFrame(small, display: false)
        window.alphaValue = 0
        NSApp.activate(ignoringOtherApps: true) // cooperative on macOS 14+: can be refused,
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()           // so never leave the editor behind the active app
        window.makeFirstResponder(canvas)
        Tween.run(window, to: frame, alpha: 1, duration: 0.2, curve: Tween.backOut(1.2), alphaCurve: { min(1, $0 * 2) })
    }

    // MARK: layout

    private func build() {
        window.editor = self
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = Palette.chrome
        window.minSize = NSSize(width: 760, height: 600)
        window.contentView = root
        root.editor = self

        scroll.contentView = CenteringClipView()
        scroll.documentView = canvas
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.1
        scroll.maxMagnification = 32
        scroll.backgroundColor = Palette.canvas
        scroll.drawsBackground = true
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
            self?.updateZoomLabel()
        }
        root.addSubview(scroll)
        root.addSubview(titleBar)
        titleLine.wantsLayer = true
        titleLine.layer!.backgroundColor = Palette.hairline.cgColor
        root.addSubview(titleLine)
        canvas.wantsLayer = true // soft shadow lifts the image off the canvas
        canvas.shadow = { let s = NSShadow(); s.shadowColor = NSColor(white: 0, alpha: 0.5); s.shadowBlurRadius = 16; s.shadowOffset = NSSize(width: 0, height: -4); return s }()
        canvas.setFrameSize(doc.layout.canvas)

        buildTitleBar()
        buildRail()
        buildInspector()
        buildCropBar()
        strip.selected = tool
        rebuildOptions()
    }

    /// Lays out the title bar, floating panels and canvas (called from EditorRoot.layout).
    func layoutRoot(_ b: CGRect) {
        let th = Editor.titleHeight
        titleBar.frame = CGRect(x: 0, y: b.height - th, width: b.width, height: th)
        titleLine.frame = CGRect(x: 0, y: b.height - th - 1, width: b.width, height: 1)
        let side: CGFloat = sidebar == nil ? 0 : 272
        scroll.frame = CGRect(x: 0, y: 0, width: b.width - side, height: b.height - th - 1)
        sidebar?.frame = CGRect(x: b.width - 262, y: 10, width: 252, height: b.height - th - 21)
        rail.frame.origin = CGPoint(x: 12, y: ((b.height - th - rail.frame.height) / 2).rounded())
        layoutInspector()
        zoomPanel.frame.origin = CGPoint(x: b.width - side - zoomPanel.frame.width - 12, y: 12)
        layoutTitleBar(b.width)
        layoutTitlebarButtons()
    }

    /// The window's own titlebar is stretched to our 40pt bar so the traffic lights sit centred in it.
    private func layoutTitlebarButtons() {
        let kinds: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        guard let close = window.standardWindowButton(.closeButton), let container = close.superview?.superview else { return }
        container.frame = CGRect(x: 0, y: window.frame.height - Editor.titleHeight, width: window.frame.width, height: Editor.titleHeight)
        for (i, k) in kinds.enumerated() {
            guard let b = window.standardWindowButton(k), let sv = b.superview else { continue }
            b.setFrameOrigin(CGPoint(x: 14 + CGFloat(i) * 20, y: (sv.bounds.height - b.frame.height) / 2))
        }
    }

    private var titleActions: [NSView] = []

    private func buildTitleBar() {
        // File name chip: drag it out to drop the annotated image into another app.
        titleChip = DragPill(frame: CGRect(x: 84, y: 7, width: 300, height: 26), title: source.deletingPathExtension().lastPathComponent)
        titleChip.provider = { [weak self] in self?.exportForDrag() }
        titleBar.addSubview(titleChip)
        let icon = { (symbol: String, tip: String, action: @escaping (EButton) -> Void) -> EButton in
            let b = EButton(frame: CGRect(x: 0, y: 7, width: 30, height: 26), symbol: symbol, fill: .clear, tip: tip) { }
            b.handlerWithSelf = action
            return b
        }
        titleActions = [
            icon("doc.on.doc.fill", "Copy and close (⇧⌘C)") { [weak self] _ in self?.copyAndClose() },
            icon("pin.fill", "Pin and close") { [weak self] _ in self?.pinAndClose() },
            icon("square.and.arrow.up", "Share") { [weak self] b in self?.share(b) },
            EButton(frame: CGRect(x: 0, y: 7, width: 76, height: 26), title: "Save as…", fill: Palette.button, tip: "Save to a location and close (⇧⌘S)") { [weak self] in self?.saveAs() },
            EButton(frame: CGRect(x: 0, y: 7, width: 58, height: 26), title: "Done", fill: Palette.accent, tip: "Save changes and close (⌘S)") { [weak self] in self?.saveAndClose() },
        ]
        titleActions.forEach(titleBar.addSubview)
    }

    private func layoutTitleBar(_ w: CGFloat) {
        var x = w - 10
        for (k, v) in titleActions.enumerated().reversed() {
            x -= v.frame.width
            v.frame.origin.x = x
            x -= k >= 3 ? 8 : 2
        }
        titleChip.frame.size.width = min(titleChip.preferredWidth, max(80, x - 8 - 84))
    }

    private var railButtons: [EButton] = []

    private func buildRail() {
        let cell = ToolStrip.cell
        strip.frame = CGRect(origin: CGPoint(x: 4, y: 6), size: strip.intrinsicContentSize)
        strip.onSelect = { [weak self] t in self?.setTool(t) }
        rail.addSubview(strip)
        let sep = NSView(frame: CGRect(x: 10, y: strip.frame.maxY + 5, width: cell.width - 12, height: 1))
        sep.wantsLayer = true
        sep.layer!.backgroundColor = Palette.panelBorder.cgColor
        rail.addSubview(sep)
        backgroundButton = EButton(frame: .zero, symbol: "photo.artframe", fill: .clear, tip: "Background (B)") { [weak self] in self?.toggleBackground() }
        railButtons = [
            EButton(frame: .zero, symbol: "crop", fill: .clear, tip: "Crop and resize (K)") { [weak self] in self?.enterCrop() },
            backgroundButton,
            EButton(frame: .zero, symbol: "photo.badge.plus", fill: .clear, tip: "Add a screenshot") { [weak self] in self?.addScreenshot() },
        ]
        for (k, b) in railButtons.enumerated() {
            b.frame = CGRect(x: 7, y: sep.frame.maxY + 5 + CGFloat(k) * cell.height + 2, width: cell.width - 6, height: cell.height - 4)
            b.layer!.cornerRadius = 8
            rail.addSubview(b)
        }
        rail.frame.size = CGSize(width: cell.width + 8, height: (railButtons.last?.frame.maxY ?? 0) + 8)
        root.addSubview(rail)
    }

    private func buildInspector() {
        inspector.addSubview(options)
        inspector.addSubview(cropTools)
        cropTools.isHidden = true
        root.addSubview(inspector)
        zoomButton = EButton(frame: CGRect(x: 4, y: 4, width: 64, height: 26), title: "100%", fill: .clear, tip: "Zoom") { }
        zoomButton.chevron = true
        zoomButton.handlerWithSelf = { [weak self] b in self?.zoomMenu(b) }
        zoomPanel.frame.size = CGSize(width: 72, height: 34)
        zoomPanel.addSubview(zoomButton)
        root.addSubview(zoomPanel)
    }

    /// Sizes the inspector to its content (tool options or crop controls), centred at the bottom of the canvas.
    private func layoutInspector() {
        let content = crop != nil ? cropTools : options
        let w = content.frame.width
        inspector.isHidden = w == 0
        inspector.frame.size = CGSize(width: w + 16, height: 38)
        content.frame.origin = CGPoint(x: 8, y: 6)
        let area = scroll.frame
        inspector.frame.origin = CGPoint(x: (area.midX - inspector.frame.width / 2).rounded(), y: 12)
    }

    // MARK: tools & options

    func setTool(_ t: Tool) {
        if crop != nil { return }
        canvas.endTextEditing()
        tool = t
        strip.selected = t
        UserDefaults.standard.set(t.rawValue, forKey: "editorTool")
        if t != .select { canvas.selection = nil }
        rebuildOptions()
    }

    var selectedItem: Item? { canvas.selection.flatMap { doc.items.indices.contains($0) ? doc.items[$0] : nil } }

    func selectionChanged() {
        if let it = selectedItem { // reflect the selected object's style in the option buttons
            color = it.color
            if it.tool != .text && it.tool != .counter { width = it.width }
            if it.tool == .arrow { arrowStyle = it.arrow }
            if it.tool == .text { fontSize = it.fontSize; textStyle = it.textStyle }
            if it.tool == .spotlight { spot = it.spot }
        }
        rebuildOptions()
    }

    /// Option buttons for the selected object's tool, or the current tool (color first).
    func rebuildOptions() {
        options.subviews.forEach { $0.removeFromSuperview() }
        let t = selectedItem?.tool ?? tool
        var x: CGFloat = 0
        func add(_ v: NSView) {
            if x > 0 { // hairline divider between groups
                let d = NSView(frame: CGRect(x: x + 2, y: 6, width: 1, height: 14))
                d.wantsLayer = true; d.layer!.backgroundColor = Palette.panelBorder.cgColor
                options.addSubview(d); x += 9
            }
            v.frame.origin = CGPoint(x: x, y: (26 - v.frame.height) / 2); options.addSubview(v); x += v.frame.width + 4
        }
        func option(_ image: NSImage, _ tip: String, _ action: @escaping (EButton) -> Void) -> EButton {
            let b = EButton(frame: CGRect(x: 0, y: 0, width: 42, height: 26), tip: tip, handler: {})
            b.fill = .clear
            b.image = OptionArt.withChevron(image)
            b.handlerWithSelf = action
            return b
        }
        defer {
            options.frame.size = CGSize(width: max(0, x - 4), height: 26)
            layoutInspector()
        }
        let hasColor: Set<Tool> = [.rect, .filledRect, .ellipse, .line, .arrow, .text, .counter, .pencil, .marker]
        if hasColor.contains(t) {
            add(SwatchRow(current: color) { [weak self] c in if let c { self?.setColor(c) } else { self?.openColorPanel() } })
        }
        if [.rect, .filledRect, .ellipse, .line, .arrow, .pencil, .marker].contains(t) {
            add(option(OptionArt.thickness(width), "Thickness") { [weak self] b in self?.thicknessMenu(b) })
        }
        switch t {
        case .arrow:
            add(option(OptionArt.arrow(arrowStyle), "Arrow Style") { [weak self] b in self?.arrowMenu(b) })
        case .text:
            let size = EButton(frame: CGRect(x: 0, y: 0, width: 68, height: 26), title: "\(Int(fontSize)) pt", fill: .clear, tip: "Font size") { }
            size.chevron = true
            size.handlerWithSelf = { [weak self] b in self?.fontSizeMenu(b) }
            add(size)
            add(option(OptionArt.italicA, "Text Style") { [weak self] b in self?.textStyleMenu(b) })
        case .pixelate:
            add(option(OptionArt.symbol(["pixelate", "blur", "blur", "blackout"][doc.redact.rawValue]), "Redaction Style") { [weak self] b in self?.redactMenu(b) })
            if doc.redact != .blackOut { // a solid fill has no intensity
                add(slider(value: doc.redactIntensity, min: 3, max: 30, tip: "Intensity") { [weak self] v in self?.setRedactIntensity(v) })
            }
        case .spotlight:
            add(option(OptionArt.symbol(["square", "rounded", "oval"][spot.rawValue]), "Spotlight Shape") { [weak self] b in self?.spotMenu(b) })
            add(slider(value: doc.spotOpacity, min: 0, max: 100, tip: "Opacity") { [weak self] v in self?.setSpotOpacity(v) })
        case .counter:
            add(option(OptionArt.symbol("number"), "Counter Settings") { [weak self] b in self?.counterMenu(b) })
        default: break
        }
    }

    private var sliderBefore: Doc?

    private func slider(value: CGFloat, min: CGFloat, max: CGFloat, tip: String, _ change: @escaping (CGFloat) -> Void) -> NSSlider {
        let s = ActionSlider(value: Double(value), minValue: Double(min), maxValue: Double(max), target: nil, action: nil)
        s.frame = CGRect(x: 0, y: 0, width: 102, height: 22)
        s.controlSize = .small
        s.toolTip = tip
        s.handler = { [weak self] v in
            guard let self else { return }
            if self.sliderBefore == nil { self.sliderBefore = self.doc }
            change(CGFloat(v))
            if NSApp.currentEvent?.type == .leftMouseUp, let b = self.sliderBefore { self.commit(b); self.sliderBefore = nil }
        }
        return s
    }

    private func setRedactIntensity(_ v: CGFloat) { doc.redactIntensity = v.rounded() }
    private func setSpotOpacity(_ v: CGFloat) { doc.spotOpacity = v.rounded() }

    /// Applies a style change to the selected item (one undo step).
    private func applyToSelection(_ change: (inout Item) -> Void) {
        guard let i = canvas.selection, doc.items.indices.contains(i) else { return }
        let before = doc
        change(&doc.items[i])
        commit(before)
        canvas.refreshTextEditor()
    }

    private func popUp(_ menu: NSMenu, under b: NSView) {
        menu.appearance = NSAppearance(named: .darkAqua)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: b.bounds.height + 4), in: b)
    }

    func setColor(_ c: NSColor) {
        color = c
        applyToSelection { $0.color = c }
        rebuildOptions()
    }

    func openBackgroundColorPanel() { sidebar?.wantsPanelColor = true; openColorPanel() }

    private func openColorPanel() {
        let p = NSColorPanel.shared
        p.color = color
        p.setTarget(self)
        p.setAction(#selector(colorPanelChanged(_:)))
        p.orderFront(nil)
    }

    @objc private func colorPanelChanged(_ p: NSColorPanel) {
        if let sidebar, sidebar.wantsPanelColor { sidebar.apply(color: p.color); return }
        setColor(p.color)
    }

    private func thicknessMenu(_ b: NSView) {
        let m = NSMenu()
        for w in Palette.thickness {
            let item = ActionItem("") { [weak self] in self?.setWidth(w) }
            item.image = OptionArt.thickness(w, size: CGSize(width: 34, height: 24))
            item.state = w == width ? .on : .off
            m.addItem(item)
        }
        popUp(m, under: b)
    }

    func setWidth(_ w: CGFloat) {
        width = w
        applyToSelection { $0.width = w }
        rebuildOptions()
    }

    private func arrowMenu(_ b: NSView) {
        let m = NSMenu()
        for (s, name) in zip(ArrowStyle.allCases, ["Standard", "Fancy", "Curved", "Double"]) {
            let item = ActionItem(name) { [weak self] in
                self?.arrowStyle = s
                self?.applyToSelection { it in
                    it.arrow = s
                    if s == .curved, it.points.count == 2 { it.points.append(CGPoint(x: (it.points[0].x + it.points[1].x) / 2, y: (it.points[0].y + it.points[1].y) / 2)) }
                }
                self?.rebuildOptions()
            }
            item.image = OptionArt.arrow(s)
            item.state = s == arrowStyle ? .on : .off
            m.addItem(item)
        }
        popUp(m, under: b)
    }

    private func fontSizeMenu(_ b: NSView) {
        let m = NSMenu()
        for s: CGFloat in [12, 14, 18, 24, 30, 36, 48, 64, 72, 96] {
            let item = ActionItem("\(Int(s)) pt") { [weak self] in self?.setFontSize(s) }
            item.state = s == fontSize ? .on : .off
            m.addItem(item)
        }
        popUp(m, under: b)
    }

    private func setFontSize(_ s: CGFloat) {
        fontSize = s
        applyToSelection { $0.fontSize = s }
        rebuildOptions()
    }

    private func textStyleMenu(_ b: NSView) {
        let m = NSMenu()
        for (s, name) in zip(TextStyle.allCases, ["Standard", "Rounded", "Outlined", "Mono", "Box", "Mono Box", "Rounded Box"]) {
            let item = ActionItem(name) { [weak self] in
                self?.textStyle = s
                self?.applyToSelection { $0.textStyle = s }
            }
            item.state = s == textStyle ? .on : .off
            m.addItem(item)
        }
        popUp(m, under: b)
    }

    private func redactMenu(_ b: NSView) {
        let m = NSMenu()
        for (s, name) in zip(RedactStyle.allCases, ["Pixelate", "Blur (secure)", "Blur (smooth)", "Black Out"]) {
            let item = ActionItem(name) { [weak self] in
                guard let self else { return }
                let before = self.doc
                self.doc.redact = s // global: every redaction re-renders
                self.commit(before)
                self.rebuildOptions()
            }
            item.state = s == doc.redact ? .on : .off
            m.addItem(item)
        }
        popUp(m, under: b)
    }

    private func spotMenu(_ b: NSView) {
        let m = NSMenu()
        for (s, name) in zip(SpotShape.allCases, ["Rectangle", "Rounded Rectangle", "Ellipse"]) {
            let item = ActionItem(name) { [weak self] in
                self?.spot = s
                self?.applyToSelection { $0.spot = s }
                self?.rebuildOptions()
            }
            item.state = s == spot ? .on : .off
            m.addItem(item)
        }
        popUp(m, under: b)
    }

    private func counterMenu(_ b: NSView) {
        let m = NSMenu()
        for (f, name) in zip(CounterFormat.allCases, ["1, 2, 3", "A, B, C", "I, II, III", "a, b, c"]) {
            let item = ActionItem(name) { [weak self] in
                guard let self else { return }
                let before = self.doc
                self.doc.counterFormat = f // global: relabels existing counters
                self.commit(before)
            }
            item.state = f == doc.counterFormat ? .on : .off
            m.addItem(item)
        }
        m.addItem(.separator())
        let start = NSMenuItem()
        start.view = StepperRow(title: "Starting number", value: counterStart) { [weak self] v in self?.counterStart = v }
        m.addItem(start)
        let sizes = NSMenu()
        for s: CGFloat in [11, 14, 20, 24, 31, 45] {
            let item = ActionItem("\(Int(s)) pt") { [weak self] in
                guard let self else { return }
                let before = self.doc
                self.doc.counterSize = s
                self.commit(before)
            }
            item.state = s == doc.counterSize ? .on : .off
            sizes.addItem(item)
        }
        let sizeItem = NSMenuItem(title: "Size", action: nil, keyEquivalent: "")
        sizeItem.submenu = sizes
        m.addItem(sizeItem)
        popUp(m, under: b)
    }

    /// A new item at `p` with the current style.
    func newItem(_ t: Tool, at p: CGPoint) -> Item {
        var it = Item(tool: t, points: [p, p], color: color, width: width, arrow: arrowStyle, fontSize: fontSize, textStyle: textStyle, spot: spot)
        switch t {
        case .pencil, .marker, .text: it.points = [p]
        case .counter:
            it.points = [p]
            let used = doc.items.filter { $0.tool == .counter }.map(\.number)
            it.number = used.isEmpty ? counterStart : used.max()! + 1
        case .arrow where arrowStyle == .curved: it.points = [p, p, p]
        default: break
        }
        return it
    }

    // MARK: undo

    func commit(_ before: Doc) {
        undoStack.append(before)
        redoStack.removeAll()
        dirty = true
    }

    func undo() {
        canvas.endTextEditing()
        guard let prev = undoStack.popLast() else { return NSSound.beep() }
        redoStack.append(doc)
        canvas.selection = nil
        let size = doc.layout.canvas
        doc = prev
        if doc.layout.canvas != size { fit() } // un-cropping: refit so the image fits again
    }

    func redo() {
        guard let next = redoStack.popLast() else { return NSSound.beep() }
        undoStack.append(doc)
        canvas.selection = nil
        let size = doc.layout.canvas
        doc = next
        if doc.layout.canvas != size { fit() }
    }

    private func docChanged() {
        let size = crop != nil ? doc.imageSize : doc.layout.canvas
        if canvas.frame.size != size { canvas.setFrameSize(size) }
        canvas.needsDisplay = true
        if crop != nil { cropChanged() }
    }

    // MARK: keys

    /// Plain keys (from the canvas). ⌘ combos arrive through `command(_:)`.
    func handleKey(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection([.command, .shift, .option, .control])
        let chars = e.charactersIgnoringModifiers?.lowercased() ?? ""
        if crop != nil {
            switch e.keyCode {
            case 36, 76: applyCrop(); return true  // Return
            case 53: cancelCrop(); return true     // Esc
            default: return false
            }
        }
        switch e.keyCode {
        case 53: // Esc: deselect, then close (asking first if edited)
            if canvas.selection != nil { canvas.selection = nil } else { requestClose() }
            return true
        case 51, 117: // ⌫
            if let i = canvas.selection { let before = doc; canvas.selection = nil; doc.items.remove(at: i); commit(before) }
            return true
        case 123, 124, 125, 126:
            guard let i = canvas.selection else { return true }
            let step: CGFloat = mods.contains(.shift) ? 10 : 1
            let d = [123: CGPoint(x: -step, y: 0), 124: CGPoint(x: step, y: 0), 125: CGPoint(x: 0, y: step), 126: CGPoint(x: 0, y: -step)][Int(e.keyCode)]!
            let before = doc
            doc.items[i] = doc.items[i].moved(by: d)
            commit(before)
            return true
        default: break
        }
        guard mods.subtracting(.shift).isEmpty else { return false }
        if chars == "=" || chars == "+" || chars == "-" { stepSize(chars == "-" ? -1 : 1); return true }
        if chars == "k" { enterCrop(); return true }
        if chars == "b" { toggleBackground(); return true }
        if let t = Tool.toolbar.first(where: { $0.key == chars }) { setTool(t); return true }
        return false
    }

    private func stepSize(_ d: Int) {
        let t = selectedItem?.tool ?? tool
        if t == .text {
            let sizes: [CGFloat] = [12, 14, 18, 24, 30, 36, 48, 64, 72, 96]
            let i = sizes.firstIndex { $0 >= fontSize } ?? 4
            setFontSize(sizes[max(0, min(sizes.count - 1, i + d))])
        } else {
            let i = Palette.thickness.firstIndex { $0 >= width } ?? 2
            setWidth(Palette.thickness[max(0, min(Palette.thickness.count - 1, i + d))])
        }
    }

    /// ⌘ shortcuts. Returns false to let the system have them.
    func command(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection([.command, .shift, .option, .control])
        guard mods.contains(.command) else { return false }
        let shift = mods.contains(.shift)
        let chars = e.charactersIgnoringModifiers?.lowercased() ?? ""
        if canvas.isEditingText { // the text view has no Edit menu to give it these
            let sel: Selector? = ["c": Selector(("copy:")), "x": Selector(("cut:")), "v": Selector(("paste:")), "a": #selector(NSText.selectAll(_:))][chars]
            if let sel { NSApp.sendAction(sel, to: nil, from: nil); return true }
            if chars == "z" { if shift { window.firstResponder?.undoManager?.redo() } else { window.firstResponder?.undoManager?.undo() }; return true }
            return false
        }
        switch (chars, shift) {
        case ("z", false): undo()
        case ("z", true): redo()
        case ("d", false): duplicate()
        case ("c", false): if let it = selectedItem { Editor.clipboard = it }
        case ("v", false): paste()
        case ("c", true): copyAndClose()
        case ("s", false): saveAndClose()
        case ("s", true): saveAs()
        case ("w", false): requestClose()
        case ("=", _), ("+", _): zoom(step: 1)
        case ("-", false): zoom(step: -1)
        case ("0", false): setZoom(1)
        case ("1", false): fit()
        default: return false
        }
        return true
    }

    private func duplicate() {
        guard let it = selectedItem else { return }
        let before = doc
        doc.items.append(it.moved(by: CGPoint(x: 20, y: 20)))
        commit(before)
        canvas.selection = doc.items.count - 1
    }

    private func paste() {
        guard let it = Editor.clipboard else { return }
        // Centre of the visible canvas, in image coordinates.
        let v = scroll.contentView.bounds, o = canvas.origin
        let c = CGPoint(x: v.midX - o.x, y: v.midY - o.y)
        let b = Geometry.outline(it, doc: doc).path.boundingBox
        let before = doc
        doc.items.append(it.moved(by: CGPoint(x: c.x - b.midX, y: c.y - b.midY)))
        commit(before)
        canvas.selection = doc.items.count - 1
    }

    // MARK: zoom

    func zoom(step: Int) {
        let m = scroll.magnification
        let next = step > 0 ? Editor.zoomSteps.first { $0 > m * 1.001 } : Editor.zoomSteps.last { $0 < m * 0.999 }
        if let next { setZoom(next) }
    }

    func setZoom(_ z: CGFloat) {
        let c = scroll.contentView.bounds
        scroll.setMagnification(z, centeredAt: CGPoint(x: c.midX, y: c.midY))
        updateZoomLabel()
    }

    func fit() {
        let m = Editor.fitMargins, size = canvas.frame.size
        let avail = CGSize(width: max(100, scroll.frame.width - m.width), height: max(100, scroll.frame.height - m.height))
        setZoom(min(1, avail.width / size.width, avail.height / size.height))
    }

    private func updateZoomLabel() {
        zoomButton?.setTitle("\(Int((scroll.magnification * 100).rounded()))%")
        canvas.needsDisplay = true // handles are drawn at a constant screen size
    }

    // MARK: zoom chip and crop options

    @objc private func toggleSnap(_ b: NSButton) { crop?.snap = b.state == .on }

    private func zoomMenu(_ b: NSView) {
        let m = NSMenu()
        m.addItem(ActionItem("Zoom In", key: "+") { [weak self] in self?.zoom(step: 1) })
        m.addItem(ActionItem("Zoom Out", key: "-") { [weak self] in self?.zoom(step: -1) })
        m.addItem(ActionItem("Fit Canvas", key: "1") { [weak self] in self?.fit() })
        m.addItem(.separator())
        m.addItem(ActionItem("50%") { [weak self] in self?.setZoom(0.5) })
        m.addItem(ActionItem("100%", key: "0") { [weak self] in self?.setZoom(1) })
        m.addItem(ActionItem("200%") { [weak self] in self?.setZoom(2) })
        m.appearance = NSAppearance(named: .darkAqua)
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: b) // opens upward from the bottom bar
    }

    // MARK: export

    private func flattened() -> CGImage? {
        canvas.endTextEditing()
        return Render.flatten(doc)
    }

    /// The edit goes back into the capture: the popup's thumbnail and file update.
    private func writeBack(_ img: CGImage) {
        if let card { card.replaceImage(img) }
        else if let data = Output.png(img) { try? data.write(to: source) }
        dirty = false
    }

    func saveAndClose() {
        guard let img = flattened() else { return }
        writeBack(img)
        close()
    }

    func copyAndClose() {
        guard let img = flattened() else { return }
        writeBack(img)
        Output.copy(img, file: source)
        close()
    }

    func pinAndClose() {
        guard let img = flattened() else { return }
        writeBack(img)
        let r = canvas.convert(canvas.bounds, to: nil)
        PinWindow.open(img, url: source, from: window.convertToScreen(r).intersection(window.frame))
        close(animated: true)
    }

    private func exportForDrag() -> (URL, CGImage)? {
        guard let img = flattened() else { return nil }
        writeBack(img)
        return (source, img)
    }

    private func share(_ b: NSView) {
        guard let img = flattened() else { return }
        writeBack(img)
        NSSharingServicePicker(items: [source]).show(relativeTo: b.bounds, of: b, preferredEdge: .maxY)
    }

    /// ⇧⌘S / "Save as...": save sheet with a format popup, then close.
    func saveAs() {
        guard let img = flattened() else { return }
        let writable = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        let formats = [("PNG", "public.png", "png"), ("JPEG", "public.jpeg", "jpg"), ("HEIC", "public.heic", "heic"), ("WebP", "org.webmproject.webp", "webp")]
            .filter { writable.contains($0.1) }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = source.deletingPathExtension().lastPathComponent
        panel.directoryURL = Settings.exportDirectory
        panel.isExtensionHidden = false
        let popup = NSPopUpButton(frame: CGRect(x: 60, y: 8, width: 140, height: 26))
        popup.addItems(withTitles: formats.map(\.0))
        let label = NSTextField(labelWithString: "Format:")
        label.frame = CGRect(x: 0, y: 13, width: 56, height: 17)
        label.alignment = .right
        let accessory = NSView(frame: CGRect(x: 0, y: 0, width: 220, height: 42))
        accessory.addSubview(label); accessory.addSubview(popup)
        panel.accessoryView = accessory
        panel.allowedContentTypes = [.png]
        popup.target = PanelFormat.shared
        popup.action = #selector(PanelFormat.changed(_:))
        PanelFormat.shared.panel = panel
        PanelFormat.shared.formats = formats.map(\.1)
        panel.beginSheetModal(for: window) { [weak self] resp in
            guard resp == .OK, let self, let url = panel.url else { return }
            let type = formats[popup.indexOfSelectedItem].1
            guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
            if CGImageDestinationFinalize(dest) { log("editor saved \(url.path)"); self.writeBack(img); self.close() }
        }
    }

    // MARK: closing

    func requestClose() {
        canvas.endTextEditing()
        guard dirty else { return close() }
        let a = NSAlert()
        a.messageText = "Do you want to save the changes you made to the screenshot?"
        a.addButton(withTitle: "Save")
        a.addButton(withTitle: "Don't Save")
        a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: window) { [weak self] r in
            switch r {
            case .alertFirstButtonReturn: self?.saveAndClose()
            case .alertSecondButtonReturn: self?.close()
            default: break
            }
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { requestClose(); return false }

    func close(animated: Bool = false) {
        Editor.open.removeAll { $0 === self }
        guard animated else { window.orderOut(nil); window.close(); return }
        // Pin: fade out while shrinking to 98% (~180 ms).
        let f = window.frame
        Tween.run(window, to: f.insetBy(dx: f.width * 0.01, dy: f.height * 0.01), alpha: 0, duration: 0.18, curve: { $0 }, alphaCurve: { $0 }) { [window] in
            window.orderOut(nil); window.close() // the editor is already released; keep the window itself
        }
    }

    // MARK: add screenshot

    private func addScreenshot() {
        Task { @MainActor [weak self] in
            guard let shot = await Capturer.interactive(.area), let self else { return }
            let size = CGSize(width: CGFloat(shot.image.width) / self.doc.scale, height: CGFloat(shot.image.height) / self.doc.scale)
            let k = min(1, self.doc.imageSize.width * 0.8 / size.width, self.doc.imageSize.height * 0.8 / size.height)
            let s = CGSize(width: size.width * k, height: size.height * k)
            let o = CGPoint(x: (self.doc.imageSize.width - s.width) / 2, y: (self.doc.imageSize.height - s.height) / 2)
            var it = Item(tool: .image, points: [o, CGPoint(x: o.x + s.width, y: o.y + s.height)])
            it.image = shot.image
            let before = self.doc
            self.doc.items.append(it)
            self.commit(before)
            self.setTool(.select)
            self.canvas.selection = self.doc.items.count - 1
            self.window.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: background tool (B)

    func toggleBackground() {
        if crop != nil { return }
        if let s = sidebar {
            s.removeFromSuperview(); sidebar = nil
            backgroundButton.fill = .clear
        } else {
            let s = BackgroundPanel(editor: self)
            root.addSubview(s)
            sidebar = s
            backgroundButton.fill = Palette.accent
        }
        root.needsLayout = true
        root.layoutSubtreeIfNeeded()
        fit()
    }

    func setBackground(_ bg: Background?, coalesce: Bool = false) {
        let before = doc
        doc.background = bg
        if !coalesce { commit(before) } else if sliderBefore == nil { sliderBefore = before }
        if coalesce, NSApp.currentEvent?.type == .leftMouseUp, let b = sliderBefore { commit(b); sliderBefore = nil }
        fit()
    }

    // MARK: crop mode (K)

    /// Crop controls, shown in the inspector while cropping: ratio, W × H (with swap), rotate, flip, image size, snapping,
    /// revert, Cancel and Crop.
    private func buildCropBar() {
        var x: CGFloat = 0
        func add(_ v: NSView, gap: CGFloat = 6) { v.frame.origin = CGPoint(x: x, y: (26 - v.frame.height) / 2); cropTools.addSubview(v); x += v.frame.width + gap }
        ratioPopup = NSPopUpButton(frame: CGRect(x: 0, y: 0, width: 128, height: 26), pullsDown: false)
        ratioPopup.addItems(withTitles: ["Freeform", "Original ratio", "1 : 1", "5 : 4", "7 : 5", "4 : 3", "3 : 2", "16 : 9"])
        ratioPopup.controlSize = .regular
        ratioPopup.target = self
        ratioPopup.action = #selector(ratioChanged)
        add(ratioPopup)
        for (k, f) in [cropW, cropH].enumerated() {
            f.frame = CGRect(x: 0, y: 0, width: 54, height: 22)
            f.alignment = .center
            f.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            f.target = self
            f.action = #selector(cropFieldChanged)
            add(f, gap: 2)
            if k == 0 { add(EButton(frame: CGRect(x: 0, y: 0, width: 22, height: 22), symbol: "swap", fill: .clear, tip: "Swap width and height") { [weak self] in self?.swapRatio() }, gap: 2) }
        }
        x += 6
        add(EButton(frame: CGRect(x: 0, y: 0, width: 30, height: 26), symbol: "rotate", fill: .clear, tip: "Rotate left") { [weak self] in self?.transformImage(rotate: true) }, gap: 2)
        add(EButton(frame: CGRect(x: 0, y: 0, width: 30, height: 26), symbol: "flip", fill: .clear, tip: "Flip horizontally") { [weak self] in self?.transformImage(rotate: false) })
        cropSizeButton = EButton(frame: CGRect(x: 0, y: 0, width: 120, height: 26), title: "", fill: .clear, tip: "Resize image") { }
        cropSizeButton.handlerWithSelf = { [weak self] b in self?.showResize(b) }
        add(cropSizeButton)
        let snap = NSButton(checkboxWithTitle: "Snap", target: self, action: #selector(toggleSnap(_:)))
        snap.state = .on
        snap.toolTip = "Snap to the image edges. Hold ⌘ while dragging to turn it off."
        snap.sizeToFit()
        add(snap, gap: 10)
        revertButton = EButton(frame: CGRect(x: 0, y: 0, width: 62, height: 26), title: "Revert", fill: .clear, tip: "Back to the full image") { [weak self] in
            guard let self, self.crop != nil else { return }
            self.crop!.rect = CGRect(origin: .zero, size: self.doc.imageSize)
            self.cropChanged()
        }
        add(revertButton)
        add(EButton(frame: CGRect(x: 0, y: 0, width: 64, height: 26), title: "Cancel", fill: Palette.button, tip: "Cancel (Esc)") { [weak self] in self?.cancelCrop() })
        add(EButton(frame: CGRect(x: 0, y: 0, width: 56, height: 26), title: "Crop", fill: Palette.accent, tip: "Crop (Return)") { [weak self] in self?.applyCrop() }, gap: 0)
        cropTools.frame.size = CGSize(width: x, height: 26)
    }

    func enterCrop() {
        guard crop == nil else { return }
        canvas.endTextEditing()
        canvas.selection = nil
        sidebar.map { _ in toggleBackground() }
        crop = Crop(rect: CGRect(origin: .zero, size: doc.imageSize), ratio: nil, start: doc)
        ratioPopup.selectItem(at: 0)
        setCropChrome(true)
        docChanged()
        fit()
    }

    private func setCropChrome(_ on: Bool) {
        options.isHidden = on; cropTools.isHidden = !on
        rail.isHidden = on
        scroll.backgroundColor = on ? Palette.cropCanvas : Palette.canvas
        layoutInspector()
    }

    func cropChanged() {
        guard let c = crop else { return }
        let px = { (v: CGFloat) in Int((v * self.doc.scale).rounded()) }
        cropW.stringValue = "\(px(c.rect.width))"
        cropH.stringValue = "\(px(c.rect.height))"
        cropSizeButton.setTitle("\(px(c.rect.width)) × \(px(c.rect.height)) px")
        revertButton.isHidden = c.rect == CGRect(origin: .zero, size: doc.imageSize)
        canvas.needsDisplay = true
    }

    @objc private func ratioChanged() {
        guard crop != nil else { return }
        let ratios: [CGFloat?] = [nil, doc.imageSize.width / doc.imageSize.height, 1, 5.0 / 4, 7.0 / 5, 4.0 / 3, 3.0 / 2, 16.0 / 9]
        crop!.ratio = ratios[ratioPopup.indexOfSelectedItem]
        if let r = crop!.ratio { fitCrop(ratio: r) }
        cropChanged()
    }

    /// Largest rect of `ratio` centred on the current crop, inside the image.
    private func fitCrop(ratio r: CGFloat) {
        guard let c = crop?.rect else { return }
        let b = CGRect(origin: .zero, size: doc.imageSize)
        var w = c.width, h = w / r
        if h > b.height { h = b.height; w = h * r }
        if w > b.width { w = b.width; h = w / r }
        var rect = CGRect(x: c.midX - w / 2, y: c.midY - h / 2, width: w, height: h)
        rect.origin.x = min(max(0, rect.minX), b.width - w)
        rect.origin.y = min(max(0, rect.minY), b.height - h)
        crop!.rect = rect.integral.intersection(b)
    }

    private func swapRatio() {
        guard let r = crop?.ratio else { return }
        crop!.ratio = 1 / r
        fitCrop(ratio: 1 / r)
        cropChanged()
    }

    @objc private func cropFieldChanged() {
        guard let c = crop else { return }
        let w = CGFloat(cropW.integerValue) / doc.scale, h = CGFloat(cropH.integerValue) / doc.scale
        guard w > 0, h > 0 else { return cropChanged() }
        crop!.rect = CGRect(x: c.rect.minX, y: c.rect.minY, width: w, height: h).intersection(CGRect(origin: .zero, size: doc.imageSize))
        cropChanged()
    }

    func applyCrop() {
        guard let c = crop else { return }
        let full = CGRect(origin: .zero, size: doc.imageSize)
        if c.rect != full, c.rect.width >= 1, c.rect.height >= 1 {
            let px = CGRect(x: c.rect.minX * doc.scale, y: c.rect.minY * doc.scale, width: c.rect.width * doc.scale, height: c.rect.height * doc.scale).integral
            if let img = doc.image.cropping(to: px) {
                doc.image = img
                doc.items = doc.items.map { $0.moved(by: CGPoint(x: -c.rect.minX, y: -c.rect.minY)) }
            }
        }
        crop = nil
        setCropChrome(false)
        if doc.image !== c.start.image { commit(c.start) }
        docChanged()
        fit()
    }

    func cancelCrop() {
        guard let c = crop else { return }
        crop = nil
        setCropChrome(false)
        doc = c.start
        fit()
    }

    /// Rotate 90° left or flip horizontally: image and objects together.
    private func transformImage(rotate: Bool) {
        guard crop != nil, let img = Output.transformed(doc.image, rotateLeft: rotate) else { return }
        let w = doc.imageSize.width
        let map: (CGPoint) -> CGPoint = rotate ? { CGPoint(x: $0.y, y: w - $0.x) } : { CGPoint(x: w - $0.x, y: $0.y) }
        doc.image = img
        doc.items = doc.items.map { var it = $0; it.points = it.points.map(map); return it }
        crop!.rect = CGRect(origin: .zero, size: doc.imageSize)
        docChanged()
        fit()
    }

    private func showResize(_ b: NSView) {
        let pop = NSPopover()
        pop.behavior = .transient
        pop.appearance = NSAppearance(named: .darkAqua)
        let vc = NSViewController()
        vc.view = ResizeView(width: doc.image.width, height: doc.image.height) { [weak self, weak pop] w, h in
            pop?.close()
            if let w, let h { self?.resize(toPixels: CGSize(width: w, height: h)) }
        }
        pop.contentViewController = vc
        pop.contentSize = vc.view.frame.size
        pop.show(relativeTo: b.bounds, of: b, preferredEdge: .maxY)
    }

    private func resize(toPixels size: CGSize) {
        guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.interpolationQuality = .high
        ctx.draw(doc.image, in: CGRect(origin: .zero, size: size))
        guard let img = ctx.makeImage() else { return }
        let k = size.width / CGFloat(doc.image.width)
        doc.image = img
        doc.items = doc.items.map { var it = $0; it.points = it.points.map { CGPoint(x: $0.x * k, y: $0.y * k) }; it.width *= k; it.fontSize *= k; it.textWidth = it.textWidth.map { $0 * k }; return it }
        crop?.rect = CGRect(origin: .zero, size: doc.imageSize)
        docChanged()
        fit()
    }
}

// MARK: - Window and containers

final class EditorWindow: NSWindow {
    weak var editor: Editor?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if editor?.command(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

final class EditorRoot: NSView {
    weak var editor: Editor?
    override func layout() { super.layout(); editor?.layoutRoot(bounds) }
}

final class Bar: NSView {
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true; layer!.backgroundColor = Palette.chrome.cgColor }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }
}

/// Keeps the canvas centred when it is smaller than the viewport.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposed: NSRect) -> NSRect {
        var r = super.constrainBoundsRect(proposed)
        guard let doc = documentView?.frame else { return r }
        if r.width > doc.width { r.origin.x = (doc.width - r.width) / 2 }
        if r.height > doc.height { r.origin.y = (doc.height - r.height) / 2 }
        return r
    }
}

/// ⌘-scroll zooms smoothly around the cursor; plain scroll pans.
final class EditorScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.command) else { return super.scrollWheel(with: event) }
        let p = documentView!.convert(event.locationInWindow, from: nil)
        let k = pow(1.01, event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 8))
        setMagnification(min(32, max(0.1, magnification * k)), centeredAt: p)
    }
}
