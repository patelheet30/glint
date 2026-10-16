// Renders Glint's app icon (the menu bar mark on a macOS-style rounded square) into AppIcon.icns.
// Usage: swiftc -O Resources/make-icon.swift -o /tmp/make-icon && /tmp/make-icon Resources/AppIcon.icns
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])

func hex(_ v: Int, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(v >> 16 & 255) / 255, green: CGFloat(v >> 8 & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: a)
}

/// Apple's icon grid: an 824pt body centred on a 1024 canvas with ~185pt continuous corners.
func body(_ r: CGRect) -> CGPath {
    let p = CGMutablePath()
    p.addRoundedRect(in: r, cornerWidth: 185, cornerHeight: 185)
    return p
}

func render(_ px: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: CGFloat(px) / 1024, y: CGFloat(px) / 1024)
    ctx.translateBy(x: 0, y: 1024); ctx.scaleBy(x: 1, y: -1) // top-left origin, like the app's 18-unit icon grid
    let rect = CGRect(x: 100, y: 100, width: 824, height: 824), shape = body(rect)

    // Drop shadow, then a blue → violet body with a soft top highlight.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: hex(0x000000, 0.35))
    ctx.addPath(shape); ctx.setFillColor(hex(0x3D6BFF)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    let bg = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [hex(0x3B8CFF), hex(0x4F5BFA), hex(0x7A3FF2)] as CFArray, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 280, y: 100), end: CGPoint(x: 744, y: 924), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [hex(0xFFFFFF, 0.28), hex(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 330, y: 170), startRadius: 0, endCenter: CGPoint(x: 330, y: 170), endRadius: 620, options: [])
    ctx.restoreGState()
    // Hairline inner edge so it holds up on dark Docks.
    ctx.addPath(shape); ctx.setStrokeColor(hex(0xFFFFFF, 0.18)); ctx.setLineWidth(3); ctx.strokePath()

    // The mark: same geometry as the menu bar icon (18-unit grid), scaled into a 520pt box.
    let k: CGFloat = 520 / 18
    ctx.saveGState()
    ctx.translateBy(x: 512 - 9 * k, y: 512 - 9 * k)
    ctx.scaleBy(x: k, y: k)
    ctx.setShadow(offset: CGSize(width: 0, height: 0.4), blur: 0.9, color: hex(0x1A1060, 0.35))
    ctx.setStrokeColor(.white); ctx.setFillColor(.white)
    ctx.setLineWidth(1.9); ctx.setLineCap(.round); ctx.setLineJoin(.round)
    let corners: [[CGPoint]] = [[CGPoint(x: 1.8, y: 6.4), CGPoint(x: 1.8, y: 1.8), CGPoint(x: 6.4, y: 1.8)],
                                [CGPoint(x: 11.6, y: 1.8), CGPoint(x: 16.2, y: 1.8), CGPoint(x: 16.2, y: 6.4)],
                                [CGPoint(x: 16.2, y: 11.6), CGPoint(x: 16.2, y: 16.2), CGPoint(x: 11.6, y: 16.2)],
                                [CGPoint(x: 6.4, y: 16.2), CGPoint(x: 1.8, y: 16.2), CGPoint(x: 1.8, y: 11.6)]]
    for c in corners {
        ctx.move(to: c[0]); ctx.addArc(tangent1End: c[1], tangent2End: c[2], radius: 3); ctx.addLine(to: c[2]); ctx.strokePath()
    }
    ctx.fillEllipse(in: CGRect(x: 5.6, y: 5.6, width: 6.8, height: 6.8))
    ctx.restoreGState()
    return ctx.makeImage()!
}

let set = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: set)
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for (size, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
    let data = NSBitmapImageRep(cgImage: render(size * scale)).representation(using: .png, properties: [:])!
    try! data.write(to: set.appendingPathComponent(name))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", out.path]
try! p.run(); p.waitUntilExit()
try! NSBitmapImageRep(cgImage: render(1024)).representation(using: .png, properties: [:])!
    .write(to: out.deletingPathExtension().appendingPathExtension("png"))
print(p.terminationStatus == 0 ? "wrote \(out.path)" : "iconutil failed")
