import AppKit

/// A device or window drawn around the screenshot (background tool → Frame). Vector, so it's sharp at any export size.
struct DeviceFrame: Equatable {
    enum Style: Int, CaseIterable {
        case macWindow, browser, macBook, iPhone, iPad

        var title: String { ["Mac window", "Browser", "MacBook", "iPhone", "iPad"][rawValue] }
        var symbol: String { ["macwindow", "safari", "laptopcomputer", "iphone", "ipad"][rawValue] }
        /// Window frames carry text (window title / address bar).
        var hasText: Bool { self == .macWindow || self == .browser }
    }
    enum Appearance: Int, CaseIterable { case auto, light, dark }

    var style: Style
    var appearance = Appearance.auto
    var text = ""   // window title, or the browser's address

    struct Insets: Equatable { var top: CGFloat, left: CGFloat, bottom: CGFloat, right: CGFloat }

    static let titleBar: CGFloat = 28, browserBar: CGFloat = 44

    /// Room the frame needs around an image of `size` (points).
    func insets(for size: CGSize) -> Insets {
        switch style {
        case .macWindow: return Insets(top: Self.titleBar, left: 0, bottom: 0, right: 0)
        case .browser: return Insets(top: Self.browserBar, left: 0, bottom: 0, right: 0)
        case .macBook:
            let m = macBook(size)
            return Insets(top: m.bezel * 1.3, left: m.bezel + m.overhang, bottom: m.bezel + m.base, right: m.bezel + m.overhang)
        case .iPhone, .iPad:
            let b = bezel(size)
            return Insets(top: b, left: b, bottom: b, right: b)
        }
    }

    /// Lid bezel, how far the base sticks out past the lid on each side, and the base's height.
    private func macBook(_ s: CGSize) -> (bezel: CGFloat, overhang: CGFloat, base: CGFloat) {
        let bezel = max(12, s.width * 0.03)
        return (bezel, (s.width + 2 * bezel) * 0.08, max(10, s.width * 0.028))
    }

    private func bezel(_ s: CGSize) -> CGFloat {
        style == .iPhone ? max(10, s.width * 0.045) : max(10, min(s.width, s.height) * 0.05)
    }

    /// Corner radius of the screen itself (the image is clipped to it).
    func screenRadius(_ s: CGSize) -> CGFloat {
        switch style {
        case .macWindow, .browser: 10
        case .macBook: 4
        case .iPhone: min(s.width, s.height) * 0.12
        case .iPad: min(s.width, s.height) * 0.04
        }
    }

    /// Where the image is clipped: window frames round only the bottom corners (the bar covers the top).
    func screenPath(_ r: CGRect) -> CGPath {
        switch style {
        case .macWindow, .browser:
            let rad = screenRadius(r.size), p = CGMutablePath()
            p.move(to: CGPoint(x: r.minX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
            p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.maxY), radius: rad)
            p.addArc(tangent1End: CGPoint(x: r.minX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.minY), radius: rad)
            p.closeSubpath()
            return p
        default:
            let rad = screenRadius(r.size)
            return CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil)
        }
    }

    func isDark(over image: CGImage) -> Bool {
        switch appearance {
        case .light: false
        case .dark: true
        case .auto: !(NSColor(cgColor: Render.edgeColor(image))?.isLight ?? false)
        }
    }

    // MARK: drawing (flipped context, canvas points)

    /// Draws everything behind the image (body, bars, bezels), with `shadow` (0–100) under it. `image` is where the screenshot goes.
    func drawBehind(image r: CGRect, dark: Bool, shadow: CGFloat, in ctx: CGContext) {
        let i = insets(for: r.size)
        let outer = CGRect(x: r.minX - i.left, y: r.minY - i.top, width: r.width + i.left + i.right, height: r.height + i.top + i.bottom)
        func withShadow(_ body: () -> Void) {
            ctx.saveGState()
            if shadow > 0 {
                ctx.setShadow(offset: CGSize(width: 0, height: shadow * 0.25), blur: shadow * 0.9,
                              color: CGColor(gray: 0, alpha: min(0.6, 0.2 + shadow / 200)))
            }
            body()
            ctx.restoreGState()
        }
        switch style {
        case .macWindow, .browser:
            let path = CGPath(roundedRect: outer, cornerWidth: 10, cornerHeight: 10, transform: nil)
            withShadow { ctx.addPath(path); ctx.setFillColor(Self.hex(dark ? 0x2B2B2D : 0xECECEC)); ctx.fillPath() }
            trafficLights(x: outer.minX + 14, midY: outer.minY + i.top / 2, in: ctx)
            if style == .browser { addressBar(outer, barHeight: i.top, dark: dark, in: ctx) } else { windowTitle(outer, dark: dark, in: ctx) }
            ctx.addPath(path); ctx.setStrokeColor(Self.hex(dark ? 0x000000 : 0x000000, dark ? 0.6 : 0.18)); ctx.setLineWidth(0.5); ctx.strokePath()

        case .macBook:
            let m = macBook(r.size)
            let lid = CGRect(x: r.minX - m.bezel, y: outer.minY, width: r.width + 2 * m.bezel, height: r.height + m.bezel * 2.3)
            let base = CGRect(x: outer.minX, y: lid.maxY, width: outer.width, height: m.base)
            let lidPath = CGPath(roundedRect: lid, cornerWidth: m.bezel * 1.1, cornerHeight: m.bezel * 1.1, transform: nil)
            let basePath = CGMutablePath()
            basePath.addRoundedRect(in: base, cornerWidth: m.base * 0.5, cornerHeight: m.base * 0.5)
            withShadow {
                ctx.addPath(lidPath); ctx.addPath(basePath); ctx.setFillColor(Self.hex(0x0E0E10)); ctx.fillPath()
            }
            // Aluminium base with the opening notch, and the camera dot in the top bezel.
            ctx.saveGState()
            ctx.addPath(basePath); ctx.clip()
            let alu = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [Self.hex(0xE3E4E7), Self.hex(0xA7A9AE)] as CFArray, locations: nil)!
            ctx.drawLinearGradient(alu, start: CGPoint(x: 0, y: base.minY), end: CGPoint(x: 0, y: base.maxY), options: [])
            ctx.restoreGState()
            let notch = CGRect(x: base.midX - lid.width * 0.09, y: base.minY, width: lid.width * 0.18, height: base.height * 0.38)
            ctx.addPath(CGPath(roundedRect: notch, cornerWidth: notch.height / 2, cornerHeight: notch.height / 2, transform: nil))
            ctx.setFillColor(Self.hex(0x8E9095)); ctx.fillPath()
            ctx.setFillColor(Self.hex(0x2A2A2E))
            let cam = m.bezel * 0.18
            ctx.fillEllipse(in: CGRect(x: lid.midX - cam, y: lid.minY + m.bezel * 0.65 - cam, width: 2 * cam, height: 2 * cam))

        case .iPhone, .iPad:
            let b = bezel(r.size), rad = screenRadius(r.size) + b
            let body = CGPath(roundedRect: outer, cornerWidth: rad, cornerHeight: rad, transform: nil)
            withShadow { ctx.addPath(body); ctx.setFillColor(Self.hex(0x111113)); ctx.fillPath() }
            // Titanium edge.
            ctx.addPath(CGPath(roundedRect: outer.insetBy(dx: 1, dy: 1), cornerWidth: rad - 1, cornerHeight: rad - 1, transform: nil))
            ctx.setStrokeColor(Self.hex(dark ? 0x5A5B60 : 0xB9BBC0)); ctx.setLineWidth(2); ctx.strokePath()
        }
    }

    /// Drawn on top of the image (the iPhone's Dynamic Island sits in the screen).
    func drawOver(image r: CGRect, in ctx: CGContext) {
        guard style == .iPhone else { return }
        let w = r.width * 0.28, h = max(8, r.width * 0.08)
        let island = CGRect(x: r.midX - w / 2, y: r.minY + max(6, r.width * 0.03), width: w, height: h)
        ctx.addPath(CGPath(roundedRect: island, cornerWidth: h / 2, cornerHeight: h / 2, transform: nil))
        ctx.setFillColor(.black); ctx.fillPath()
    }

    private func trafficLights(x: CGFloat, midY: CGFloat, in ctx: CGContext) {
        for (n, c) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() {
            ctx.setFillColor(Self.hex(c))
            ctx.fillEllipse(in: CGRect(x: x + CGFloat(n) * 20, y: midY - 6, width: 12, height: 12))
        }
    }

    private func windowTitle(_ outer: CGRect, dark: Bool, in ctx: CGContext) {
        guard !text.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                                                    .foregroundColor: dark ? NSColor(white: 1, alpha: 0.75) : NSColor(white: 0, alpha: 0.7)]
        let s = NSAttributedString(string: text, attributes: attrs), size = s.size()
        let maxW = outer.width - 2 * 80
        guard maxW > 20 else { return }
        s.draw(with: CGRect(x: outer.midX - min(size.width, maxW) / 2, y: outer.minY + (Self.titleBar - size.height) / 2,
                            width: min(size.width, maxW), height: size.height), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    private func addressBar(_ outer: CGRect, barHeight: CGFloat, dark: Bool, in ctx: CGContext) {
        let w = min(max(outer.width * 0.5, 160), outer.width - 2 * 84)
        guard w > 40 else { return }
        let field = CGRect(x: outer.midX - w / 2, y: outer.minY + (barHeight - 26) / 2, width: w, height: 26)
        ctx.addPath(CGPath(roundedRect: field, cornerWidth: 8, cornerHeight: 8, transform: nil))
        ctx.setFillColor(Self.hex(dark ? 0x1C1C1E : 0xFFFFFF, dark ? 1 : 0.9)); ctx.fillPath()
        let shown = text.isEmpty ? "example.com" : text
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12),
                                                    .foregroundColor: dark ? NSColor(white: 1, alpha: 0.8) : NSColor(white: 0, alpha: 0.75)]
        let s = NSAttributedString(string: "🔒 " + shown, attributes: attrs), size = s.size()
        s.draw(with: CGRect(x: field.midX - min(size.width, w - 16) / 2, y: field.midY - size.height / 2,
                            width: min(size.width, w - 16), height: size.height), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    static func hex(_ v: Int, _ a: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat(v >> 16 & 255) / 255, green: CGFloat(v >> 8 & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: a)
    }
}
