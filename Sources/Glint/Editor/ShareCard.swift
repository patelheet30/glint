import AppKit

/// The screenshot as the attached image of a social post (X, LinkedIn, Instagram, Bluesky), with your avatar,
/// name, handle and text. Drawn from each platform's proportions in light or dark, without logos or badges.
struct ShareCard: Equatable {
    enum Platform: Int, CaseIterable {
        case x, linkedIn, instagram, bluesky

        var title: String { ["X / Twitter", "LinkedIn", "Instagram", "Bluesky"][rawValue] }
        var handlePlaceholder: String { ["@handle", "Headline (e.g. Founder at Glint)", "username", "@handle.bsky.social"][rawValue] }
        /// Width of the real post the proportions come from (points).
        var reference: CGFloat { [600, 555, 470, 600][rawValue] }
        /// Media runs edge to edge (no side padding, no rounding).
        var fullBleed: Bool { self == .linkedIn || self == .instagram }
    }
    enum Theme: Int, CaseIterable { case light, dark }
    enum Preset: Int, CaseIterable {
        case x, linkedIn, openGraph, square, story, banner

        var title: String { ["X / Twitter", "LinkedIn", "Open Graph", "Square", "Story", "README banner"][rawValue] }
        var pixels: CGSize {
            [CGSize(width: 1600, height: 900), CGSize(width: 1200, height: 627), CGSize(width: 1200, height: 630),
             CGSize(width: 1080, height: 1080), CGSize(width: 1080, height: 1920), CGSize(width: 1280, height: 640)][rawValue]
        }
        var label: String { "\(title)  \(Int(pixels.width)) × \(Int(pixels.height))" }
    }

    var platform = Platform.x
    var theme = Theme.light
    var name = ""
    var handle = ""
    var text = ""
    var avatar: CGImage? = nil
    var showCounts = false
    var preset: Preset? = nil   // nil = fit the post; otherwise export at exactly this size
    var date = Date()

    static func == (a: ShareCard, b: ShareCard) -> Bool {
        a.platform == b.platform && a.theme == b.theme && a.name == b.name && a.handle == b.handle && a.text == b.text
            && a.avatar === b.avatar && a.showCounts == b.showCounts && a.preset == b.preset && a.date == b.date
    }

    // MARK: colours

    struct Colors { var bg, text, muted, line, accent: NSColor }

    var colors: Colors {
        let dark = theme == .dark
        func c(_ v: Int, _ a: CGFloat = 1) -> NSColor { Palette.hex(v).withAlphaComponent(a) }
        switch platform {
        case .x: return dark ? Colors(bg: c(0x000000), text: c(0xE7E9EA), muted: c(0x71767B), line: c(0x2F3336), accent: c(0x1D9BF0))
                             : Colors(bg: c(0xFFFFFF), text: c(0x0F1419), muted: c(0x536471), line: c(0xEFF3F4), accent: c(0x1D9BF0))
        case .linkedIn: return dark ? Colors(bg: c(0x1B1F23), text: c(0xFFFFFF, 0.9), muted: c(0xFFFFFF, 0.6), line: c(0x38434F), accent: c(0x71B7FB))
                                    : Colors(bg: c(0xFFFFFF), text: c(0x000000, 0.9), muted: c(0x000000, 0.6), line: c(0xE8E8E8), accent: c(0x0A66C2))
        case .instagram: return dark ? Colors(bg: c(0x000000), text: c(0xF5F5F5), muted: c(0xA8A8A8), line: c(0x262626), accent: c(0x0095F6))
                                     : Colors(bg: c(0xFFFFFF), text: c(0x000000), muted: c(0x737373), line: c(0xDBDBDB), accent: c(0x0095F6))
        case .bluesky: return dark ? Colors(bg: c(0x161E27), text: c(0xF1F3F5), muted: c(0x8B98A5), line: c(0x2E4052), accent: c(0x208BFE))
                                   : Colors(bg: c(0xFFFFFF), text: c(0x0B0F14), muted: c(0x6F869F), line: c(0xE2E8EE), accent: c(0x0085FF))
        }
    }

    // MARK: layout

    /// Everything in the post, relative to its top-left corner. `media` is where the (framed) screenshot goes.
    struct Layout {
        var size: CGSize
        var media: CGRect
        var u: CGFloat              // one point of the reference post
        var avatar: CGRect
        var header: CGPoint         // where the name line starts
        var text: CGRect
        var below: CGFloat          // y where everything under the media starts
    }

    func layout(content: CGSize) -> Layout {
        let p = platform
        let u = p.fullBleed ? content.width / p.reference : content.width / (p.reference - 32)
        let pad = 16 * u, w = p.fullBleed ? content.width : content.width + 2 * pad
        var y = p == .instagram ? 0 : pad
        let avatarSide: CGFloat = [40, 48, 32, 42][p.rawValue] * u
        let avatar: CGRect, header: CGPoint
        if p == .instagram {
            avatar = CGRect(x: 12 * u, y: (54 * u - avatarSide) / 2, width: avatarSide, height: avatarSide)
            header = CGPoint(x: avatar.maxX + 10 * u, y: avatar.midY)
            y = 54 * u
        } else {
            avatar = CGRect(x: pad, y: y, width: avatarSide, height: avatarSide)
            header = CGPoint(x: avatar.maxX + 12 * u, y: avatar.minY)
            y = avatar.maxY + 12 * u
        }
        var text = CGRect.zero
        if p != .instagram, !self.text.isEmpty { // Instagram's caption sits under the photo
            let s = body(u: u)
            let h = Self.height(s, width: w - 2 * pad)
            text = CGRect(x: pad, y: y, width: w - 2 * pad, height: h)
            y = text.maxY + 12 * u
        }
        let media = CGRect(x: p.fullBleed ? 0 : pad, y: y, width: content.width, height: content.height)
        y = media.maxY
        let below = y
        switch p {
        case .x, .bluesky:
            y += 16 * u + 20 * u + 16 * u + 48 * u   // timestamp, divider, action row
        case .linkedIn:
            y += (showCounts ? 34 * u : 8 * u) + 52 * u
        case .instagram:
            y += 46 * u + (showCounts ? 22 * u : 0)
            if !self.text.isEmpty { y += Self.height(caption(u: u), width: w - 24 * u) + 6 * u }
            y += 22 * u + 12 * u
        }
        return Layout(size: CGSize(width: w, height: y), media: media, u: u, avatar: avatar, header: header, text: text, below: below)
    }

    static func height(_ s: NSAttributedString, width: CGFloat) -> CGFloat {
        ceil(s.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
    }

    private func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont { .systemFont(ofSize: size, weight: weight) }

    private func body(u: CGFloat) -> NSAttributedString {
        let size: CGFloat = [17, 14, 14, 16][platform.rawValue] * u
        let para = NSMutableParagraphStyle(); para.lineSpacing = size * 0.2
        return NSAttributedString(string: text, attributes: [.font: font(size), .foregroundColor: colors.text, .paragraphStyle: para])
    }

    private func caption(u: CGFloat) -> NSAttributedString {
        let s = NSMutableAttributedString(string: displayHandle + " ", attributes: [.font: font(14 * u, .semibold), .foregroundColor: colors.text])
        s.append(NSAttributedString(string: text, attributes: [.font: font(14 * u), .foregroundColor: colors.text]))
        return s
    }

    private var displayName: String { name.isEmpty ? "Your Name" : name }
    private var displayHandle: String {
        let h = handle.trimmingCharacters(in: .whitespaces)
        switch platform {
        case .x, .bluesky: return h.isEmpty ? "@yourhandle" : (h.hasPrefix("@") ? h : "@" + h)
        case .instagram: return h.isEmpty ? "yourname" : (h.hasPrefix("@") ? String(h.dropFirst()) : h)
        case .linkedIn: return h
        }
    }

    // MARK: drawing (flipped context, `origin` = the post's top-left on the canvas)

    /// The post around the media: card, header, text, and everything under the photo. `shadow` is 0–100.
    func draw(at origin: CGPoint, content: CGSize, shadow: CGFloat, in ctx: CGContext) {
        let l = layout(content: content), u = l.u, col = colors
        let card = CGRect(origin: origin, size: l.size)
        let cardPath = CGPath(roundedRect: card, cornerWidth: 16 * u, cornerHeight: 16 * u, transform: nil)
        ctx.saveGState()
        if shadow > 0 {
            ctx.setShadow(offset: CGSize(width: 0, height: shadow * 0.25), blur: shadow * 0.9, color: CGColor(gray: 0, alpha: min(0.5, 0.15 + shadow / 250)))
        }
        ctx.addPath(cardPath); ctx.setFillColor(col.bg.cgColor); ctx.fillPath()
        ctx.restoreGState()
        if theme == .light { ctx.addPath(cardPath); ctx.setStrokeColor(col.line.cgColor); ctx.setLineWidth(max(1, u)); ctx.strokePath() }

        ctx.saveGState()
        ctx.translateBy(x: origin.x, y: origin.y)
        drawAvatar(l.avatar, ring: platform == .instagram, in: ctx)
        drawHeader(l, in: ctx)
        if l.text != .zero { body(u: u).draw(with: l.text, options: [.usesLineFragmentOrigin, .usesFontLeading]) }
        drawBelow(l, in: ctx)
        ctx.restoreGState()
    }

    /// Clip for the screenshot inside the post (X and Bluesky round their media; LinkedIn and Instagram run it edge to edge).
    func mediaPath(_ r: CGRect, u: CGFloat) -> CGPath {
        let rad: CGFloat = platform == .x ? 16 * u : platform == .bluesky ? 12 * u : 0
        return CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil)
    }

    /// Hairline around rounded media (drawn over the screenshot).
    func drawMediaBorder(_ r: CGRect, u: CGFloat, in ctx: CGContext) {
        guard !platform.fullBleed else { return }
        ctx.addPath(mediaPath(r, u: u)); ctx.setStrokeColor(colors.line.cgColor); ctx.setLineWidth(max(1, u)); ctx.strokePath()
    }

    private func drawAvatar(_ r: CGRect, ring: Bool, in ctx: CGContext) {
        var r = r
        if ring { // Instagram's story ring
            let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [0xFEDA75, 0xFA7E1E, 0xD62976, 0x962FBF].map { Palette.hex($0).cgColor } as CFArray, locations: nil)!
            ctx.saveGState(); ctx.addEllipse(in: r); ctx.clip()
            ctx.drawLinearGradient(g, start: CGPoint(x: r.minX, y: r.maxY), end: CGPoint(x: r.maxX, y: r.minY), options: [])
            ctx.restoreGState()
            ctx.setFillColor(colors.bg.cgColor); ctx.fillEllipse(in: r.insetBy(dx: r.width * 0.07, dy: r.width * 0.07))
            r = r.insetBy(dx: r.width * 0.12, dy: r.width * 0.12)
        }
        ctx.saveGState()
        ctx.addEllipse(in: r); ctx.clip()
        if let avatar {
            let k = max(r.width / CGFloat(avatar.width), r.height / CGFloat(avatar.height))
            let s = CGSize(width: CGFloat(avatar.width) * k, height: CGFloat(avatar.height) * k)
            Render.drawImage(avatar, in: CGRect(x: r.midX - s.width / 2, y: r.midY - s.height / 2, width: s.width, height: s.height), ctx: ctx)
        } else { // initials on a colour picked from the name
            let palette = [0x1D9BF0, 0x7856FF, 0xF91880, 0x00BA7C, 0xFF7A00, 0x0A66C2]
            ctx.setFillColor(Palette.hex(palette[displayName.unicodeScalars.reduce(0) { $0 + Int($1.value) } % palette.count]).cgColor); ctx.fill(r)
            let initials = displayName.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
            let s = NSAttributedString(string: initials, attributes: [.font: font(r.height * 0.4, .semibold), .foregroundColor: NSColor.white])
            let sz = s.size()
            s.draw(at: CGPoint(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2))
        }
        ctx.restoreGState()
    }

    private func drawHeader(_ l: Layout, in ctx: CGContext) {
        let u = l.u, col = colors
        let nameFont = font([15, 14, 14, 15][platform.rawValue] * u, platform == .x ? .bold : .semibold)
        let small = font([15, 12, 12, 14][platform.rawValue] * u)
        let w = l.size.width - l.header.x - 16 * u
        func line(_ s: NSAttributedString, _ y: CGFloat) {
            s.draw(with: CGRect(x: l.header.x, y: y, width: w, height: s.size().height), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
        switch platform {
        case .x, .bluesky:
            line(NSAttributedString(string: displayName, attributes: [.font: nameFont, .foregroundColor: col.text]), l.header.y + 1 * u)
            line(NSAttributedString(string: displayHandle, attributes: [.font: small, .foregroundColor: col.muted]), l.header.y + 21 * u)
        case .linkedIn:
            line(NSAttributedString(string: displayName, attributes: [.font: nameFont, .foregroundColor: col.text]), l.header.y)
            if !displayHandle.isEmpty { line(NSAttributedString(string: displayHandle, attributes: [.font: small, .foregroundColor: col.muted]), l.header.y + 17 * u) }
            line(NSAttributedString(string: "1h · 🌐", attributes: [.font: small, .foregroundColor: col.muted]), l.header.y + (displayHandle.isEmpty ? 17 : 32) * u)
        case .instagram:
            let s = NSAttributedString(string: displayHandle, attributes: [.font: nameFont, .foregroundColor: col.text])
            line(s, l.header.y - s.size().height / 2)
            glyph("ellipsis", at: CGPoint(x: l.size.width - 32 * u, y: l.header.y - 8 * u), size: 18 * u, color: col.text, in: ctx)
        }
    }

    private func drawBelow(_ l: Layout, in ctx: CGContext) {
        let u = l.u, col = colors, w = l.size.width, pad = 16 * u
        var y = l.below
        func divider(_ at: CGFloat, inset: CGFloat) {
            ctx.setFillColor(col.line.cgColor); ctx.fill(CGRect(x: inset, y: at, width: w - 2 * inset, height: max(1, u)))
        }
        switch platform {
        case .x, .bluesky:
            y += 16 * u
            let f = DateFormatter(); f.dateFormat = platform == .x ? "h:mm a · MMM d, yyyy" : "MMM d, yyyy 'at' h:mm a"
            NSAttributedString(string: f.string(from: date), attributes: [.font: font(15 * u), .foregroundColor: col.muted]).draw(at: CGPoint(x: pad, y: y))
            y += 20 * u + 16 * u
            divider(y, inset: pad)
            let icons = platform == .x ? ["bubble.left", "arrow.2.squarepath", "heart", "chart.bar.xaxis", "bookmark"]
                                       : ["bubble.left", "arrow.2.squarepath", "heart", "ellipsis"]
            let counts = ["24", "128", "1.2K", "48K", ""]
            let slot = (w - 2 * pad) / CGFloat(icons.count)
            for (i, name) in icons.enumerated() {
                let x = pad + CGFloat(i) * slot
                glyph(name, at: CGPoint(x: x, y: y + 14 * u), size: 19 * u, color: col.muted, in: ctx)
                if showCounts, !counts[i].isEmpty, i < icons.count - 1 {
                    NSAttributedString(string: counts[i], attributes: [.font: font(13 * u), .foregroundColor: col.muted])
                        .draw(at: CGPoint(x: x + 25 * u, y: y + 15 * u))
                }
            }
        case .linkedIn:
            if showCounts {
                y += 10 * u
                NSAttributedString(string: "👍❤️👏 128 · 14 comments", attributes: [.font: font(12 * u), .foregroundColor: col.muted]).draw(at: CGPoint(x: pad, y: y))
                y += 24 * u
            } else { y += 8 * u }
            divider(y, inset: pad)
            let actions: [(String, String)] = [("hand.thumbsup", "Like"), ("text.bubble", "Comment"), ("arrow.2.squarepath", "Repost"), ("paperplane", "Send")]
            let slot = (w - 2 * pad) / 4
            for (i, (icon, label)) in actions.enumerated() {
                let s = NSAttributedString(string: label, attributes: [.font: font(14 * u, .semibold), .foregroundColor: col.muted])
                let total = 20 * u + 6 * u + s.size().width, x = pad + CGFloat(i) * slot + (slot - total) / 2
                glyph(icon, at: CGPoint(x: x, y: y + 16 * u), size: 20 * u, color: col.muted, in: ctx)
                s.draw(at: CGPoint(x: x + 26 * u, y: y + 17 * u))
            }
        case .instagram:
            y += 11 * u
            for (i, icon) in ["heart", "bubble.right", "paperplane"].enumerated() {
                glyph(icon, at: CGPoint(x: 12 * u + CGFloat(i) * 40 * u, y: y), size: 24 * u, color: col.text, in: ctx)
            }
            glyph("bookmark", at: CGPoint(x: w - 36 * u, y: y), size: 24 * u, color: col.text, in: ctx)
            y += 35 * u
            if showCounts {
                NSAttributedString(string: "1,284 likes", attributes: [.font: font(14 * u, .semibold), .foregroundColor: col.text]).draw(at: CGPoint(x: 12 * u, y: y))
                y += 22 * u
            }
            if !text.isEmpty {
                let s = caption(u: u), h = Self.height(s, width: w - 24 * u)
                s.draw(with: CGRect(x: 12 * u, y: y, width: w - 24 * u, height: h), options: [.usesLineFragmentOrigin, .usesFontLeading])
                y += h + 6 * u
            }
            NSAttributedString(string: "JUST NOW", attributes: [.font: font(10 * u, .medium), .foregroundColor: col.muted, .kern: 0.3 * u])
                .draw(at: CGPoint(x: 12 * u, y: y + 4 * u))
        }
    }

    /// An SF Symbol, tinted, with its top-left at `p`.
    private func glyph(_ name: String, at p: CGPoint, size: CGFloat, color: NSColor, in ctx: CGContext) {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .regular)) else { return }
        let tinted = NSImage(size: base.size, flipped: false) { r in
            base.draw(in: r); color.set(); r.fill(using: .sourceAtop); return true
        }
        let k = size / max(base.size.width, base.size.height, 1) // fit in a size × size box (wide glyphs like ••• stay small)
        let w = base.size.width * k, h = base.size.height * k
        tinted.draw(in: CGRect(x: p.x + (size - w) / 2, y: p.y + (size - h) / 2, width: w, height: h),
                    from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    // MARK: remembered identity

    /// Name, handle and avatar carry over to the next card.
    static func remembered() -> ShareCard {
        var c = ShareCard()
        let d = UserDefaults.standard
        c.name = d.string(forKey: "card.name") ?? ""
        c.handle = d.string(forKey: "card.handle") ?? ""
        c.platform = Platform(rawValue: d.integer(forKey: "card.platform")) ?? .x
        c.theme = Theme(rawValue: d.integer(forKey: "card.theme")) ?? .light
        if let data = d.data(forKey: "card.avatar"), let src = CGImageSourceCreateWithData(data as CFData, nil) {
            c.avatar = CGImageSourceCreateImageAtIndex(src, 0, nil)
        }
        return c
    }

    func remember() {
        let d = UserDefaults.standard
        d.set(name, forKey: "card.name")
        d.set(handle, forKey: "card.handle")
        d.set(platform.rawValue, forKey: "card.platform")
        d.set(theme.rawValue, forKey: "card.theme")
        if let avatar, let png = NSBitmapImageRep(cgImage: avatar).representation(using: .png, properties: [:]) { d.set(png, forKey: "card.avatar") }
        else { d.removeObject(forKey: "card.avatar") }
    }
}
