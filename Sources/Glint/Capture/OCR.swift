import AppKit
import Vision

/// Capture Text: Vision text recognition, copied as plain text.
enum OCR {
    static func recognize(_ image: CGImage, lineBreaks: Bool = Settings.ocrLineBreaks) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        try? VNImageRequestHandler(cgImage: image).perform([request])
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: lineBreaks ? "\n" : " ")
    }

    /// Recognize, copy, and confirm with a toast.
    static func copyText(from image: CGImage) {
        Task.detached(priority: .userInitiated) {
            let text = recognize(image)
            await MainActor.run {
                guard !text.isEmpty else { return Toast.show("No text found") }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                log("ocr copied \(text.count) chars")
                Toast.show("Text has been copied")
            }
        }
    }
}

/// A short HUD near the bottom of the active screen ("Text has been copied").
enum Toast {
    private static var panel: NSPanel?

    static func show(_ message: String) {
        panel?.orderOut(nil)
        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.textColor = .white
        label.sizeToFit()
        let size = CGSize(width: label.frame.width + 44, height: 40)
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main!
        let vf = screen.visibleFrame
        let p = NSPanel(contentRect: CGRect(x: vf.midX - size.width / 2, y: vf.minY + 120, width: size.width, height: size.height),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .statusBar
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let v = NSView(frame: CGRect(origin: .zero, size: size))
        v.wantsLayer = true
        v.layer!.backgroundColor = Palette.capsule.withAlphaComponent(0.97).cgColor
        v.layer!.borderWidth = 0.5
        v.layer!.borderColor = Palette.panelBorder.cgColor
        v.layer!.cornerRadius = size.height / 2
        label.frame.origin = CGPoint(x: 22, y: (size.height - label.frame.height) / 2)
        v.addSubview(label)
        p.contentView = v
        p.alphaValue = 0
        p.orderFrontRegardless()
        panel = p
        NSAnimationContext.runAnimationGroup { $0.duration = 0.2; p.animator().alphaValue = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            guard panel === p else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; p.animator().alphaValue = 0 }) { p.orderOut(nil) }
        }
    }
}
