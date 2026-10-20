import AppKit

/// The 32×32 pet sprite, plus what's derived from it: a closed-eyes copy for blinking,
/// how much of him shows when he peeks over the screen edge, and the two tentacle "paws"
/// that grip the edge while he peeks.
///
/// The eyes are found automatically: the brightest pixels (at least 80% of the brightest
/// pixel's luminance) are treated as eyes, as long as they are a small part of the sprite.
struct Sprite {
    static let size = 32
    static let defaultPath = "sprites/placeholder.png"
    /// The paws image is wider than the sprite so they fit beside a wide head.
    static let pawsWidth = size + 8
    private static let paw = [".##.",
                              "#BB#",
                              "#BB#"]

    let open: CGImage
    let blink: CGImage
    /// Rows, counted from the top, that show while peeking: his head down to just below the eyes.
    let peekRows: Int
    /// `pawsWidth` × 3 pixels, centred on the sprite, resting on the screen edge.
    let paws: CGImage
    private let alpha: [UInt8]
    private let pawsAlpha: [UInt8]

    /// Loads the sprite named by the `spritePath` preference, falling back to the placeholder.
    static func load() -> Sprite {
        let configured = UserDefaults.standard.string(forKey: "spritePath") ?? defaultPath
        if let sprite = Sprite(path: configured) { return sprite }
        NSLog("Jit: no 32×32 PNG at %@, using %@", configured, defaultPath)
        return Sprite(path: defaultPath)!
    }

    /// `path` is absolute (or `~/…`), or relative to the app's resources.
    init?(path: String) {
        let expanded = (path as NSString).expandingTildeInPath
        let url = expanded.hasPrefix("/")
            ? URL(fileURLWithPath: expanded)
            : Bundle.main.resourceURL!.appendingPathComponent(expanded)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width == Self.size, image.height == Self.size else { return nil }

        let n = Self.size
        var px = [UInt8](repeating: 0, count: n * n * 4)
        px.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))
        }

        let luminance = (0..<n * n).map { i -> Double in
            px[i * 4 + 3] == 0 ? 0 : 0.2126 * Double(px[i * 4]) + 0.7152 * Double(px[i * 4 + 1]) + 0.0722 * Double(px[i * 4 + 2])
        }
        let brightest = luminance.max() ?? 0
        var eyes = Set((0..<n * n).filter { brightest > 0 && luminance[$0] >= 0.8 * brightest })
        let opaqueCount = (0..<n * n).filter { px[$0 * 4 + 3] > 0 }.count
        if eyes.count > opaqueCount / 20 { eyes = [] }  // no distinct eyes: don't blink

        // Close each eye pixel with the colour of the nearest non-eye pixel above it.
        var closed = px
        for i in eyes {
            var j = i - n
            while j >= 0 && (eyes.contains(j) || px[j * 4 + 3] == 0) { j -= n }
            for k in 0..<4 { closed[i * 4 + k] = j >= 0 ? px[j * 4 + k] : 0 }
        }

        let eyeBottom = eyes.map { $0 / n }.max()
        let peek = min(n, (eyeBottom ?? 10) + 4)

        // Paws: two tentacle tips in the tentacles' own colours (the darkest pixel of the bottom
        // rows for the outline, a mid-light one for the fill), one pixel clear of the head.
        let tentacles = ((n - 6) * n..<n * n).filter { px[$0 * 4 + 3] > 0 }.sorted { luminance[$0] < luminance[$1] }
        let outline = tentacles.first ?? 0, fill = tentacles.isEmpty ? 0 : tentacles[tentacles.count * 2 / 3]
        let edgeCols = (0..<n).filter { c in (peek - 3..<peek).contains { px[($0 * n + c) * 4 + 3] > 0 } }
        let pw = Self.pawsWidth, margin = (pw - n) / 2
        var pawPx = [UInt8](repeating: 0, count: pw * 3 * 4)
        for x0 in [(edgeCols.min() ?? 8) - 5, (edgeCols.max() ?? 23) + 2] {
            for (y, line) in Self.paw.enumerated() {
                for (dx, c) in line.enumerated() where c != "." {
                    let x = x0 + dx + margin
                    guard (0..<pw).contains(x) else { continue }
                    let from = (c == "#" ? outline : fill) * 4, to = (y * pw + x) * 4
                    for k in 0..<4 { pawPx[to + k] = px[from + k] }
                }
            }
        }

        open = Art.makeImage(px, width: n, height: n)
        blink = Art.makeImage(closed, width: n, height: n)
        paws = Art.makeImage(pawPx, width: pw, height: 3)
        peekRows = peek
        alpha = (0..<n * n).map { px[$0 * 4 + 3] }
        pawsAlpha = (0..<pw * 3).map { pawPx[$0 * 4 + 3] }
    }

    /// Whether the pixel at (`col`, `row`) is visible; row 0 is the top.
    func isOpaque(col: Int, row: Int) -> Bool {
        (0..<Self.size).contains(col) && (0..<Self.size).contains(row) && alpha[row * Self.size + col] > 0
    }

    /// Whether the paws pixel at (`col`, `row`) is visible; row 0 is the top.
    func isPawOpaque(col: Int, row: Int) -> Bool {
        (0..<Self.pawsWidth).contains(col) && (0..<3).contains(row) && pawsAlpha[row * Self.pawsWidth + col] > 0
    }
}
