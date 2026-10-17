import AppKit

/// Title + subtitle laid out with the (framed) screenshot at an exact social/README size (background tool → Card).
struct ShareCard: Equatable {
    enum Preset: Int, CaseIterable {
        case x, linkedIn, openGraph, square, story, banner

        var title: String { ["X / Twitter", "LinkedIn", "Open Graph", "Square", "Story", "README banner"][rawValue] }
        var pixels: CGSize {
            [CGSize(width: 1600, height: 900), CGSize(width: 1200, height: 627), CGSize(width: 1200, height: 630),
             CGSize(width: 1080, height: 1080), CGSize(width: 1080, height: 1920), CGSize(width: 1280, height: 640)][rawValue]
        }
        var label: String { "\(title)  \(Int(pixels.width)) × \(Int(pixels.height))" }
    }
    enum Position: Int, CaseIterable { case above, below, beside }
    enum TextStyle: Int, CaseIterable {
        case bold, editorial, mono
        var title: String { ["Bold", "Serif", "Mono"][rawValue] }
    }

    var title = ""
    var subtitle = ""
    var preset = Preset.x
    var position = Position.above
    var style = TextStyle.bold

    var hasText: Bool { !title.isEmpty || !subtitle.isEmpty }

    // MARK: text

    /// Font sizes scale with the content, so the text reads the same at every export size.
    func attributed(reference w: CGFloat, color: NSColor) -> NSAttributedString {
        let size = max(18, w * 0.05)
        let titleFont: NSFont, subFont: NSFont
        switch style {
        case .bold:
            titleFont = .systemFont(ofSize: size, weight: .heavy)
            subFont = .systemFont(ofSize: size * 0.5, weight: .medium)
        case .editorial:
            func serif(_ f: NSFont) -> NSFont { f.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: f.pointSize) } ?? f }
            titleFont = serif(.systemFont(ofSize: size, weight: .bold))
            subFont = serif(.systemFont(ofSize: size * 0.5))
        case .mono:
            titleFont = .monospacedSystemFont(ofSize: size * 0.9, weight: .bold)
            subFont = .monospacedSystemFont(ofSize: size * 0.45, weight: .regular)
        }
        let para = NSMutableParagraphStyle()
        para.alignment = position == .beside ? .left : .center
        para.lineBreakMode = .byWordWrapping
        let out = NSMutableAttributedString()
        if !title.isEmpty {
            out.append(NSAttributedString(string: title, attributes: [.font: titleFont, .foregroundColor: color, .paragraphStyle: para]))
        }
        if !subtitle.isEmpty {
            let sub = NSMutableParagraphStyle(); sub.setParagraphStyle(para); sub.paragraphSpacingBefore = size * 0.35
            out.append(NSAttributedString(string: (title.isEmpty ? "" : "\n") + subtitle,
                                          attributes: [.font: subFont, .foregroundColor: color.withAlphaComponent(0.78), .paragraphStyle: sub]))
        }
        return out
    }

    static func measure(_ s: NSAttributedString, width: CGFloat) -> CGSize {
        let r = s.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading])
        return CGSize(width: ceil(r.width), height: ceil(r.height))
    }

    /// White on dark fills, near-black on light ones.
    static func textColor(for fill: Background.Fill) -> NSColor {
        let light: Bool
        switch fill {
        case .color(let c): light = c.alphaComponent < 0.5 || c.isLight
        case .gradient(let i):
            let hexes = Render.gradients[i % Render.gradients.count].0
            light = hexes.map { Palette.hex($0) }.map(lum).reduce(0, +) / CGFloat(hexes.count) > 0.62
        case .image(let img): light = lum(NSColor(cgColor: Render.edgeColor(img)) ?? .black) > 0.62
        }
        return light ? NSColor(white: 0.08, alpha: 1) : .white
    }

    private static func lum(_ c: NSColor) -> CGFloat {
        guard let s = c.usingColorSpace(.sRGB) else { return 0 }
        return 0.299 * s.redComponent + 0.587 * s.greenComponent + 0.114 * s.blueComponent
    }
}
