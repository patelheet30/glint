import AppKit
import CoreImage

/// The background tool's panel: None, gradients, wallpaper, blurred, plain colors,
/// then padding / inset / shadow / corners sliders, a 3×3 alignment grid and a ratio popup.
final class BackgroundPanel: NSView, NSTextFieldDelegate {
    private weak var editor: Editor?
    var wantsPanelColor = false
    private let content = FlippedView()
    private var tiles: [BGTile] = []
    private var sliders: [(NSSlider, WritableKeyPath<Background, CGFloat>)] = []
    private var alignButtons: [EButton] = []
    private let ratio = NSPopUpButton()
    private var frameButtons: [(DeviceFrame.Style?, EButton)] = []
    private let frameLook = NSSegmentedControl(labels: ["Auto", "Light", "Dark"], trackingMode: .selectOne, target: nil, action: nil)
    private let frameText = NSTextField()
    private let cardSize = NSPopUpButton()
    private let cardTitle = NSTextField(), cardSubtitle = NSTextField()
    private let cardPosition = NSSegmentedControl(labels: ["Above", "Below", "Beside"], trackingMode: .selectOne, target: nil, action: nil)
    private let cardStyle = NSSegmentedControl(labels: ShareCard.TextStyle.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    private static let ratios: [(String, CGFloat?)] = [("Auto", nil), ("1 : 1", 1), ("4 : 3", 4.0 / 3), ("3 : 2", 3.0 / 2), ("16 : 10", 1.6), ("16 : 9", 16.0 / 9), ("9 : 16", 9.0 / 16)]

    init(editor: Editor) {
        self.editor = editor
        super.init(frame: CGRect(x: 0, y: 0, width: 250, height: 600))
        wantsLayer = true
        layer!.backgroundColor = Palette.capsule.cgColor // floats over the canvas like the rail and inspector
        layer!.cornerRadius = 12
        layer!.cornerCurve = .continuous
        layer!.borderWidth = 0.5
        layer!.borderColor = Palette.panelBorder.cgColor
        layer!.masksToBounds = true
        let scroll = NSScrollView(frame: bounds)
        scroll.autoresizingMask = [.width, .height]
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = content
        addSubview(scroll)
        build(editor.doc.image)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    private var current: Background { editor?.doc.background ?? Background(fill: .gradient(0)) }

    private func set(_ change: (inout Background) -> Void, coalesce: Bool = false) {
        guard let editor else { return }
        var bg = current
        change(&bg)
        editor.setBackground(bg, coalesce: coalesce)
        refresh()
    }

    private func pick(_ fill: Background.Fill) {
        // A new background starts from Glint's defaults (see `Background`).
        if editor?.doc.background == nil { editor?.setBackground(Background(fill: fill)); refresh() }
        else { set { $0.fill = fill } }
    }

    func apply(color: NSColor) { pick(.color(color)) }

    private func build(_ image: CGImage) {
        var y: CGFloat = 14
        let none = EButton(frame: CGRect(x: 12, y: y, width: 226, height: 36), title: "None", fill: Palette.button, tip: "No background") { [weak self] in
            self?.editor?.setBackground(nil); self?.refresh()
        }
        none.layer!.cornerRadius = 9
        content.addSubview(none)
        noneButton = none
        y += 52

        // Frame: none, or a window / device drawn around the screenshot.
        y = section("Frame", y)
        for (i, style) in ([nil] + DeviceFrame.Style.allCases.map { Optional($0) }).enumerated() {
            let b = EButton(frame: CGRect(x: 12 + CGFloat(i) * 38, y: y, width: 34, height: 30),
                            symbol: style?.symbol ?? "square.dashed", fill: .clear, tip: style?.title ?? "No frame") { [weak self] in
                self?.pickFrame(style)
            }
            b.layer!.cornerRadius = 7
            frameButtons.append((style, b))
            content.addSubview(b)
        }
        y += 38
        frameLook.frame = CGRect(x: 12, y: y, width: 226, height: 24)
        frameLook.controlSize = .small
        frameLook.target = self
        frameLook.action = #selector(frameLookChanged)
        content.addSubview(frameLook)
        y += 32
        frameText.frame = CGRect(x: 12, y: y, width: 226, height: 24)
        frameText.controlSize = .small
        frameText.font = .systemFont(ofSize: 12)
        frameText.delegate = self
        content.addSubview(frameText)
        y += 40

        // Card: title + subtitle laid out with the screenshot at an exact social / README size.
        y = section("Card", y)
        cardSize.frame = CGRect(x: 10, y: y - 2, width: 230, height: 26)
        cardSize.addItem(withTitle: "Off")
        ShareCard.Preset.allCases.forEach { cardSize.addItem(withTitle: $0.label) }
        cardSize.target = self
        cardSize.action = #selector(cardSizeChanged)
        content.addSubview(cardSize)
        y += 32
        for (field, placeholder) in [(cardTitle, "Title"), (cardSubtitle, "Subtitle or @handle")] {
            field.frame = CGRect(x: 12, y: y, width: 226, height: 24)
            field.controlSize = .small
            field.font = .systemFont(ofSize: 12)
            field.placeholderString = placeholder
            field.delegate = self
            content.addSubview(field)
            y += 30
        }
        for seg in [cardPosition, cardStyle] {
            seg.frame = CGRect(x: 12, y: y, width: 226, height: 24)
            seg.controlSize = .small
            seg.target = self
            seg.action = #selector(cardOptionChanged)
            content.addSubview(seg)
            y += 30
        }
        y += 10

        y = section("Gradients", y)
        for i in 0..<Render.gradients.count {
            addTile(.gradient(i), x: 12 + CGFloat(i % 5) * 46, y: y + CGFloat(i / 5) * 46)
        }
        y += 4 * 46 + 10

        y = section("Wallpapers", y)
        if let url = NSScreen.main.flatMap({ NSWorkspace.shared.desktopImageURL(for: $0) }),
           let img = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            addTile(.image(img), x: 12, y: y)
        }
        let plus = BGTile(frame: CGRect(x: 58, y: y, width: 43, height: 43), fill: nil)
        plus.onClick = { [weak self] in self?.chooseWallpaper() }
        content.addSubview(plus)
        y += 56

        y = section("Blurred", y)
        for (i, ev) in [0.0, -1.2, -2.4].enumerated() {
            if let img = Self.blurred(image, ev: ev) { addTile(.image(img), x: 12 + CGFloat(i) * 46, y: y) }
        }
        y += 56

        y = section("Plain color", y)
        let colors: [NSColor?] = [0x1C1C1E, 0xFFFFFF, 0xE5343F, 0xF5872E, 0xF4B523, 0x1E9C5A, 0x1A8CF0, 0x8E44EC].map { Palette.hex($0) } + [.clear]
            + [0x2C2C2E, 0xE8E8EA, 0xF7C3C0, 0xFAD3A6, 0xFCE2A6, 0xBCE6C9, 0xBEDCF7, 0xDAC8F6].map { Palette.hex($0) } + [nil]
        for (i, c) in colors.enumerated() {
            let t = BGTile(frame: CGRect(x: 12 + CGFloat(i % 9) * 25.5, y: y + CGFloat(i / 9) * 30, width: 24, height: 24), fill: c.map { .color($0) }, round: true)
            t.onClick = { [weak self] in
                if let c { self?.pick(.color(c)) } else { self?.wantsPanelColor = true; self?.editor?.openBackgroundColorPanel() }
            }
            if c != nil { tiles.append(t) }
            content.addSubview(t)
        }
        y += 70

        let line = NSBox(frame: CGRect(x: 12, y: y, width: 226, height: 1)); line.boxType = .separator
        content.addSubview(line)
        y += 16

        y = section("Padding", y)
        addSlider(\.padding, 0...400, CGRect(x: 12, y: y, width: 226, height: 20)); y += 34
        y = section("Inset", y)
        addSlider(\.inset, 0...100, CGRect(x: 12, y: y, width: 226, height: 20)); y += 34
        _ = section("Shadow", y); _ = section("Corners", y, x: 132)
        y += 22
        addSlider(\.shadow, 0...100, CGRect(x: 12, y: y, width: 106, height: 20))
        addSlider(\.corners, 0...60, CGRect(x: 132, y: y, width: 106, height: 20))
        y += 34
        _ = section("Alignment", y); _ = section("Ratio", y, x: 132)
        y += 22
        for i in 0..<9 {
            let b = EButton(frame: CGRect(x: 12 + CGFloat(i % 3) * 32, y: y + CGFloat(i / 3) * 28, width: 26, height: 22), fill: .clear, tip: "Alignment") { [weak self] in
                self?.set { $0.align = i }
            }
            b.image = Self.alignIcon(i)
            b.layer!.cornerRadius = 5
            alignButtons.append(b)
            content.addSubview(b)
        }
        ratio.frame = CGRect(x: 130, y: y - 2, width: 110, height: 26)
        ratio.addItems(withTitles: Self.ratios.map(\.0))
        ratio.target = self
        ratio.action = #selector(ratioChanged)
        content.addSubview(ratio)
        y += 3 * 28 + 16
        content.frame = CGRect(x: 0, y: 0, width: 250, height: y)
    }

    private var noneButton: EButton!

    private func section(_ title: String, _ y: CGFloat, x: CGFloat = 12) -> CGFloat {
        let l = NSTextField(labelWithString: title)
        l.font = .systemFont(ofSize: 12, weight: .medium)
        l.textColor = NSColor(white: 1, alpha: 0.75)
        l.frame = CGRect(x: x, y: y, width: 200, height: 16)
        content.addSubview(l)
        return y + 24
    }

    private func addTile(_ fill: Background.Fill, x: CGFloat, y: CGFloat) {
        let t = BGTile(frame: CGRect(x: x, y: y, width: 43, height: 43), fill: fill)
        t.onClick = { [weak self] in self?.pick(fill) }
        tiles.append(t)
        content.addSubview(t)
    }

    private func addSlider(_ key: WritableKeyPath<Background, CGFloat>, _ range: ClosedRange<Double>, _ frame: CGRect) {
        let s = ActionSlider(value: 0, minValue: range.lowerBound, maxValue: range.upperBound, target: nil, action: nil)
        s.frame = frame
        s.controlSize = .small
        s.handler = { [weak self] v in
            guard self?.editor?.doc.background != nil else { return }
            self?.set({ $0[keyPath: key] = CGFloat(v).rounded() }, coalesce: true)
        }
        sliders.append((s, key))
        content.addSubview(s)
    }

    private func pickFrame(_ style: DeviceFrame.Style?) {
        guard let editor else { return }
        if editor.doc.background == nil {
            guard let style else { return }
            var bg = Background(fill: .gradient(0)); bg.frame = DeviceFrame(style: style)
            editor.setBackground(bg); refresh()
        } else {
            set { bg in
                guard let style else { bg.frame = nil; return }
                var f = bg.frame ?? DeviceFrame(style: style)
                f.style = style
                bg.frame = f
            }
        }
    }

    @objc private func frameLookChanged() {
        set { $0.frame?.appearance = DeviceFrame.Appearance(rawValue: self.frameLook.selectedSegment) ?? .auto }
    }

    func controlTextDidChange(_ obj: Notification) { applyText(obj, coalesce: true) }
    func controlTextDidEndEditing(_ obj: Notification) { applyText(obj, coalesce: false) } // one undo step per edit

    private func applyText(_ obj: Notification, coalesce: Bool) {
        let field = obj.object as? NSTextField
        set({ bg in
            if field === self.frameText { bg.frame?.text = self.frameText.stringValue }
            if field === self.cardTitle { bg.card?.title = self.cardTitle.stringValue }
            if field === self.cardSubtitle { bg.card?.subtitle = self.cardSubtitle.stringValue }
        }, coalesce: coalesce)
    }

    @objc private func cardSizeChanged() {
        guard let editor else { return }
        let i = cardSize.indexOfSelectedItem
        guard i > 0, let preset = ShareCard.Preset(rawValue: i - 1) else { return set { $0.card = nil } }
        if editor.doc.background == nil {
            var bg = Background(fill: .gradient(0)); bg.card = ShareCard(preset: preset)
            editor.setBackground(bg); refresh()
        } else {
            set { bg in var c = bg.card ?? ShareCard(); c.preset = preset; bg.card = c }
        }
    }

    @objc private func cardOptionChanged() {
        set { bg in
            bg.card?.position = ShareCard.Position(rawValue: self.cardPosition.selectedSegment) ?? .above
            bg.card?.style = ShareCard.TextStyle(rawValue: self.cardStyle.selectedSegment) ?? .bold
        }
    }

    @objc private func ratioChanged() { set { $0.ratio = Self.ratios[self.ratio.indexOfSelectedItem].1 } }

    /// Reflects the document's background in the controls.
    func refresh() {
        let bg = editor?.doc.background
        noneButton.layer!.borderWidth = bg == nil ? 2 : 0
        noneButton.layer!.borderColor = Palette.handle.cgColor
        for t in tiles { t.selected = bg != nil && t.fill == bg!.fill }
        for (s, key) in sliders { s.doubleValue = Double(current[keyPath: key]); s.isEnabled = bg != nil }
        for (i, b) in alignButtons.enumerated() { b.fill = i == current.align && bg != nil ? NSColor(white: 1, alpha: 0.18) : .clear }
        ratio.selectItem(at: Self.ratios.firstIndex { $0.1 == current.ratio } ?? 0)
        ratio.isEnabled = bg != nil
        let frame = bg?.frame
        for (style, b) in frameButtons {
            b.fill = style == frame?.style ? NSColor(white: 1, alpha: 0.18) : .clear
        }
        frameLook.selectedSegment = frame?.appearance.rawValue ?? 0
        frameLook.isEnabled = frame != nil
        frameText.isEnabled = frame?.style.hasText == true
        frameText.placeholderString = frame?.style == .browser ? "Address (example.com)" : "Window title"
        if frameText.currentEditor() == nil { frameText.stringValue = frame?.text ?? "" }
        let card = bg?.card
        cardSize.selectItem(at: card.map { $0.preset.rawValue + 1 } ?? 0)
        for c in [cardTitle, cardSubtitle] as [NSControl] { c.isEnabled = card != nil }
        for c in [cardPosition, cardStyle] { c.isEnabled = card != nil }
        if cardTitle.currentEditor() == nil { cardTitle.stringValue = card?.title ?? "" }
        if cardSubtitle.currentEditor() == nil { cardSubtitle.stringValue = card?.subtitle ?? "" }
        cardPosition.selectedSegment = card?.position.rawValue ?? 0
        cardStyle.selectedSegment = card?.style.rawValue ?? 0
    }

    private func chooseWallpaper() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.image]
        guard p.runModal() == .OK, let url = p.url, let img = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        pick(.image(img))
    }

    private static func blurred(_ image: CGImage, ev: Double) -> CGImage? {
        let src = CIImage(cgImage: image)
        let k = 480 / max(src.extent.width, 1)
        let small = src.transformed(by: CGAffineTransform(scaleX: k, y: k))
        let out = small.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 24])
            .applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: ev])
            .cropped(to: small.extent)
        return CIContext().createCGImage(out, from: small.extent)
    }

    private static func alignIcon(_ i: Int) -> NSImage {
        NSImage(size: NSSize(width: 18, height: 14), flipped: true) { r in
            NSColor(white: 1, alpha: 0.5).setStroke()
            let frame = NSBezierPath(roundedRect: r.insetBy(dx: 1, dy: 1), xRadius: 3, yRadius: 3); frame.lineWidth = 1.2; frame.stroke()
            let w: CGFloat = 8, h: CGFloat = 6
            let x = 2 + CGFloat(i % 3) * (r.width - 4 - w) / 2, y = 2 + CGFloat(i / 3) * (r.height - 4 - h) / 2
            Palette.icon.setFill()
            NSBezierPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), xRadius: 1.5, yRadius: 1.5).fill()
            return true
        }
    }
}

final class FlippedView: NSView { override var isFlipped: Bool { true } }

/// One background swatch: gradient / image / color (nil = "+" or the custom color wheel).
final class BGTile: NSView {
    let fill: Background.Fill?
    let round: Bool
    var onClick: (() -> Void)?
    var selected = false { didSet { needsDisplay = true } }

    init(frame: CGRect, fill: Background.Fill?, round: Bool = false) {
        self.fill = fill
        self.round = round
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let r = bounds.insetBy(dx: 2, dy: 2)
        let path = round ? CGPath(ellipseIn: r, transform: nil) : CGPath(roundedRect: r, cornerWidth: 10, cornerHeight: 10, transform: nil)
        ctx.saveGState()
        ctx.addPath(path); ctx.clip()
        switch fill {
        case .gradient(let i): Render.fillGradient(i, in: r, ctx: ctx)
        case .color(let c):
            if c.alphaComponent == 0 { // transparent: checkerboard
                ctx.setFillColor(.white); ctx.fill(r)
                ctx.setFillColor(CGColor(gray: 0.75, alpha: 1))
                let s = r.width / 4
                for i in 0..<4 { for j in 0..<4 where (i + j) % 2 == 0 { ctx.fill(CGRect(x: r.minX + CGFloat(i) * s, y: r.minY + CGFloat(j) * s, width: s, height: s)) } }
            } else { ctx.setFillColor(c.cgColor); ctx.fill(r) }
        case .image(let img):
            let k = max(r.width / CGFloat(img.width), r.height / CGFloat(img.height))
            let sz = CGSize(width: CGFloat(img.width) * k, height: CGFloat(img.height) * k)
            Render.drawImage(img, in: CGRect(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2, width: sz.width, height: sz.height), ctx: ctx)
        case nil:
            if round { // custom color wheel
                let colors = [NSColor.systemRed, .systemYellow, .systemGreen, .systemCyan, .systemBlue, .systemPurple, .systemRed].map(\.cgColor) as CFArray
                if let g = CGGradient(colorsSpace: nil, colors: colors, locations: nil) {
                    ctx.drawLinearGradient(g, start: CGPoint(x: r.minX, y: r.minY), end: CGPoint(x: r.maxX, y: r.maxY), options: [])
                }
            }
        }
        ctx.restoreGState()
        if fill == nil && !round { // dashed "+"
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.45)); ctx.setLineWidth(1.2); ctx.setLineDash(phase: 0, lengths: [3, 3])
            ctx.addPath(path); ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
            ctx.setLineWidth(1.8); ctx.setStrokeColor(.white)
            ctx.move(to: CGPoint(x: r.midX - 5, y: r.midY)); ctx.addLine(to: CGPoint(x: r.midX + 5, y: r.midY))
            ctx.move(to: CGPoint(x: r.midX, y: r.midY - 5)); ctx.addLine(to: CGPoint(x: r.midX, y: r.midY + 5))
            ctx.strokePath()
        }
        if selected {
            let ring = round ? CGPath(ellipseIn: bounds.insetBy(dx: 0.75, dy: 0.75), transform: nil)
                : CGPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75), cornerWidth: 11, cornerHeight: 11, transform: nil)
            ctx.addPath(ring); ctx.setStrokeColor(Palette.handle.cgColor); ctx.setLineWidth(1.5); ctx.strokePath()
        }
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
}
