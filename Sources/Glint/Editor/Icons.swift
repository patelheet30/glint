import AppKit

/// Hand-drawn editor icons in the style of the popup's ✓: one stroke weight, round caps and joins, drawn on an
/// 18-unit grid and rendered crisp at any size. Used instead of SF Symbols for a consistent weight.
enum Icon {
    /// Capture Bar mode icons (and the OCR glyph they share) use one lighter weight so the row reads evenly.
    static let modeStroke: CGFloat = 1.75
    static let stroke: CGFloat = 2 // 2px at 1:1 — thick enough to read crisp on a 1× display

    /// `name` is a tool or chrome icon id; nil if we don't draw it (callers fall back to SF Symbols).
    static func image(_ name: String, size: CGFloat = 16, color: NSColor = Palette.icon) -> NSImage? {
        guard let draw = shapes[name] else { return nil }
        return NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.scaleBy(x: size / 18, y: size / 18)
            ctx.setLineWidth(stroke)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.setStrokeColor(color.cgColor)
            ctx.setFillColor(color.cgColor)
            draw(ctx)
            return true
        }
    }

    // MARK: path helpers

    private static func line(_ ctx: CGContext, _ pts: [(CGFloat, CGFloat)], close: Bool = false) {
        ctx.move(to: CGPoint(x: pts[0].0, y: pts[0].1))
        for p in pts.dropFirst() { ctx.addLine(to: CGPoint(x: p.0, y: p.1)) }
        if close { ctx.closePath() }
        ctx.strokePath()
    }

    /// Polyline whose corners are rounded with `radius` (ends stay as-is).
    private static func softLine(_ ctx: CGContext, _ pts: [(CGFloat, CGFloat)], radius: CGFloat) {
        let p = pts.map { CGPoint(x: $0.0, y: $0.1) }
        ctx.move(to: p[0])
        for i in 1..<p.count - 1 { ctx.addArc(tangent1End: p[i], tangent2End: p[i + 1], radius: radius) }
        ctx.addLine(to: p[p.count - 1])
        ctx.strokePath()
    }

    private static func rr(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> CGPath {
        CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: r, cornerHeight: r, transform: nil)
    }

    /// Cuts `body` out of what's already drawn (badges, the counter's "1").
    private static func knockout(_ ctx: CGContext, _ body: () -> Void) {
        ctx.saveGState(); ctx.setBlendMode(.destinationOut); body(); ctx.restoreGState()
    }

    private static let pencilBody: [(CGFloat, CGFloat)] = [(3, 15), (3.8, 11.6), (12.2, 3.2), (14.8, 5.8), (6.4, 14.2)]

    // MARK: shapes (18-unit grid = pixels at 1×; keep straight edges on whole/half units so they land on pixels)

    private static let shapes: [String: (CGContext) -> Void] = [
        // Toolbar actions
        "crop": { ctx in
            line(ctx, [(5, 1.8), (5, 13), (16.2, 13)])
            line(ctx, [(1.8, 5), (13, 5), (13, 16.2)])
        },
        "photo.badge.plus": { ctx in
            ctx.addPath(rr(1.2, 2.4, 13.2, 10.8, 2.6)); ctx.strokePath()
            ctx.move(to: CGPoint(x: 3.2, y: 11.4)); ctx.addLine(to: CGPoint(x: 6.6, y: 7.4)); ctx.addLine(to: CGPoint(x: 9.2, y: 10))
            ctx.addLine(to: CGPoint(x: 10.6, y: 8.6)); ctx.addLine(to: CGPoint(x: 12.6, y: 10.6)); ctx.addLine(to: CGPoint(x: 12.6, y: 11.4)); ctx.closePath()
            ctx.setLineWidth(1); ctx.drawPath(using: .fillStroke); ctx.setLineWidth(Icon.stroke)
            knockout(ctx) { ctx.fillEllipse(in: CGRect(x: 8.4, y: 8.4, width: 10.4, height: 10.4)) }
            ctx.fillEllipse(in: CGRect(x: 9.6, y: 9.6, width: 8, height: 8))
            knockout(ctx) { ctx.setLineWidth(1.6); line(ctx, [(13.6, 11.4), (13.6, 15.8)]); line(ctx, [(11.4, 13.6), (15.8, 13.6)]) }
        },
        "photo.artframe": { ctx in
            ctx.addPath(rr(1.4, 2.4, 15.2, 13.2, 3)); ctx.strokePath()
            ctx.addPath(rr(4.4, 5.4, 9.2, 7.2, 1.2)); ctx.fillPath()
            knockout(ctx) {
                ctx.move(to: CGPoint(x: 5.6, y: 11.6)); ctx.addLine(to: CGPoint(x: 8.2, y: 8.6)); ctx.addLine(to: CGPoint(x: 10, y: 10.4))
                ctx.addLine(to: CGPoint(x: 11, y: 9.4)); ctx.addLine(to: CGPoint(x: 12.4, y: 10.8)); ctx.addLine(to: CGPoint(x: 12.4, y: 11.6)); ctx.closePath(); ctx.fillPath()
            }
        },
        // Tools
        "select": { ctx in
            ctx.move(to: CGPoint(x: 4.5, y: 2.5)); ctx.addLine(to: CGPoint(x: 4.5, y: 14.8))
            ctx.addLine(to: CGPoint(x: 7.6, y: 11.9)); ctx.addLine(to: CGPoint(x: 9.7, y: 16.2))
            ctx.addLine(to: CGPoint(x: 11.5, y: 15.4)); ctx.addLine(to: CGPoint(x: 9.5, y: 11.1))
            ctx.addLine(to: CGPoint(x: 13.6, y: 11.1)); ctx.closePath()
            ctx.setLineWidth(1.2); ctx.drawPath(using: .fillStroke)
        },
        "rect": { ctx in ctx.addPath(rr(3, 3, 12, 12, 2)); ctx.strokePath() },
        "filledRect": { ctx in ctx.addPath(rr(2.6, 2.6, 12.8, 12.8, 2.4)); ctx.fillPath() },
        "ellipse": { ctx in ctx.strokeEllipse(in: CGRect(x: 2.8, y: 2.8, width: 12.4, height: 12.4)) },
        "line": { ctx in line(ctx, [(3.5, 14.5), (14.5, 3.5)]) },
        "arrow": { ctx in
            line(ctx, [(14.2, 3.8), (4.2, 13.8)])
            line(ctx, [(4, 7.6), (4, 14), (10.4, 14)])
        },
        "text": { ctx in
            ctx.setLineWidth(2.4)
            line(ctx, [(3.6, 15.2), (9, 2.8), (14.4, 15.2)])
            line(ctx, [(5.7, 10.6), (12.3, 10.6)])
        },
        "pixelate": { ctx in
            let s: CGFloat = 4.4, o: CGFloat = 2.4
            for i in 0..<3 { for j in 0..<3 {
                ctx.setAlpha((i + j) % 2 == 0 ? 1 : 0.35)
                ctx.addPath(rr(o + CGFloat(i) * s, o + CGFloat(j) * s, s, s, 0.5)); ctx.fillPath()
            } }
            ctx.setAlpha(1)
        },
        "spotlight": { ctx in
            ctx.addPath(rr(1.6, 3.2, 14.8, 11.6, 2.6)); ctx.strokePath()
            ctx.addPath(rr(5, 6.5, 8, 5, 1.2)); ctx.fillPath()
        },
        "counter": { ctx in
            ctx.fillEllipse(in: CGRect(x: 1.8, y: 1.8, width: 14.4, height: 14.4))
            knockout(ctx) { ctx.setLineWidth(1.9); line(ctx, [(7.4, 6.6), (9.4, 5), (9.4, 13)]) }
        },
        "pencil": { ctx in
            line(ctx, pencilBody, close: true)
            line(ctx, [(10.6, 4.8), (13.2, 7.4)])
        },
        "marker": { ctx in
            line(ctx, [(4.2, 12.4), (5, 9.6), (11.6, 3), (14.2, 5.6), (7.6, 12.2)], close: true)
            line(ctx, [(2.5, 16), (15.5, 16)])
        },
        // Popup card's annotate button: a solid pencil with knocked-out ferrule and tip lines (ink color).
        "pencil.fill": { ctx in
            ctx.move(to: CGPoint(x: 4, y: 14)); ctx.addLine(to: CGPoint(x: 4.8, y: 10.6)); ctx.addLine(to: CGPoint(x: 11.2, y: 4.2))
            ctx.addLine(to: CGPoint(x: 13.8, y: 6.8)); ctx.addLine(to: CGPoint(x: 7.4, y: 13.2)); ctx.closePath()
            ctx.setLineWidth(1.6); ctx.drawPath(using: .fillStroke)
            knockout(ctx) {
                ctx.setLineWidth(1.1)
                line(ctx, [(9.6, 5.8), (12.2, 8.4)])
                line(ctx, [(4.9, 10.5), (7.5, 13.1)])
            }
        },
        // Popup card's Extract Text button: scan corners around two text lines (ink color).
        "ocr": { ctx in
            ctx.setLineWidth(modeStroke)
            line(ctx, [(2.5, 6.5), (2.5, 2.5), (6.5, 2.5)]); line(ctx, [(11.5, 2.5), (15.5, 2.5), (15.5, 6.5)])
            line(ctx, [(15.5, 11.5), (15.5, 15.5), (11.5, 15.5)]); line(ctx, [(6.5, 15.5), (2.5, 15.5), (2.5, 11.5)])
            line(ctx, [(6, 7.2), (12, 7.2)]); line(ctx, [(6, 10.8), (10.8, 10.8)])
        },
        // Capture Bar modes
        "area": { ctx in
            ctx.setLineWidth(modeStroke)
            ctx.setLineDash(phase: 0, lengths: [2.6, 2.6]); ctx.addPath(rr(2, 3, 14, 12, 2.4)); ctx.strokePath(); ctx.setLineDash(phase: 0, lengths: [])
            ctx.fillEllipse(in: CGRect(x: 7.4, y: 7.4, width: 3.2, height: 3.2))
        },
        "fullscreen": { ctx in
            ctx.setLineWidth(modeStroke)
            ctx.addPath(rr(1.5, 2.5, 15, 10.5, 2.2)); ctx.strokePath()
            line(ctx, [(9, 13), (9, 15.5)]); line(ctx, [(5.5, 15.8), (12.5, 15.8)])
        },
        "window": { ctx in
            ctx.setLineWidth(modeStroke)
            ctx.addPath(rr(1.5, 2.5, 15, 13, 2.6)); ctx.strokePath()
            line(ctx, [(1.8, 6.5), (16.2, 6.5)])
            ctx.fillEllipse(in: CGRect(x: 3.6, y: 3.7, width: 1.6, height: 1.6)); ctx.fillEllipse(in: CGRect(x: 6.2, y: 3.7, width: 1.6, height: 1.6))
        },
        "timer": { ctx in
            ctx.setLineWidth(modeStroke)
            ctx.strokeEllipse(in: CGRect(x: 2.5, y: 3.5, width: 13, height: 13))
            line(ctx, [(9, 6.8), (9, 10), (11.4, 11.6)]); line(ctx, [(7, 1.4), (11, 1.4)])
        },
        // Menu bar: four rounded viewfinder corners around a solid shutter dot (template image, tinted by macOS).
        "menubar": { ctx in
            ctx.setLineWidth(1.9)
            let corners: [[(CGFloat, CGFloat)]] = [[(1.8, 6.4), (1.8, 1.8), (6.4, 1.8)], [(11.6, 1.8), (16.2, 1.8), (16.2, 6.4)],
                                                   [(16.2, 11.6), (16.2, 16.2), (11.6, 16.2)], [(6.4, 16.2), (1.8, 16.2), (1.8, 11.6)]]
            for c in corners { softLine(ctx, c, radius: 3) }
            ctx.fillEllipse(in: CGRect(x: 5.6, y: 5.6, width: 6.8, height: 6.8))
        },
        "scrolling": { ctx in
            ctx.setLineWidth(modeStroke)
            ctx.addPath(rr(3.5, 1.5, 11, 11, 2.2)); ctx.strokePath()
            line(ctx, [(9, 5), (9, 16.2)]); line(ctx, [(6.2, 13.4), (9, 16.2), (11.8, 13.4)])
        },
        "expand": { ctx in
            line(ctx, [(10.5, 3), (15, 3), (15, 7.5)]); line(ctx, [(15, 3), (10.2, 7.8)])
            line(ctx, [(7.5, 15), (3, 15), (3, 10.5)]); line(ctx, [(3, 15), (7.8, 10.2)])
        },
        // Small chrome glyphs
        "close": { ctx in line(ctx, [(5, 5), (13, 13)]); line(ctx, [(13, 5), (5, 13)]) },
        "chevron.up": { ctx in ctx.setLineWidth(2.4); line(ctx, [(4, 11.5), (9, 6.5), (14, 11.5)]) },
        "lock": { ctx in
            ctx.addPath(rr(3.5, 8, 11, 8.5, 2.4)); ctx.fillPath()
            ctx.move(to: CGPoint(x: 6, y: 8)); ctx.addLine(to: CGPoint(x: 6, y: 5.6))
            ctx.addArc(center: CGPoint(x: 9, y: 5.6), radius: 3, startAngle: .pi, endAngle: 0, clockwise: false)
            ctx.addLine(to: CGPoint(x: 12, y: 8)); ctx.strokePath()
        },
        // Bottom bar
        "square.and.arrow.up": { ctx in
            softLine(ctx, [(5.8, 7), (3.8, 7), (3.8, 16), (14.2, 16), (14.2, 7), (12.2, 7)], radius: 2.8)
            line(ctx, [(9, 11), (9, 1.8)])
            line(ctx, [(6, 4.6), (9, 1.6), (12, 4.6)])
        },
        "pin.fill": { ctx in
            ctx.translateBy(x: 9, y: 9); ctx.rotate(by: .pi / 4); ctx.translateBy(x: -9, y: -9)
            ctx.addPath(rr(5, 1.4, 8, 2.8, 1.4)); ctx.fillPath()
            ctx.move(to: CGPoint(x: 6.6, y: 3.6)); ctx.addLine(to: CGPoint(x: 6.6, y: 7.6)); ctx.addLine(to: CGPoint(x: 4.4, y: 10.6))
            ctx.addLine(to: CGPoint(x: 13.6, y: 10.6)); ctx.addLine(to: CGPoint(x: 11.4, y: 7.6)); ctx.addLine(to: CGPoint(x: 11.4, y: 3.6))
            ctx.closePath(); ctx.setLineWidth(2); ctx.drawPath(using: .fillStroke) // wide round join softens the corners
            ctx.setLineWidth(Icon.stroke); line(ctx, [(9, 10.6), (9, 16.4)])
        },
        "doc.on.doc.fill": { ctx in
            ctx.addPath(rr(6, 1.6, 10, 11.4, 3.2)); ctx.strokePath()
            knockout(ctx) { ctx.addPath(rr(1.2, 4.2, 11.6, 13, 4)); ctx.fillPath() }
            ctx.addPath(rr(2.2, 5.2, 9.6, 11, 3)); ctx.fillPath()
        },
        // Small chrome
        "chevron": { ctx in ctx.setLineWidth(2.8); line(ctx, [(4.5, 7), (9, 11.5), (13.5, 7)]) },
        "grip": { ctx in ctx.setLineWidth(1.4); for y: CGFloat in [5, 9, 13] { line(ctx, [(4, y), (14, y)]) } },
        "swap": { ctx in
            line(ctx, [(3, 6), (15, 6)]); line(ctx, [(12, 3), (15, 6), (12, 9)])
            line(ctx, [(15, 12), (3, 12)]); line(ctx, [(6, 9), (3, 12), (6, 15)])
        },
        "rotate": { ctx in
            ctx.addPath(rr(5.5, 7, 10, 9, 2)); ctx.strokePath()
            ctx.move(to: CGPoint(x: 2.6, y: 9)); ctx.addQuadCurve(to: CGPoint(x: 9, y: 2.6), control: CGPoint(x: 2.6, y: 2.6)); ctx.strokePath()
            line(ctx, [(7, 0.8), (9.2, 2.6), (7, 4.6)])
        },
        "flip": { ctx in
            ctx.setLineDash(phase: 0, lengths: [1.6, 2.4]); line(ctx, [(9, 1.5), (9, 16.5)]); ctx.setLineDash(phase: 0, lengths: [])
            ctx.move(to: CGPoint(x: 6.4, y: 4)); ctx.addLine(to: CGPoint(x: 6.4, y: 14)); ctx.addLine(to: CGPoint(x: 1.8, y: 14)); ctx.closePath(); ctx.strokePath()
            ctx.move(to: CGPoint(x: 11.6, y: 4)); ctx.addLine(to: CGPoint(x: 11.6, y: 14)); ctx.addLine(to: CGPoint(x: 16.2, y: 14)); ctx.closePath(); ctx.fillPath()
        },
        // Option menus
        "thickness": { ctx in ctx.setLineWidth(3.2); line(ctx, [(4, 14), (14, 4)]) },
        "rounded": { ctx in ctx.addPath(rr(2.5, 4, 13, 10, 3.2)); ctx.strokePath() },
        "square": { ctx in ctx.addPath(rr(2.5, 4, 13, 10, 0.6)); ctx.strokePath() },
        "oval": { ctx in ctx.strokeEllipse(in: CGRect(x: 2.5, y: 4, width: 13, height: 10)) },
        "blur": { ctx in
            for (r, a) in [(7.0, 0.25), (5.2, 0.5), (3.4, 1.0)] as [(CGFloat, CGFloat)] {
                ctx.setAlpha(a); ctx.fillEllipse(in: CGRect(x: 9 - r, y: 9 - r, width: 2 * r, height: 2 * r))
            }
            ctx.setAlpha(1)
        },
        "blackout": { ctx in ctx.addPath(rr(2, 5, 14, 8, 1.6)); ctx.fillPath() },
        "number": { ctx in
            line(ctx, [(7, 2.5), (5.5, 15.5)]); line(ctx, [(12.5, 2.5), (11, 15.5)])
            line(ctx, [(3.2, 6.5), (15.2, 6.5)]); line(ctx, [(2.8, 11.5), (14.8, 11.5)])
        },
    ]
}
