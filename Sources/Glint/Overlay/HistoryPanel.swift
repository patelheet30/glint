import AppKit
import ImageIO

/// Capture History: a dark rounded panel across the top of the screen with a horizontal
/// strip of past captures. ← → select, Return / double-click restores the popup, Esc or clicking elsewhere closes.
final class HistoryPanel: NSPanel {
    private static var current: HistoryPanel?
    private let strip = HistoryStrip()

    static func toggle() {
        if let p = current { return p.dismiss() }
        let files = History.all()
        guard !files.isEmpty else { return Toast.show("No captures yet") }
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main!
        let vf = screen.visibleFrame
        let frame = CGRect(x: vf.minX + 16, y: vf.maxY - 16 - HistoryStrip.height, width: vf.width - 32, height: HistoryStrip.height)
        let p = HistoryPanel(frame: frame, files: files)
        current = p
        p.setFrame(frame.offsetBy(dx: 0, dy: 24), display: false)
        p.alphaValue = 0
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
        p.orderFrontRegardless()
        Tween.run(p, to: frame, alpha: 1, duration: 0.28, curve: Tween.backOut(1.2))
    }

    private init(frame: CGRect, files: [URL]) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false

        let bg = NSView(frame: CGRect(origin: .zero, size: frame.size))
        bg.wantsLayer = true
        bg.layer!.backgroundColor = Palette.chrome.cgColor
        bg.layer!.cornerRadius = 22
        bg.layer!.cornerCurve = .continuous
        bg.layer!.borderWidth = 1
        bg.layer!.borderColor = NSColor(white: 1, alpha: 0.08).cgColor

        let title = NSTextField(labelWithString: "Capture History")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = NSColor(white: 1, alpha: 0.55)
        title.frame = CGRect(x: 24, y: frame.height - 34, width: 200, height: 18)
        bg.addSubview(title)

        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: frame.width, height: frame.height - 40))
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.horizontalScrollElasticity = .allowed
        strip.files = files
        strip.onRestore = { [weak self] url in self?.restore(url) }
        scroll.documentView = strip
        bg.addSubview(scroll)
        contentView = bg
        makeFirstResponder(strip)
    }

    override var canBecomeKey: Bool { true }
    override func resignKey() { super.resignKey(); if HistoryPanel.current === self { dismiss() } }

    override func keyDown(with e: NSEvent) {
        switch e.keyCode {
        case 53: dismiss()                                   // Esc
        case 36, 76: strip.selectedURL.map(restore)          // Return
        case 123: strip.move(-1)                              // ←
        case 124: strip.move(1)                               // →
        default: super.keyDown(with: e)
        }
    }

    private func restore(_ url: URL) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return NSSound.beep() }
        dismiss()
        PopupManager.shared.show(img, url: url)
        log("history restored \(url.lastPathComponent)")
    }

    func dismiss() {
        guard HistoryPanel.current === self else { return }
        HistoryPanel.current = nil
        Tween.run(self, to: frame.offsetBy(dx: 0, dy: 16), alpha: 0, duration: 0.18, curve: { $0 }, alphaCurve: { $0 }) { [self] in orderOut(nil) }
    }
}

/// The thumbnails: ~180×130 on a 255pt pitch, relative time below, blue outline + "⏎ Restore" on the selection.
final class HistoryStrip: NSView {
    static let height: CGFloat = 230
    static let pitch: CGFloat = 255, thumb = CGSize(width: 220, height: 130)
    var files: [URL] = [] { didSet { setFrameSize(CGSize(width: CGFloat(files.count) * Self.pitch + 24, height: Self.height - 40)) } }
    var onRestore: ((URL) -> Void)?
    private var selected = 0
    private var thumbs: [URL: CGImage] = [:]
    private let ago = RelativeDateTimeFormatter()

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    var selectedURL: URL? { files.indices.contains(selected) ? files[selected] : nil }

    private func cell(_ i: Int) -> CGRect { CGRect(x: 24 + CGFloat(i) * Self.pitch, y: 8, width: Self.thumb.width, height: Self.thumb.height) }

    func move(_ d: Int) {
        selected = max(0, min(files.count - 1, selected + d))
        scrollToVisible(cell(selected).insetBy(dx: -24, dy: 0))
        needsDisplay = true
    }

    private func thumbnail(_ url: URL) -> CGImage? {
        if let t = thumbs[url] { return t }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let t = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                             kCGImageSourceThumbnailMaxPixelSize: 520] as CFDictionary)
        thumbs[url] = t
        return t
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        for (i, url) in files.enumerated() {
            let r = cell(i)
            guard r.insetBy(dx: -40, dy: 0).intersects(dirtyRect) else { continue }
            let box = CGPath(roundedRect: r, cornerWidth: 10, cornerHeight: 10, transform: nil)
            ctx.saveGState()
            ctx.addPath(box); ctx.clip()
            ctx.setFillColor(Palette.capsule.cgColor); ctx.fill(r)
            if let t = thumbnail(url) { // aspect fit
                let k = min(r.width / CGFloat(t.width), r.height / CGFloat(t.height))
                let s = CGSize(width: CGFloat(t.width) * k, height: CGFloat(t.height) * k)
                Render.drawImage(t, in: CGRect(x: r.midX - s.width / 2, y: r.midY - s.height / 2, width: s.width, height: s.height), ctx: ctx)
            }
            ctx.restoreGState()
            let date = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
            let label = NSAttributedString(string: ago.localizedString(for: date, relativeTo: Date()), attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor(white: 1, alpha: 0.55)])
            label.draw(at: CGPoint(x: r.minX + 2, y: r.maxY + 10))
            if i == selected {
                ctx.addPath(CGPath(roundedRect: r.insetBy(dx: -3, dy: -3), cornerWidth: 12, cornerHeight: 12, transform: nil))
                ctx.setStrokeColor(Palette.selected.cgColor); ctx.setLineWidth(3); ctx.strokePath()
                let pill = NSAttributedString(string: "⏎ Restore", attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.white])
                let ps = pill.size()
                let pr = CGRect(x: r.maxX - ps.width - 22, y: r.maxY + 6, width: ps.width + 18, height: 22)
                ctx.addPath(CGPath(roundedRect: pr, cornerWidth: 11, cornerHeight: 11, transform: nil))
                ctx.setFillColor(Palette.selected.cgColor); ctx.fillPath()
                pill.draw(at: CGPoint(x: pr.minX + 9, y: pr.midY - ps.height / 2))
            }
        }
    }

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        guard let i = files.indices.first(where: { cell($0).insetBy(dx: -4, dy: -4).union(cell($0).offsetBy(dx: 0, dy: 34)).contains(p) }) else { return }
        selected = i
        needsDisplay = true
        if e.clickCount == 2 { onRestore?(files[i]) }
    }
}
