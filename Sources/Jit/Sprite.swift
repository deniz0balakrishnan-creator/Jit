import AppKit

/// The 32×32 pet sprite, plus a closed-eyes copy for blinking.
///
/// The eyes are found automatically: the brightest pixels (at least 80% of the brightest
/// pixel's luminance) are treated as eyes, as long as they are a small part of the sprite.
struct Sprite {
    static let size = 32
    static let defaultPath = "sprites/placeholder.png"

    let open: CGImage
    let blink: CGImage
    private let alpha: [UInt8]

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

        open = Art.makeImage(px, width: n, height: n)
        blink = Art.makeImage(closed, width: n, height: n)
        alpha = (0..<n * n).map { px[$0 * 4 + 3] }
    }

    /// Whether the pixel at (`col`, `row`) is visible; row 0 is the top.
    func isOpaque(col: Int, row: Int) -> Bool {
        (0..<Self.size).contains(col) && (0..<Self.size).contains(row) && alpha[row * Self.size + col] > 0
    }
}
