import AppKit

/// The editor's document view (inside a magnifying NSScrollView). Draws the doc, the selection and the crop frame,
/// and turns mouse drags into items. View coordinates = canvas points, top-left origin.
final class CanvasView: NSView, NSTextViewDelegate {
    weak var editor: Editor!
    var selection: Int? { didSet { if selection != oldValue { needsDisplay = true; editor.selectionChanged() } } }

    private enum Drag { case create(Int), move(Int, Item, CGPoint), handle(Int, Int, Item), cropMove(CGRect, CGPoint), cropHandle(Int, CGRect) }
    private var drag: Drag?
    private var before: Doc?

    private var textView: NSTextView?
    private var editingIndex: Int?
    private var emojiButton: NSButton?


    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var doc: Doc { editor.doc }
    private var mag: CGFloat { enclosingScrollView?.magnification ?? 1 }
    /// Image-space offset on the canvas (the background tool pads around the image; crop mode shows the bare image).
    var origin: CGPoint { editor.crop != nil ? .zero : doc.layout.origin }

    func imagePoint(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: p.x - origin.x, y: p.y - origin.y)
    }

    // MARK: drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if editor.crop != nil {
            var bare = doc; bare.background = nil
            Render.draw(bare, in: ctx)
            drawCrop(ctx)
            return
        }
        Render.draw(doc, in: ctx, halo: editingIndex == nil ? selection : nil, hidden: editingIndex)
        ctx.translateBy(x: origin.x, y: origin.y)
        if let i = selection, doc.items.indices.contains(i) {
            let it = doc.items[i]
            if it.tool == .text { drawTextFrame(Render.textFrame(it), dashed: editingIndex == nil, ctx) }
            if it.tool == .image { ctx.setStrokeColor(Palette.handle.cgColor); ctx.setLineWidth(1.5 / mag); ctx.stroke(it.box) }
            for (k, h) in handles(it).enumerated() {
                drawHandle(h, square: it.tool == .text && k == 2, color: it.tool == .arrow && k == 2 ? it.color : Palette.handle, ctx)
            }
        }
    }

    private func drawHandle(_ p: CGPoint, square: Bool, color: NSColor, _ ctx: CGContext) {
        let r = (square ? 5 : 7) / mag
        let rect = CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 0.5 / mag), blur: 2 / mag, color: CGColor(gray: 0, alpha: 0.4))
        ctx.setFillColor(.white)
        if square { ctx.fill(rect) } else { ctx.fillEllipse(in: rect) }
        ctx.restoreGState()
        ctx.setFillColor(color.cgColor)
        let inner = rect.insetBy(dx: 1.5 / mag, dy: 1.5 / mag)
        if square { ctx.fill(inner) } else { ctx.fillEllipse(in: inner) }
    }

    private func drawTextFrame(_ r: CGRect, dashed: Bool, _ ctx: CGContext) {
        ctx.saveGState()
        ctx.setStrokeColor(Palette.hex(0x7DB5FF).cgColor)
        ctx.setLineWidth(1.5 / mag)
        if dashed { ctx.setLineDash(phase: 0, lengths: [4 / mag, 3 / mag]) }
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: 4, cornerHeight: 4, transform: nil))
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// Selection handles in image coordinates.
    func handles(_ it: Item) -> [CGPoint] {
        switch it.tool {
        case _ where it.tool.isBox:
            let b = it.box
            return [CGPoint(x: b.minX, y: b.minY), CGPoint(x: b.maxX, y: b.minY), CGPoint(x: b.maxX, y: b.maxY), CGPoint(x: b.minX, y: b.maxY)]
        case .line: return Array(it.points.prefix(2))
        case .arrow: return it.arrow == .curved ? Array(it.points.prefix(3)) : Array(it.points.prefix(2))
        case .text:
            let f = Render.textFrame(it)
            return [CGPoint(x: f.minX, y: f.midY), CGPoint(x: f.maxX, y: f.midY), CGPoint(x: f.maxX, y: f.maxY)]
        default: return []
        }
    }

    // MARK: mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if editingIndex != nil { endTextEditing(); return }
        if editor.crop != nil { return cropMouseDown(event) }
        let p = imagePoint(event)
        before = doc
        let tol = 5 / mag

        // A selected item's handles win over everything.
        if let i = selection, let k = handles(doc.items[i]).firstIndex(where: { hypot($0.x - p.x, $0.y - p.y) < 9 / mag }) {
            drag = .handle(i, k, doc.items[i]); return
        }
        let hitIndex = doc.items.indices.reversed().first { Geometry.hit(doc.items[$0], p, doc: doc, tolerance: tol) }

        switch editor.tool {
        case .select:
            guard var i = hitIndex else { selection = nil; return }
            if event.modifierFlags.contains(.option) { // ⌥-drag duplicates
                editor.doc.items.append(doc.items[i]); i = doc.items.count - 1
            }
            selection = i
            drag = .move(i, doc.items[i], p)
            if event.clickCount == 2, doc.items[i].tool == .text { beginTextEditing(i) }
        case .text:
            if let i = hitIndex, doc.items[i].tool == .text { selection = i; beginTextEditing(i); return }
            if selection != nil { selection = nil; return } // a click after finishing text deselects
            var it = editor.newItem(.text, at: p)
            it.points[0].y -= it.fontSize * 0.75
            editor.doc.items.append(it)
            let i = doc.items.count - 1
            selection = i
            beginTextEditing(i)
        case .counter:
            selection = nil
            editor.doc.items.append(editor.newItem(.counter, at: p))
            editor.commit(before!)
            needsDisplay = true
        default:
            selection = nil
            editor.doc.items.append(editor.newItem(editor.tool, at: p))
            drag = .create(doc.items.count - 1)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        if editor.crop != nil { return cropMouseDragged(event) }
        guard let drag else { return }
        let p = imagePoint(event), shift = event.modifierFlags.contains(.shift)
        switch drag {
        case .create(let i):
            var it = doc.items[i]
            switch it.tool {
            case .pencil, .marker:
                it.points = shift ? [it.points[0], p] : it.points + [p]
            case .line, .arrow:
                it.points[1] = shift ? Geometry.snap45(it.points[0], p) : p
                if it.points.count > 2 { it.points[2] = mid(it.points[0], it.points[1]) }
            default:
                it.points[1] = shift ? Geometry.square(it.points[0], p) : p
            }
            editor.doc.items[i] = it
        case .move(let i, let orig, let start):
            editor.doc.items[i] = orig.moved(by: CGPoint(x: p.x - start.x, y: p.y - start.y))
        case .handle(let i, let k, let orig):
            editor.doc.items[i] = dragHandle(orig, k, to: p, shift: shift)
        default: break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if editor.crop != nil { drag = nil; return }
        defer { drag = nil; before = nil; needsDisplay = true }
        guard let drag, let before else { return }
        if case .create(let i) = drag {
            let it = doc.items[i]
            let size = it.tool.isBox ? min(it.box.width, it.box.height) :
                (it.points.count > 1 ? hypot(it.points.last!.x - it.points[0].x, it.points.last!.y - it.points[0].y) : 0)
            if size < 2 && it.tool != .pencil && it.tool != .marker { editor.doc.items.remove(at: i); return }
            if it.tool.isBox { editor.doc.items[i].points = [it.box.origin, CGPoint(x: it.box.maxX, y: it.box.maxY)] }
        }
        if case .handle(let i, _, _) = drag, doc.items[i].tool.isBox {
            let b = doc.items[i].box
            editor.doc.items[i].points = [b.origin, CGPoint(x: b.maxX, y: b.maxY)]
        }
        editor.commit(before)
    }

    private func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }

    private func dragHandle(_ orig: Item, _ k: Int, to p: CGPoint, shift: Bool) -> Item {
        var it = orig
        switch it.tool {
        case _ where it.tool.isBox:
            let hs = handles(orig), opposite = hs[(k + 2) % 4]
            var q = shift ? Geometry.square(opposite, p) : p
            if it.tool == .image, !shift { // images keep their aspect ratio unless ⇧
                let r = orig.box.width / max(1, orig.box.height)
                let w = abs(q.x - opposite.x)
                q.y = opposite.y + (q.y < opposite.y ? -1 : 1) * w / r
            }
            it.points = [opposite, q]
        case .line, .arrow:
            if k == 2 { it.points[2] = p; break }
            let other = it.points[1 - k]
            it.points[k] = shift ? Geometry.snap45(other, p) : p
            if it.points.count > 2, orig.points.count > 2, orig.points[2] == mid(orig.points[0], orig.points[1]) {
                it.points[2] = mid(it.points[0], it.points[1]) // a straight curved-arrow stays straight
            }
        case .text:
            let f = Render.textFrame(orig)
            switch k {
            case 0: it.points[0].x = min(p.x, f.maxX - 20); it.textWidth = f.maxX - it.points[0].x
            case 1: it.textWidth = max(20, p.x - f.minX)
            default: it.fontSize = min(300, max(8, orig.fontSize * max(0.1, (p.y - f.minY) / f.height)))
            }
        default: break
        }
        return it
    }

    // MARK: text editing (a live NSTextView over the item)

    func beginTextEditing(_ i: Int) {
        endTextEditing()
        before = before ?? doc
        editingIndex = i
        let it = doc.items[i]
        let tv = NSTextView(frame: textViewFrame(it))
        tv.delegate = self
        tv.drawsBackground = false
        tv.isRichText = false
        tv.allowsUndo = true
        tv.textContainerInset = Render.textPad
        tv.textContainer?.lineFragmentPadding = 0
        tv.insertionPointColor = Palette.handle
        tv.typingAttributes = Render.attributes(it)
        tv.string = it.text
        tv.textStorage?.setAttributes(Render.attributes(it), range: NSRange(location: 0, length: (it.text as NSString).length))
        addSubview(tv)
        textView = tv
        window?.makeFirstResponder(tv)
        tv.selectAll(nil)

        let b = NSButton(frame: .zero)
        b.isBordered = false
        b.wantsLayer = true
        b.layer!.backgroundColor = Palette.handle.cgColor
        b.layer!.cornerRadius = 11
        b.image = NSImage(systemSymbolName: "face.smiling", accessibilityDescription: "Emoji")?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        b.contentTintColor = .white
        b.target = self
        b.action = #selector(showEmoji)
        addSubview(b)
        emojiButton = b
        layoutTextEditor()
        needsDisplay = true
    }

    private func textViewFrame(_ it: Item) -> CGRect {
        Render.textFrame(it).offsetBy(dx: origin.x, dy: origin.y)
    }

    private func layoutTextEditor() {
        guard let i = editingIndex, let tv = textView else { return }
        let f = textViewFrame(doc.items[i])
        tv.frame = f
        tv.textContainer?.containerSize = CGSize(width: f.width - 2 * Render.textPad.width, height: 100_000)
        let s = 22 / mag
        emojiButton?.frame = CGRect(x: f.midX - s / 2, y: f.minY - s - 8 / mag, width: s, height: s)
        emojiButton?.layer?.cornerRadius = s / 2
    }

    @objc private func showEmoji() {
        guard let tv = textView else { return }
        window?.makeFirstResponder(tv)
        NSApp.orderFrontCharacterPalette(nil)
    }

    func textDidChange(_ notification: Notification) {
        guard let i = editingIndex, let tv = textView else { return }
        editor.doc.items[i].text = tv.string
        layoutTextEditor()
        needsDisplay = true
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(cancelOperation(_:)) { endTextEditing(); return true } // Esc: stop editing, stay selected
        return false
    }

    var isEditingText: Bool { editingIndex != nil }

    func endTextEditing() {
        guard let i = editingIndex else { return }
        textView?.removeFromSuperview(); textView = nil
        emojiButton?.removeFromSuperview(); emojiButton = nil
        editingIndex = nil
        if doc.items[i].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            editor.doc.items.remove(at: i)
            selection = nil
        }
        if let before { editor.commit(before) }
        before = nil
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    /// Restyles the text view after the toolbar changed the edited item.
    func refreshTextEditor() {
        guard let i = editingIndex, let tv = textView else { return }
        let attrs = Render.attributes(doc.items[i])
        tv.typingAttributes = attrs
        tv.textStorage?.setAttributes(attrs, range: NSRange(location: 0, length: (tv.string as NSString).length))
        layoutTextEditor()
    }

    // MARK: keys

    override func keyDown(with event: NSEvent) {
        if !editor.handleKey(event) { super.keyDown(with: event) }
    }

    // MARK: crop mode

    private func cropHandles(_ r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.midY),
         CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.midX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX, y: r.midY)]
    }

    private func cropMouseDown(_ event: NSEvent) {
        guard let crop = editor.crop else { return }
        let p = imagePoint(event)
        if let k = cropHandles(crop.rect).firstIndex(where: { hypot($0.x - p.x, $0.y - p.y) < 12 / mag }) {
            drag = .cropHandle(k, crop.rect)
        } else if crop.rect.contains(p) {
            drag = .cropMove(crop.rect, p)
        } else { // drag out a new rect from here
            editor.crop?.rect = CGRect(origin: p, size: .zero)
            drag = .cropHandle(4, CGRect(origin: p, size: .zero))
        }
    }

    private func cropMouseDragged(_ event: NSEvent) {
        guard let drag, let crop = editor.crop else { return }
        let bounds = CGRect(origin: .zero, size: doc.imageSize)
        var p = imagePoint(event)
        let snap = crop.snap && !event.modifierFlags.contains(.command)
        if snap {
            let d = 10 / mag
            for x in [bounds.minX, bounds.maxX] where abs(p.x - x) < d { p.x = x }
            for y in [bounds.minY, bounds.maxY] where abs(p.y - y) < d { p.y = y }
        }
        p.x = min(max(p.x, 0), bounds.width); p.y = min(max(p.y, 0), bounds.height)
        var r: CGRect
        switch drag {
        case .cropMove(let orig, let start):
            r = orig.offsetBy(dx: p.x - start.x, dy: p.y - start.y)
            r.origin.x = min(max(r.minX, 0), bounds.width - r.width)
            r.origin.y = min(max(r.minY, 0), bounds.height - r.height)
        case .cropHandle(let k, let orig):
            var (x0, y0, x1, y1) = (orig.minX, orig.minY, orig.maxX, orig.maxY)
            if [0, 6, 7].contains(k) { x0 = p.x }
            if [2, 3, 4].contains(k) { x1 = p.x }
            if [0, 1, 2].contains(k) { y0 = p.y }
            if [4, 5, 6].contains(k) { y1 = p.y }
            r = CGRect(x: min(x0, x1), y: min(y0, y1), width: abs(x1 - x0), height: abs(y1 - y0))
            if let ratio = crop.ratio, r.width > 0 { // keep the side opposite the dragged handle fixed
                if k == 1 || k == 5 { r.size.width = r.height * ratio; r.origin.x = orig.midX - r.width / 2 }
                else {
                    r.size.height = r.width / ratio
                    if k == 3 || k == 7 { r.origin.y = orig.midY - r.height / 2 }
                    else if k <= 2 { r.origin.y = orig.maxY - r.height }
                }
                r = r.intersection(bounds)
            }
        default: return
        }
        editor.crop?.rect = r.integral.intersection(bounds)
        editor.cropChanged()
        needsDisplay = true
    }

    private func drawCrop(_ ctx: CGContext) {
        guard let r = editor.crop?.rect else { return }
        let all = CGRect(origin: .zero, size: doc.imageSize)
        let dim = CGMutablePath(); dim.addRect(all); dim.addRect(r)
        ctx.addPath(dim); ctx.setFillColor(CGColor(gray: 0, alpha: 0.5)); ctx.fillPath(using: .evenOdd)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.6)); ctx.setLineWidth(1 / mag); ctx.stroke(r)
        // White L brackets at the corners, short bars at the edge midpoints.
        let t = 4 / mag, l = 22 / mag
        ctx.setStrokeColor(.white); ctx.setLineWidth(t); ctx.setLineCap(.square)
        for (c, sx, sy) in [(CGPoint(x: r.minX, y: r.minY), 1.0, 1.0), (CGPoint(x: r.maxX, y: r.minY), -1.0, 1.0),
                            (CGPoint(x: r.maxX, y: r.maxY), -1.0, -1.0), (CGPoint(x: r.minX, y: r.maxY), 1.0, -1.0)] {
            let o = CGPoint(x: c.x - sx * t / 2, y: c.y - sy * t / 2)
            ctx.move(to: CGPoint(x: o.x + sx * l, y: o.y)); ctx.addLine(to: o); ctx.addLine(to: CGPoint(x: o.x, y: o.y + sy * l))
        }
        ctx.strokePath()
        let b = 18 / mag
        for (c, horizontal) in [(CGPoint(x: r.midX, y: r.minY - t / 2), true), (CGPoint(x: r.midX, y: r.maxY + t / 2), true),
                                (CGPoint(x: r.minX - t / 2, y: r.midY), false), (CGPoint(x: r.maxX + t / 2, y: r.midY), false)] {
            ctx.move(to: horizontal ? CGPoint(x: c.x - b / 2, y: c.y) : CGPoint(x: c.x, y: c.y - b / 2))
            ctx.addLine(to: horizontal ? CGPoint(x: c.x + b / 2, y: c.y) : CGPoint(x: c.x, y: c.y + b / 2))
        }
        ctx.strokePath()
    }
}
