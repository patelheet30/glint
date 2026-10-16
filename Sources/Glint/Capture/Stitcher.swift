import CoreGraphics

/// Scrolling capture's stitcher: each new frame is matched against the previous one by per-row hashes to find how far
/// the content moved up, and only the newly revealed rows are appended.
/// ponytail: exact row-hash matching (fine for UI/text, which scrolls in whole pixels); fall back to Vision
/// VNTranslationalImageRegistrationRequest if animated or subpixel-scrolled content mis-stitches.
final class Stitcher {
    enum Result: Equatable { case first, unchanged, appended(Int), lost }

    private(set) var slices: [CGImage] = []
    private(set) var height = 0
    private var prevHashes: [UInt64] = []
    let maxHeight: Int

    init(maxHeight: Int = 30_000) { self.maxHeight = maxHeight }

    var width: Int { slices.first?.width ?? 0 }
    var isFull: Bool { height >= maxHeight }

    func add(_ frame: CGImage) -> Result {
        let hashes = Self.rowHashes(frame)
        guard !prevHashes.isEmpty else {
            prevHashes = hashes
            slices = [frame]
            height = frame.height
            return .first
        }
        guard hashes.count == prevHashes.count else { return .lost }
        guard let dy = Self.offset(prev: prevHashes, next: hashes) else { return .lost }
        if dy == 0 { prevHashes = hashes; return .unchanged }
        let keep = min(dy, maxHeight - height)
        guard keep > 0, let slice = frame.cropping(to: CGRect(x: 0, y: frame.height - keep, width: frame.width, height: keep)) else { return .unchanged }
        slices.append(slice)
        height += keep
        prevHashes = hashes
        return .appended(keep)
    }

    /// The stitched image.
    func image() -> CGImage? {
        guard let first = slices.first,
              let ctx = CGContext(data: nil, width: first.width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        var top = 0 // CG draws bottom-up: place each slice below the previous one
        for s in slices {
            ctx.draw(s, in: CGRect(x: 0, y: height - top - s.height, width: s.width, height: s.height))
            top += s.height
        }
        return ctx.makeImage()
    }

    /// FNV-1a over every pixel of each row, top to bottom (RGBA8, so the source pixel format doesn't matter).
    static func rowHashes(_ img: CGImage) -> [UInt64] {
        let w = img.width, h = img.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return [] }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        let px = data.bindMemory(to: UInt32.self, capacity: w * h)
        var out = [UInt64](repeating: 0, count: h)
        for y in 0..<h { // bitmap memory is top row first
            var hash: UInt64 = 0xcbf2_9ce4_8422_2325
            let row = px + y * w
            for x in 0..<w { hash = (hash ^ UInt64(row[x])) &* 0x100_0000_01b3 }
            out[y] = hash
        }
        return out
    }

    /// How many rows the content moved up between `prev` and `next` (0 = no movement), or nil if no shift explains it.
    /// Rows that look like their neighbours (blank space) don't count as evidence; a fixed header just lowers the score.
    static func offset(prev: [UInt64], next: [UInt64]) -> Int? {
        let h = prev.count
        guard h == next.count, h > 8 else { return nil }
        let informative = (0..<h).filter { y in y == 0 || next[y] != next[y - 1] }
        guard !informative.isEmpty else { return 0 } // a blank frame: treat as unchanged
        if informative.allSatisfy({ prev[$0] == next[$0] }) { return 0 }
        var best: (dy: Int, score: Double)?
        let minOverlap = max(8, h / 10)
        for dy in 1...(h - minOverlap) {
            var hits = 0, total = 0
            for y in informative where y + dy < h {
                total += 1
                if next[y] == prev[y + dy] { hits += 1 }
            }
            guard total >= 4 else { continue }
            let score = Double(hits) / Double(total)
            if score > (best?.score ?? 0) { best = (dy, score) }
        }
        guard let best, best.score >= 0.75 else { return nil }
        return best.dy
    }
}
