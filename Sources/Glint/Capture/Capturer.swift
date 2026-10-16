import AppKit
import ScreenCaptureKit

enum Capturer {
    struct NoDisplay: Error {}

    /// Native interactive modes, run through Apple's `screencapture` (its selection UI, window picker and timer).
    enum Mode {
        case area, window, selfTimer
        var args: [String] {
            switch self {
            case .area: ["-i"]
            case .window: ["-i", "-W"]
            case .selfTimer: ["-i", "-T\(Settings.timerSeconds)"]
            }
        }
    }

    /// Returns nil if the user cancelled. `rect` is the selection in global top-left points.
    static func interactive(_ mode: Mode) async -> (image: CGImage, rect: CGRect?)? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("csx-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = mode.args + ["-x", "-r", url.path]
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            p.terminationHandler = { _ in c.resume() }
            do { try p.run() } catch { c.resume() }
        }

        let opts = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, opts) else { return nil }
        return (image, globalRect(of: url))
    }

    /// Display under the mouse, full resolution.
    static func captureDisplayUnderCursor() async throws -> CGImage {
        try await captureDisplay(at: CGEvent(source: nil)?.location ?? .zero)
    }

    /// Re-captures a global rect (top-left points) from the display containing its center.
    static func capture(globalRect r: CGRect) async throws -> CGImage {
        let id = try display(at: CGPoint(x: r.midX, y: r.midY))
        let full = try await captureDisplay(id)
        let bounds = CGDisplayBounds(id)
        guard let crop = full.cropping(to: pixelRect(r, in: bounds, scale: CGFloat(full.width) / bounds.width))
        else { throw NoDisplay() }
        return crop
    }

    /// Global top-left point rect → pixel rect inside that display's image, clipped to the display.
    static func pixelRect(_ r: CGRect, in bounds: CGRect, scale: CGFloat) -> CGRect {
        r.intersection(bounds)
            .offsetBy(dx: -bounds.minX, dy: -bounds.minY)
            .applying(CGAffineTransform(scaleX: scale, y: scale))
            .integral
    }

    private static func captureDisplay(at point: CGPoint) async throws -> CGImage {
        try await captureDisplay(display(at: point))
    }

    private static func display(at point: CGPoint) throws -> CGDirectDisplayID {
        var id = CGDirectDisplayID(), count: UInt32 = 0
        guard CGGetDisplaysWithPoint(point, 1, &id, &count) == .success, count > 0 else { throw NoDisplay() }
        return id
    }

    private static func captureDisplay(_ id: CGDirectDisplayID) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == id }),
              let mode = CGDisplayCopyDisplayMode(id) else { throw NoDisplay() }
        let config = SCStreamConfiguration()
        config.width = mode.pixelWidth
        config.height = mode.pixelHeight
        config.showsCursor = Settings.showCursor
        return try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(display: display, excludingWindows: []), configuration: config)
    }

    /// Repeated captures of one global rect (scrolling capture). Shareable content is fetched once, and this app's
    /// windows are excluded so the pills drawn over the selection never end up in the frames.
    static func regionGrabber(_ r: CGRect) async throws -> () async throws -> CGImage {
        let id = try display(at: CGPoint(x: r.midX, y: r.midY))
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == id }),
              let mode = CGDisplayCopyDisplayMode(id) else { throw NoDisplay() }
        let bounds = CGDisplayBounds(id)
        let scale = CGFloat(mode.pixelWidth) / bounds.width
        let local = r.intersection(bounds).offsetBy(dx: -bounds.minX, dy: -bounds.minY)
        let config = SCStreamConfiguration()
        config.sourceRect = local
        config.width = Int((local.width * scale).rounded())
        config.height = Int((local.height * scale).rounded())
        config.showsCursor = false
        let me = content.applications.filter { $0.processID == getpid() }
        let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
        return { try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) }
    }

    /// `screencapture` tags its files with the captured rect (global, top-left points).
    private static func globalRect(of url: URL) -> CGRect? {
        let name = "com.apple.metadata:kMDItemScreenCaptureGlobalRect"
        let size = getxattr(url.path, name, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var data = Data(count: size)
        _ = data.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, size, 0, 0) }
        guard let v = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [Double], v.count == 4
        else { return nil }
        return CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
    }
}
