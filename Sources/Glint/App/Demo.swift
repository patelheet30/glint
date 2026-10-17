import AppKit

/// `Glint --demo` / `--demo-editor`: open a popup (or the editor) on a generated sample screenshot, for working on the
/// UI without capturing your real screen.
enum Demo {
    static func run(editor: Bool) {
        let image = sample()
        guard let url = try? History.save(image) else { return }
        let card = PopupManager.shared.show(image, url: url)
        if editor { Editor.open(card: card) }
    }

    /// `Glint --render-samples <dir>`: exports the sample through the real renderer with each frame (light and dark),
    /// headless, so features can be checked without opening windows.
    static func renderSamples(to dir: URL) -> Never {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func write(_ doc: Doc, _ name: String) {
            guard let img = Render.flatten(doc), let png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) else { return }
            try? png.write(to: dir.appending(path: name + ".png"))
        }
        let shot = sample()
        for style in DeviceFrame.Style.allCases {
            for look in [DeviceFrame.Appearance.light, .dark] {
                var doc = Doc(image: shot, scale: 2)
                var bg = Background(fill: .gradient(3)); bg.padding = 64
                bg.frame = DeviceFrame(style: style, appearance: look, text: style == .browser ? "glint.app/features" : "Quarterly overview")
                doc.background = bg
                write(doc, "frame-\(style)-\(look)")
            }
        }
        var phone = Doc(image: sample(width: 390, height: 844), scale: 2)
        var bg = Background(fill: .gradient(7)); bg.frame = DeviceFrame(style: .iPhone); phone.background = bg
        write(phone, "frame-iPhone-portrait")
        print("wrote samples to \(dir.path)")
        exit(0)
    }

    /// A light "app window" with a sidebar, title, colored cards and text rows.
    static func sample(width: Int = 1280, height: Int = 800) -> CGImage {
        NSImage(size: NSSize(width: width, height: height), flipped: true) { r in
            NSColor(white: 0.97, alpha: 1).setFill(); r.fill()
            NSColor(white: 0.92, alpha: 1).setFill(); CGRect(x: 0, y: 0, width: 240, height: r.height).fill()
            for (i, c) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
                c.setFill(); NSBezierPath(ovalIn: CGRect(x: 18 + i * 20, y: 18, width: 12, height: 12)).fill()
            }
            let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor(white: 0.35, alpha: 1)]
            for i in 0..<9 { ("Sidebar item \(i + 1)" as NSString).draw(at: CGPoint(x: 28, y: 64 + i * 34), withAttributes: body) }
            ("Quarterly overview" as NSString).draw(at: CGPoint(x: 280, y: 48), withAttributes: [.font: NSFont.systemFont(ofSize: 30, weight: .bold), .foregroundColor: NSColor(white: 0.12, alpha: 1)])
            for (i, c) in [NSColor.systemBlue, .systemPurple, .systemOrange].enumerated() {
                let card = CGRect(x: 280 + i * 320, y: 110, width: 296, height: 170)
                c.withAlphaComponent(0.85).setFill(); NSBezierPath(roundedRect: card, xRadius: 14, yRadius: 14).fill()
                ("\(42 + i * 17)%" as NSString).draw(at: CGPoint(x: card.minX + 20, y: card.minY + 20), withAttributes: [.font: NSFont.systemFont(ofSize: 40, weight: .semibold), .foregroundColor: NSColor.white])
            }
            for i in 0..<10 {
                let y = 320 + i * 44
                NSColor(white: i % 2 == 0 ? 1 : 0.95, alpha: 1).setFill(); CGRect(x: 280, y: y, width: 936, height: 40).fill()
                ("Row \(i + 1) — The quick brown fox jumps over the lazy dog" as NSString).draw(at: CGPoint(x: 296, y: y + 10), withAttributes: body)
            }
            return true
        }.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    }
}
