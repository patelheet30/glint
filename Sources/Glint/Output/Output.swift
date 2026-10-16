import AppKit

enum Output {
    static func png(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    /// File and image: the file URL (when there is one) plus PNG data, so both file and image targets accept a paste.
    static func copy(_ image: CGImage, file: URL? = nil) {
        guard let data = png(image) else { return }
        let item = NSPasteboardItem()
        if let file { item.setString(file.absoluteString, forType: .fileURL) }
        item.setData(data, forType: .png)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([item])
    }

    /// 90° counter-clockwise, or a horizontal mirror.
    static func transformed(_ image: CGImage, rotateLeft: Bool) -> CGImage? {
        let (w, h) = (CGFloat(image.width), CGFloat(image.height))
        let size = rotateLeft ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
        guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        if rotateLeft { ctx.translateBy(x: size.width, y: 0); ctx.rotate(by: .pi / 2) }
        else { ctx.translateBy(x: w, y: 0); ctx.scaleBy(x: -1, y: 1) }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// Saves to `dir` as "Glint YYYY-MM-DD at HH.MM.SS.png" and returns the file URL.
    @discardableResult
    static func save(_ image: CGImage, to dir: URL = Settings.exportDirectory, date: Date = Date()) throws -> URL {
        guard let data = png(image) else { throw CocoaError(.fileWriteUnknown) }
        let url = uniqueURL(in: dir, name: fileName(for: date), exists: { FileManager.default.fileExists(atPath: $0.path) })
        try data.write(to: url)
        return url
    }

    /// Save panel (activates the app so the panel can take focus). Returns true if saved.
    static func saveAs(_ image: CGImage, name: String) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [.png]
        panel.directoryURL = Settings.exportDirectory
        guard panel.runModal() == .OK, let dest = panel.url, let data = png(image) else { return false }
        do { try data.write(to: dest); return true } catch { log("save as failed: \(error)"); return false }
    }

    static func fileName(for date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Glint \(f.string(from: date)).png"
    }

    /// "name.png", then "name (2).png", "name (3).png", … until `exists` is false.
    static func uniqueURL(in dir: URL, name: String, exists: (URL) -> Bool) -> URL {
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var url = dir.appendingPathComponent(name), n = 2
        while exists(url) { url = dir.appendingPathComponent("\(base) (\(n)).\(ext)"); n += 1 }
        return url
    }

    private static let shutter = NSSound(contentsOfFile:
        "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif",
        byReference: true)

    static func playShutter() { shutter?.play() }
}
