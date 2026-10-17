import AppKit
import CoreImage

// The annotate document: a base image plus value-type items. Undo = snapshots of `Doc`.
// Everything is in image points, top-left origin; the same `Render.draw` paints the canvas and the export.

enum Tool: Int, CaseIterable {
    case select, rect, filledRect, ellipse, line, arrow, text, pixelate, spotlight, counter, pencil, marker
    case image // added screenshots; not in the toolbar

    static let toolbar: [Tool] = [.select, .rect, .filledRect, .ellipse, .line, .arrow, .text, .pixelate, .spotlight, .counter, .pencil, .marker]
    var key: String { ["v", "r", "f", "e", "l", "a", "t", "p", "h", "c", "d", "m", ""][rawValue] }
    var symbol: String {
        ["select", "rect", "filledRect", "ellipse", "line", "arrow", "text", "pixelate", "spotlight", "counter", "pencil", "marker", ""][rawValue]
    }
    var name: String {
        ["Select", "Rectangle", "Filled Rectangle", "Ellipse", "Line", "Arrow", "Text", "Pixelate", "Spotlight",
         "Counter", "Pencil", "Marker", "Image"][rawValue]
    }
    /// Shapes defined by two opposite corners.
    var isBox: Bool { [.rect, .filledRect, .ellipse, .pixelate, .spotlight, .image].contains(self) }
}

enum ArrowStyle: Int, CaseIterable { case standard, fancy, curved, double }
enum TextStyle: Int, CaseIterable { case standard, rounded, outlined, mono, box, monoBox, roundedBox }
enum RedactStyle: Int, CaseIterable { case pixelate, blurSecure, blurSmooth, blackOut }
enum SpotShape: Int, CaseIterable { case rect, rounded, ellipse }
enum CounterFormat: Int, CaseIterable { case numbers, upper, roman, lower }

struct Item {
    var tool: Tool
    /// Box: two opposite corners. Line/arrow: start, end (+ through-point for curved). Pencil/marker: the stroke.
    /// Text: top-left. Counter: centre.
    var points: [CGPoint]
    var color: NSColor = Palette.red
    var width: CGFloat = 4
    var arrow = ArrowStyle.standard
    var text = ""
    var fontSize: CGFloat = 30
    var textStyle = TextStyle.standard
    var textWidth: CGFloat? // set by the side handles; nil = grows with the text
    var spot = SpotShape.rounded
    var number = 1
    var image: CGImage?

    var box: CGRect {
        guard points.count >= 2 else { return CGRect(origin: points.first ?? .zero, size: .zero) }
        return CGRect(x: min(points[0].x, points[1].x), y: min(points[0].y, points[1].y),
                      width: abs(points[1].x - points[0].x), height: abs(points[1].y - points[0].y))
    }

    func moved(by d: CGPoint) -> Item {
        var c = self
        c.points = points.map { CGPoint(x: $0.x + d.x, y: $0.y + d.y) }
        return c
    }
}

/// Glint's design tokens: neutral dark grays and one accent (the blue from the top of the app icon). Chrome colors are device RGB so
/// they render as specified next to other apps' windows.
enum Palette {
    static func hex(_ v: Int, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(v >> 16 & 255) / 255, green: CGFloat(v >> 8 & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: a)
    }
    static func dev(_ v: Int, _ a: CGFloat = 1) -> NSColor {
        NSColor(deviceRed: CGFloat(v >> 16 & 255) / 255, green: CGFloat(v >> 8 & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: a)
    }

    // Annotation colors (default first after black).
    static let red = hex(0xFF5A5F)
    static let swatches = [0x111111, 0xFF5A5F, 0xFF9F1C, 0xFFD23F, 0x2FD17A, 0x19C6D1, 0x3B8CFF, 0x8C6BFF, 0xFF5FA8, 0xFFFFFF].map { hex($0) }
    static let thickness: [CGFloat] = [2, 3, 4, 6, 9, 13]

    // Surfaces, darkest to lightest.
    static let canvas = dev(0x141414)      // behind the image in the editor
    static let chrome = dev(0x1C1C1E)      // window and title bar
    static let capsule = dev(0x2A2A2C)     // floating panels: tool rail, inspector, popup frame, overlay bars
    static let button = dev(0x3A3A3C)      // secondary buttons and chips
    static let secondary = button
    static let pill = capsule
    static let cropCanvas = dev(0x2C2C2E)
    static let hairline = dev(0x2E2E30)
    static let panelBorder = dev(0x444446)

    // Text and icons.
    static let icon = dev(0xEBEBF0)
    static let muted = dev(0x9A9AA0)

    // Accent: the blue from the app icon. Selection handles and halos use it too.
    static let selected = dev(0x3D8BFF)
    static let accent = selected
    static let handle = hex(0x3D8BFF), halo = hex(0x3D8BFF, 0.45)
}

struct Background: Equatable {
    enum Fill: Equatable { case gradient(Int), color(NSColor), image(CGImage) }
    var fill: Fill
    var padding: CGFloat = 96, inset: CGFloat = 0, shadow: CGFloat = 30, corners: CGFloat = 12
    var align = 4 // 3×3 grid, row-major; 4 = centre
    var ratio: CGFloat? // width / height; nil = Auto
    var frame: DeviceFrame? // replaces the plain card (inset and corners) with a window or device
}

struct Doc {
    var image: CGImage
    var scale: CGFloat // image pixels per point
    var items: [Item] = []
    var redact = RedactStyle.pixelate, redactIntensity: CGFloat = 30
    var spotOpacity: CGFloat = 45
    var counterFormat = CounterFormat.numbers, counterSize: CGFloat = 20
    var background: Background?

    var imageSize: CGSize { CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale) }

    /// Canvas size and where the image sits on it (the background tool adds padding around it).
    var layout: (canvas: CGSize, origin: CGPoint) {
        guard let bg = background else { return (imageSize, .zero) }
        let fi = bg.frame?.insets(for: imageSize) ?? DeviceFrame.Insets(top: bg.inset, left: bg.inset, bottom: bg.inset, right: bg.inset)
        let content = CGSize(width: imageSize.width + fi.left + fi.right, height: imageSize.height + fi.top + fi.bottom)
        var canvas = CGSize(width: content.width + 2 * bg.padding, height: content.height + 2 * bg.padding)
        if let r = bg.ratio {
            if canvas.width / canvas.height < r { canvas.width = canvas.height * r } else { canvas.height = canvas.width / r }
        }
        // Centre = equal padding; other cells push the card flush against that side.
        let ax = CGFloat(bg.align % 3) / 2, ay = CGFloat(bg.align / 3) / 2
        let origin = CGPoint(x: ((canvas.width - content.width) * ax + fi.left).rounded(),
                             y: ((canvas.height - content.height) * ay + fi.top).rounded())
        return (CGSize(width: canvas.width.rounded(), height: canvas.height.rounded()), origin)
    }

    func label(_ n: Int) -> String {
        switch counterFormat {
        case .numbers: return "\(n)"
        case .upper, .lower:
            var s = "", k = n
            repeat { k -= 1; s = String(UnicodeScalar(65 + k % 26)!) + s; k /= 26 } while k > 0
            return counterFormat == .upper ? s : s.lowercased()
        case .roman:
            var s = "", k = n
            for (v, r) in [(1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"), (90, "XC"), (50, "L"),
                           (40, "XL"), (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")] { while k >= v { s += r; k -= v } }
            return s
        }
    }
}

// MARK: - Geometry shared by drawing, hit-testing and handles

enum Geometry {
    static func snap45(_ from: CGPoint, _ to: CGPoint) -> CGPoint {
        let dx = to.x - from.x, dy = to.y - from.y, len = hypot(dx, dy)
        let a = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
        return CGPoint(x: from.x + cos(a) * len, y: from.y + sin(a) * len)
    }

    static func square(_ from: CGPoint, _ to: CGPoint) -> CGPoint {
        let s = max(abs(to.x - from.x), abs(to.y - from.y))
        return CGPoint(x: from.x + (to.x < from.x ? -s : s), y: from.y + (to.y < from.y ? -s : s))
    }

    /// The shape's geometry; stroked shapes are hit-tested along it, filled ones inside it.
    static func outline(_ it: Item, doc: Doc) -> (path: CGPath, filled: Bool) {
        switch it.tool {
        case .rect: return (CGPath(roundedRect: it.box, cornerWidth: min(it.width, it.box.width / 2), cornerHeight: min(it.width, it.box.height / 2), transform: nil), false)
        case .ellipse: return (CGPath(ellipseIn: it.box, transform: nil), false)
        case .filledRect, .pixelate, .image: return (CGPath(roundedRect: it.box, cornerWidth: min(6, it.box.width / 2), cornerHeight: min(6, it.box.height / 2), transform: nil), true)
        case .spotlight: return (spotPath(it), true)
        case .line, .arrow:
            let p = CGMutablePath()
            p.move(to: it.points[0])
            if it.tool == .arrow, it.arrow == .curved, it.points.count > 2 { p.addQuadCurve(to: it.points[1], control: curveControl(it)) }
            else { p.addLine(to: it.points[1]) }
            return (p, false)
        case .pencil, .marker: return (smoothed(it.points), false)
        case .text: return (CGPath(rect: Render.textFrame(it), transform: nil), true)
        case .counter:
            let r = doc.counterSize / 2
            return (CGPath(ellipseIn: CGRect(x: it.points[0].x - r, y: it.points[0].y - r, width: 2 * r, height: 2 * r), transform: nil), true)
        case .select: return (CGMutablePath(), true)
        }
    }

    static func hit(_ it: Item, _ p: CGPoint, doc: Doc, tolerance: CGFloat) -> Bool {
        let (path, filled) = outline(it, doc: doc)
        if filled { return path.boundingBox.insetBy(dx: -tolerance, dy: -tolerance).contains(p) && (path.contains(p) || path.copy(strokingWithWidth: 2 * tolerance, lineCap: .round, lineJoin: .round, miterLimit: 1).contains(p)) }
        let w = (it.tool == .marker ? it.width * 4 : it.width) + 2 * tolerance
        return path.copy(strokingWithWidth: w, lineCap: .round, lineJoin: .round, miterLimit: 1).contains(p)
    }

    /// The curve passes through points[2] (the middle handle is a through-point, not a control point).
    static func curveControl(_ it: Item) -> CGPoint {
        let s = it.points[0], e = it.points[1], m = it.points[2]
        return CGPoint(x: 2 * m.x - (s.x + e.x) / 2, y: 2 * m.y - (s.y + e.y) / 2)
    }

    static func spotPath(_ it: Item) -> CGPath {
        let b = it.box
        switch it.spot {
        case .rect: return CGPath(rect: b, transform: nil)
        case .rounded: return CGPath(roundedRect: b, cornerWidth: min(12, b.width / 2), cornerHeight: min(12, b.height / 2), transform: nil)
        case .ellipse: return CGPath(ellipseIn: b, transform: nil)
        }
    }

    static func polyline(_ pts: [CGPoint]) -> CGPath {
        let p = CGMutablePath()
        if let f = pts.first { p.addLines(between: pts.count == 1 ? [f, f] : pts) }
        return p
    }

    /// Quadratic smoothing through the midpoints of the raw samples.
    static func smoothed(_ pts: [CGPoint]) -> CGPath {
        let p = CGMutablePath()
        guard let first = pts.first else { return p }
        p.move(to: first)
        if pts.count < 3 { pts.dropFirst().forEach { p.addLine(to: $0) }; if pts.count == 1 { p.addLine(to: first) }; return p }
        for i in 1..<pts.count - 1 {
            let mid = CGPoint(x: (pts[i].x + pts[i + 1].x) / 2, y: (pts[i].y + pts[i + 1].y) / 2)
            p.addQuadCurve(to: mid, control: pts[i])
        }
        p.addLine(to: pts[pts.count - 1])
        return p
    }
}

// MARK: - Rendering

enum Render {
    /// Draws into a context whose user space is canvas points with a top-left origin (flipped).
    static func draw(_ doc: Doc, in ctx: CGContext, halo: Int? = nil, hidden: Int? = nil) {
        let (canvas, origin) = doc.layout
        let imgRect = CGRect(origin: .zero, size: doc.imageSize)
        let ns = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        defer { NSGraphicsContext.restoreGraphicsState() }

        if let bg = doc.background { drawBackground(bg, doc: doc, canvas: canvas, origin: origin, in: ctx) }
        ctx.saveGState()
        ctx.translateBy(x: origin.x, y: origin.y)

        // Image (rounded when it sits on a background).
        ctx.saveGState()
        if let frame = doc.background?.frame {
            ctx.addPath(frame.screenPath(imgRect)); ctx.clip()
        } else if let bg = doc.background, bg.corners > bg.inset { // image corners follow the card's, minus the inset
            let r = bg.corners - bg.inset
            ctx.addPath(CGPath(roundedRect: imgRect, cornerWidth: r, cornerHeight: r, transform: nil)); ctx.clip()
        }
        drawImage(doc.image, in: imgRect, ctx: ctx)

        // Redactions: the whole image is filtered once and each region reveals it.
        let regions = doc.items.indices.filter { doc.items[$0].tool == .pixelate && $0 != hidden }
        if !regions.isEmpty {
            ctx.saveGState()
            for i in regions { ctx.addPath(Geometry.outline(doc.items[i], doc: doc).path) }
            ctx.clip()
            if doc.redact == .blackOut { ctx.setFillColor(.black); ctx.fill(imgRect) }
            else if let red = RedactCache.image(doc) { drawImage(red, in: imgRect, ctx: ctx) }
            ctx.restoreGState()
        }

        // Spotlight: one dim layer with a hole per spotlight.
        let spots = doc.items.indices.filter { doc.items[$0].tool == .spotlight && $0 != hidden }
        if !spots.isEmpty {
            let p = CGMutablePath()
            p.addRect(imgRect.insetBy(dx: -4000, dy: -4000))
            for i in spots { p.addPath(Geometry.spotPath(doc.items[i])) }
            ctx.addPath(p)
            ctx.setFillColor(CGColor(gray: 0, alpha: doc.spotOpacity / 100))
            ctx.fillPath(using: .evenOdd)
        }
        ctx.restoreGState()
        doc.background?.frame?.drawOver(image: imgRect, in: ctx)

        for (i, it) in doc.items.enumerated() where i != hidden {
            if i == halo { drawHalo(it, doc: doc, in: ctx) }
            if it.tool != .pixelate && it.tool != .spotlight { drawItem(it, doc: doc, in: ctx) }
            else if i == halo { ctx.setStrokeColor(Palette.handle.cgColor); ctx.setLineWidth(1.5); ctx.addPath(Geometry.outline(it, doc: doc).path); ctx.strokePath() }
        }
        ctx.restoreGState()
    }

    /// Flattened export at full pixel resolution.
    static func flatten(_ doc: Doc) -> CGImage? {
        let canvas = doc.layout.canvas
        let w = Int((canvas.width * doc.scale).rounded()), h = Int((canvas.height * doc.scale).rounded())
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: doc.scale, y: -doc.scale)
        draw(doc, in: ctx)
        return ctx.makeImage()
    }

    /// CGContext.draw is bottom-up; flip locally so images land upright in the flipped canvas.
    static func drawImage(_ img: CGImage, in r: CGRect, ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: r.minX, y: r.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(origin: .zero, size: r.size))
        ctx.restoreGState()
    }

    static func drawHalo(_ it: Item, doc: Doc, in ctx: CGContext) {
        guard it.tool != .text, it.tool != .counter, it.tool != .image else { return }
        let (path, filled) = Geometry.outline(it, doc: doc)
        ctx.saveGState()
        ctx.addPath(path)
        ctx.setStrokeColor(Palette.halo.cgColor)
        ctx.setLineWidth((filled ? 0 : (it.tool == .marker ? it.width * 4 : it.width)) + 8)
        ctx.setLineCap(.round); ctx.setLineJoin(.round)
        ctx.strokePath()
        ctx.restoreGState()
    }

    static func drawItem(_ it: Item, doc: Doc, in ctx: CGContext) {
        let color = it.color.cgColor
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setLineCap(.round); ctx.setLineJoin(.round)
        let shadow = { if Settings.drawShadow { ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 3, color: CGColor(gray: 0, alpha: 0.3)) } }
        switch it.tool {
        case .rect, .ellipse, .line:
            shadow()
            ctx.addPath(Geometry.outline(it, doc: doc).path)
            ctx.setStrokeColor(color); ctx.setLineWidth(it.width); ctx.strokePath()
        case .filledRect:
            shadow()
            ctx.addPath(Geometry.outline(it, doc: doc).path); ctx.setFillColor(color); ctx.fillPath()
        case .image:
            if let img = it.image {
                ctx.setShadow(offset: CGSize(width: 0, height: 4), blur: 14, color: CGColor(gray: 0, alpha: 0.35))
                ctx.setFillColor(.black); ctx.fill(it.box)
                ctx.setShadow(offset: .zero, blur: 0, color: nil)
                drawImage(img, in: it.box, ctx: ctx)
            }
        case .arrow:
            shadow()
            drawArrow(it, in: ctx)
        case .pencil:
            ctx.addPath(Settings.smoothDrawing ? Geometry.smoothed(it.points) : Geometry.polyline(it.points)); ctx.setStrokeColor(color); ctx.setLineWidth(it.width); ctx.strokePath()
        case .marker:
            ctx.setBlendMode(.multiply)
            ctx.addPath(Geometry.smoothed(it.points))
            ctx.setStrokeColor(it.color.withAlphaComponent(0.45).cgColor); ctx.setLineWidth(it.width * 4); ctx.strokePath()
        case .counter:
            let r = doc.counterSize / 2, c = it.points[0]
            shadow()
            ctx.setFillColor(color)
            ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            let s = NSAttributedString(string: doc.label(it.number), attributes: [
                .font: NSFont.systemFont(ofSize: doc.counterSize * (doc.label(it.number).count > 2 ? 0.42 : 0.6), weight: .bold),
                .foregroundColor: it.color.isLight ? NSColor.black : NSColor.white])
            let sz = s.size()
            s.draw(at: CGPoint(x: c.x - sz.width / 2, y: c.y - sz.height / 2))
        case .text:
            drawText(it, in: ctx)
        case .pixelate, .spotlight, .select: break
        }
    }

    // MARK: arrows (drawn along +x from the start, then rotated into place)

    static func drawArrow(_ it: Item, in ctx: CGContext) {
        let s = it.points[0], e = it.points[1], t = it.width
        ctx.setFillColor(it.color.cgColor); ctx.setStrokeColor(it.color.cgColor)
        switch it.arrow {
        case .standard, .fancy:
            let len = hypot(e.x - s.x, e.y - s.y)
            guard len > 0.5 else { return }
            ctx.translateBy(x: s.x, y: s.y)
            ctx.rotate(by: atan2(e.y - s.y, e.x - s.x))
            let fancy = it.arrow == .fancy
            let h = min(len * 0.6, fancy ? 5 * t + 10 : 4.5 * t + 8)   // head length
            let w = fancy ? 2.2 * t + 5 : 2.6 * t + 5                   // head half-width
            let notch = h * (fancy ? 0.45 : 0.25)
            let tail = fancy ? 0.15 * t : 0.35 * t, neck = fancy ? 0.55 * t : 0.75 * t
            let p = CGMutablePath()
            p.move(to: CGPoint(x: 0, y: -tail))
            if fancy { p.addQuadCurve(to: CGPoint(x: len - h + notch, y: -neck), control: CGPoint(x: (len - h) * 0.6, y: -neck * 0.4)) }
            else { p.addLine(to: CGPoint(x: len - h + notch, y: -neck)) }
            p.addLine(to: CGPoint(x: len - h, y: -w))
            p.addLine(to: CGPoint(x: len, y: 0))
            p.addLine(to: CGPoint(x: len - h, y: w))
            p.addLine(to: CGPoint(x: len - h + notch, y: neck))
            if fancy { p.addQuadCurve(to: CGPoint(x: 0, y: tail), control: CGPoint(x: (len - h) * 0.6, y: neck * 0.4)) }
            else { p.addLine(to: CGPoint(x: 0, y: tail)) }
            p.closeSubpath()
            ctx.addPath(p); ctx.fillPath()
            if !fancy { ctx.fillEllipse(in: CGRect(x: -tail, y: -tail, width: 2 * tail, height: 2 * tail)) }
        case .curved, .double:
            let lw = max(1.5, t * 0.7)
            ctx.setLineWidth(lw)
            let curved = it.arrow == .curved && it.points.count > 2
            let control = curved ? Geometry.curveControl(it) : s
            let p = CGMutablePath(); p.move(to: s)
            if curved { p.addQuadCurve(to: e, control: control) } else { p.addLine(to: e) }
            ctx.addPath(p); ctx.strokePath()
            let arm = 3 * t + 9
            func vhead(at tip: CGPoint, from: CGPoint) {
                let a = atan2(tip.y - from.y, tip.x - from.x)
                let v = CGMutablePath()
                v.move(to: CGPoint(x: tip.x - arm * cos(a - .pi / 6), y: tip.y - arm * sin(a - .pi / 6)))
                v.addLine(to: tip)
                v.addLine(to: CGPoint(x: tip.x - arm * cos(a + .pi / 6), y: tip.y - arm * sin(a + .pi / 6)))
                ctx.addPath(v); ctx.strokePath()
            }
            vhead(at: e, from: curved ? control : s)
            if it.arrow == .double { vhead(at: s, from: e) }
        }
    }

    // MARK: text

    static func attributes(_ it: Item) -> [NSAttributedString.Key: Any] {
        let size = it.fontSize
        var font: NSFont
        switch it.textStyle {
        case .rounded, .roundedBox:
            let base = NSFont.systemFont(ofSize: size, weight: .bold)
            font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base
        case .mono, .monoBox: font = .monospacedSystemFont(ofSize: size, weight: .bold)
        default: font = .systemFont(ofSize: size, weight: .bold)
        }
        return [.font: font, .foregroundColor: it.color]
    }

    static let textPad = CGSize(width: 10, height: 4)

    /// The text's box in image points: origin = points[0], width fixed by the handles or grown to fit.
    static func textFrame(_ it: Item) -> CGRect {
        let s = NSAttributedString(string: it.text.isEmpty ? " " : it.text, attributes: attributes(it))
        let maxW = it.textWidth.map { $0 - 2 * textPad.width } ?? 100_000
        let b = s.boundingRect(with: CGSize(width: max(maxW, it.fontSize), height: 100_000), options: [.usesLineFragmentOrigin, .usesFontLeading])
        let w = it.textWidth ?? (ceil(b.width) + 2 * textPad.width)
        return CGRect(x: it.points[0].x, y: it.points[0].y, width: max(w, it.fontSize), height: ceil(b.height) + 2 * textPad.height)
    }

    static func drawText(_ it: Item, in ctx: CGContext) {
        guard !it.text.isEmpty else { return }
        let frame = textFrame(it)
        let inner = frame.insetBy(dx: textPad.width, dy: textPad.height)
        var attrs = attributes(it)
        switch it.textStyle {
        case .box, .monoBox, .roundedBox:
            let r = it.textStyle == .roundedBox ? frame.height / 2 : 4
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 4, color: CGColor(gray: 0, alpha: 0.25))
            ctx.addPath(CGPath(roundedRect: frame, cornerWidth: min(r, frame.width / 2), cornerHeight: min(r, frame.height / 2), transform: nil))
            ctx.setFillColor((it.color.blended(withFraction: 0.95, of: .white) ?? .white).cgColor)
            ctx.fillPath()
            ctx.restoreGState()
        case .outlined:
            var stroke = attrs
            stroke[.strokeColor] = NSColor.white
            stroke[.strokeWidth] = 100 * max(3, it.fontSize * 0.16) / it.fontSize // percent of size, positive = stroke only
            NSAttributedString(string: it.text, attributes: stroke).draw(with: inner, options: [.usesLineFragmentOrigin, .usesFontLeading])
        default:
            let sh = NSShadow(); sh.shadowOffset = NSSize(width: 0, height: -1); sh.shadowBlurRadius = 3
            sh.shadowColor = NSColor(white: 0, alpha: 0.3)
            attrs[.shadow] = sh
        }
        NSAttributedString(string: it.text, attributes: attrs).draw(with: inner, options: [.usesLineFragmentOrigin, .usesFontLeading])
    }

    // MARK: background tool

    /// The 20 background gradients (colors, angle in degrees).
    static let gradients: [([Int], CGFloat)] = [
        ([0xF5576C, 0xF093FB], 135), ([0x4E54C8, 0xF78CA0], 135), ([0x0F2027, 0x2C5364, 0x5B8FD9], 160), ([0x43C6AC, 0xF8FFAE], 135), ([0xFF9A8B, 0xFF6A88], 135),
        ([0xA855F7, 0x22D3EE, 0xF472B6], 120), ([0xE0C3FC, 0xF5F5F5], 90), ([0xCFD9DF, 0xE2EBF0], 135), ([0x6A85F6, 0xB9E2FA], 135), ([0x0F0C29, 0x302B63, 0x9D7CD8], 135),
        ([0x2B5876, 0xF0C27B], 90), ([0x7F7FD5, 0x91EAE4, 0xFCC5E4], 90), ([0x8E78FF, 0xFFDDE1, 0xB8A1FF], 135), ([0x3A1C71, 0xD76D77], 135), ([0x0F0C29, 0xC31432], 135),
        ([0xB06AB3, 0x4568DC, 0xF7B3D4], 135), ([0xFF512F, 0xDD2476, 0xFDBB2D], 135), ([0x1FA2FF, 0xF9D423, 0xFF4E50], 90), ([0x41295A, 0xFF4E50, 0xF9D423], 135), ([0xF953C6, 0xB91D73, 0xFFAF7B], 135),
    ]

    static func drawBackground(_ bg: Background, doc: Doc, canvas: CGSize, origin: CGPoint, in ctx: CGContext) {
        let full = CGRect(origin: .zero, size: canvas)
        ctx.saveGState()
        switch bg.fill {
        case .color(let c): ctx.setFillColor(c.cgColor); ctx.fill(full)
        case .gradient(let i): fillGradient(i, in: full, ctx: ctx)
        case .image(let img): // aspect fill
            let k = max(canvas.width / CGFloat(img.width), canvas.height / CGFloat(img.height))
            let sz = CGSize(width: CGFloat(img.width) * k, height: CGFloat(img.height) * k)
            ctx.clip(to: full)
            drawImage(img, in: CGRect(x: (canvas.width - sz.width) / 2, y: (canvas.height - sz.height) / 2, width: sz.width, height: sz.height), ctx: ctx)
        }
        ctx.restoreGState()

        if let frame = bg.frame {
            frame.drawBehind(image: CGRect(origin: origin, size: doc.imageSize), dark: frame.isDark(over: doc.image), shadow: bg.shadow, in: ctx)
            return
        }
        // The card: inset frame (edge color of the screenshot) with corners and a soft shadow.
        let card = CGRect(x: origin.x - bg.inset, y: origin.y - bg.inset,
                          width: doc.imageSize.width + 2 * bg.inset, height: doc.imageSize.height + 2 * bg.inset)
        let path = CGPath(roundedRect: card, cornerWidth: bg.corners, cornerHeight: bg.corners, transform: nil)
        ctx.saveGState()
        if bg.shadow > 0 {
            ctx.setShadow(offset: CGSize(width: 0, height: bg.shadow * 0.25), blur: bg.shadow * 0.9, color: CGColor(gray: 0, alpha: min(0.6, 0.2 + bg.shadow / 200)))
        }
        ctx.addPath(path)
        ctx.setFillColor(edgeColor(doc.image))
        ctx.fillPath()
        ctx.restoreGState()
    }

    static func fillGradient(_ i: Int, in r: CGRect, ctx: CGContext) {
        let (hexes, angle) = gradients[i % gradients.count]
        let colors = hexes.map { Palette.hex($0).cgColor } as CFArray
        guard let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: nil) else { return }
        let a = angle * .pi / 180, c = CGPoint(x: r.midX, y: r.midY)
        let half = (abs(cos(a)) * r.width + abs(sin(a)) * r.height) / 2
        ctx.saveGState(); ctx.clip(to: r)
        ctx.drawLinearGradient(g, start: CGPoint(x: c.x - cos(a) * half, y: c.y - sin(a) * half),
                               end: CGPoint(x: c.x + cos(a) * half, y: c.y + sin(a) * half), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }

    /// Top-left pixel: the screenshot's own background, used to fill the inset frame.
    static func edgeColor(_ img: CGImage) -> CGColor {
        let rep = NSBitmapImageRep(cgImage: img)
        return rep.colorAt(x: 0, y: 0)?.cgColor ?? .white
    }
}

/// Whole-image pixelate/blur, rendered once per (image, style, intensity) and revealed per region.
enum RedactCache {
    private static var key: (CGImage, RedactStyle, CGFloat)?
    private static var value: CGImage?
    private static let ci = CIContext()

    static func image(_ doc: Doc) -> CGImage? {
        if let k = key, k.0 === doc.image, k.1 == doc.redact, k.2 == doc.redactIntensity { return value }
        let src = CIImage(cgImage: doc.image), extent = src.extent
        let px = doc.redactIntensity * doc.scale
        let center = CIVector(x: extent.midX, y: extent.midY)
        var out: CIImage
        switch doc.redact {
        case .pixelate: out = src.applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: px * 0.8, kCIInputCenterKey: center])
        case .blurSecure:
            out = src.applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: px * 0.4, kCIInputCenterKey: center])
                .clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: px * 0.35])
        case .blurSmooth: out = src.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: px * 0.5])
        case .blackOut: out = src
        }
        value = ci.createCGImage(out.cropped(to: extent), from: extent)
        key = (doc.image, doc.redact, doc.redactIntensity)
        return value
    }
}

extension NSColor {
    var isLight: Bool {
        guard let c = usingColorSpace(.sRGB) else { return false }
        return 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent > 0.75
    }
}
