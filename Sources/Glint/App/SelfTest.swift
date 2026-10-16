import AppKit
import Carbon.HIToolbox

/// `Glint --self-test`: asserts on the pure logic (swift-testing isn't usable without Xcode).
enum SelfTest {
    static func run() -> Never {
        var failures = 0
        func check(_ ok: Bool, _ what: String) { if !ok { failures += 1; print("FAIL: \(what)") } }

        // Retina display at origin: points → pixels.
        check(Capturer.pixelRect(CGRect(x: 10, y: 20, width: 100, height: 50),
                                 in: CGRect(x: 0, y: 0, width: 1680, height: 1050), scale: 2)
              == CGRect(x: 20, y: 40, width: 200, height: 100), "retina pixelRect")
        // Secondary display offset in global space, 1x, selection spilling off the right edge gets clipped.
        check(Capturer.pixelRect(CGRect(x: 3500, y: 0, width: 200, height: 100),
                                 in: CGRect(x: 1680, y: -30, width: 1920, height: 1080), scale: 1)
              == CGRect(x: 1820, y: 30, width: 100, height: 100), "offset display clip")
        // Fractional points round outward to whole pixels.
        check(Capturer.pixelRect(CGRect(x: 0.5, y: 0.5, width: 10, height: 10),
                                 in: CGRect(x: 0, y: 0, width: 100, height: 100), scale: 1)
              == CGRect(x: 0, y: 0, width: 11, height: 11), "integral")

        var c = DateComponents(); (c.year, c.month, c.day, c.hour, c.minute, c.second) = (2026, 10, 15, 9, 5, 7)
        let date = Calendar.current.date(from: c)!
        check(Output.fileName(for: date) == "Glint 2026-10-15 at 09.05.07.png", "fileName")

        let dir = URL(fileURLWithPath: "/tmp")
        let taken: Set<String> = ["a.png", "a (2).png"]
        check(Output.uniqueURL(in: dir, name: "a.png", exists: { taken.contains($0.lastPathComponent) }).lastPathComponent
              == "a (3).png", "uniqueURL collision")
        check(Output.uniqueURL(in: dir, name: "b.png", exists: { _ in false }).lastPathComponent == "b.png", "uniqueURL free")

        // Rotate-left / flip on a 2×1 image: [red | blue].
        let ctx = CGContext(data: nil, width: 2, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 1, y: 0, width: 1, height: 1))
        let strip = ctx.makeImage()!
        func isRed(_ img: CGImage, _ x: Int, _ y: Int) -> Bool { // x,y from top-left
            (NSBitmapImageRep(cgImage: img).colorAt(x: x, y: y)?.redComponent ?? 0) > 0.5
        }
        let rotated = Output.transformed(strip, rotateLeft: true)!
        check(rotated.width == 1 && rotated.height == 2 && !isRed(rotated, 0, 0) && isRed(rotated, 0, 1),
              "rotate left: left end goes to the bottom")
        let flipped = Output.transformed(strip, rotateLeft: false)!
        check(!isRed(flipped, 0, 0) && isRed(flipped, 1, 0), "flip horizontal")

        // Editor: counter labels, 45° snapping, background layout, flatten size.
        var doc = Doc(image: strip, scale: 1)
        check(doc.label(4) == "4", "counter 1-2-3")
        doc.counterFormat = .upper; check(doc.label(1) == "A" && doc.label(27) == "AA", "counter A-B-C")
        doc.counterFormat = .roman; check(doc.label(14) == "XIV", "counter roman")
        doc.counterFormat = .lower; check(doc.label(2) == "b", "counter a-b-c")
        let snapped = Geometry.snap45(.zero, CGPoint(x: 300, y: 80))
        check(abs(snapped.y) < 0.001 && abs(snapped.x - hypot(300, 80)) < 0.001, "snap to horizontal")
        let diag = Geometry.snap45(.zero, CGPoint(x: 300, y: 260))
        check(abs(diag.x - diag.y) < 0.001, "snap to 45°")
        check(Geometry.square(.zero, CGPoint(x: -10, y: 4)) == CGPoint(x: -10, y: 10), "square")
        doc.background = Background(fill: .color(.white), padding: 10)
        check(doc.layout.canvas == CGSize(width: 22, height: 21) && doc.layout.origin == CGPoint(x: 10, y: 10), "background layout")
        doc.background!.align = 0
        check(doc.layout.origin == .zero, "top-left alignment is flush")
        doc.background!.ratio = 2
        check(doc.layout.canvas == CGSize(width: 42, height: 21), "ratio widens canvas")
        doc.items = [Item(tool: .rect, points: [.zero, CGPoint(x: 1, y: 1)])]
        let flat = Render.flatten(doc)
        check(flat?.width == 42 && flat?.height == 21, "flatten size")

        // Shortcuts round-trip; OCR reads rendered text.
        let sc = Shortcut(keyCode: 18, carbonMods: UInt32(controlKey | shiftKey))
        check(Shortcut(string: sc.string) == sc && sc.display.hasPrefix("⌃⇧"), "shortcut round-trip")
        let txt = NSImage(size: NSSize(width: 420, height: 90), flipped: false) { r in
            NSColor.white.setFill(); r.fill()
            ("Hello CSX 2026" as NSString).draw(at: NSPoint(x: 20, y: 25), withAttributes: [.font: NSFont.systemFont(ofSize: 40, weight: .medium)])
            return true
        }.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        let read = OCR.recognize(txt)
        check(read.contains("Hello") && read.contains("2026"), "ocr reads text (got \"\(read)\")")

        // Scrolling stitch: frames of a tall page at known scroll offsets rebuild the page exactly.
        let page = NSImage(size: NSSize(width: 300, height: 1200), flipped: true) { r in
            NSColor.white.setFill(); r.fill()
            for i in 0..<60 {
                NSColor(calibratedHue: CGFloat(i % 7) / 7, saturation: 0.5, brightness: 0.9, alpha: 1).setFill()
                CGRect(x: 10 + CGFloat(i * 13 % 120), y: CGFloat(i) * 20 + 3, width: 60 + CGFloat(i * 7 % 90), height: 9).fill()
                ("Line \(i)" as NSString).draw(at: NSPoint(x: 200, y: CGFloat(i) * 20 + 2), withAttributes: [.font: NSFont.systemFont(ofSize: 12)])
            }
            return true
        }.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        let st = Stitcher()
        var results: [Stitcher.Result] = []
        for off in [0, 37, 90, 90, 260, 400] { results.append(st.add(page.cropping(to: CGRect(x: 0, y: off, width: page.width, height: 400))!)) }
        check(results == [.first, .appended(37), .appended(53), .unchanged, .appended(170), .appended(140)], "stitch offsets \(results)")
        let whole = st.image()!
        check(whole.height == 800 && Stitcher.rowHashes(whole) == Stitcher.rowHashes(page.cropping(to: CGRect(x: 0, y: 0, width: page.width, height: 800))!),
              "stitched image equals the page")
        check(st.add(page.cropping(to: CGRect(x: 0, y: 800, width: page.width, height: 400))!) == .lost, "jump too far is lost")

        print(failures == 0 ? "self-test: all passed" : "self-test: \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
