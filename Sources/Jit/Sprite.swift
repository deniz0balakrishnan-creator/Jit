import AppKit

/// The 32×32 pet sprite, plus what's derived from it: a closed-eyes copy for blinking,
/// how much of him shows when he peeks over the screen edge, the two tentacle "paws" that
/// grip the edge while he peeks, and the tentacle he rests on his chin while thinking.
///
/// The eyes are found automatically: the brightest pixels (at least 80% of the brightest
/// pixel's luminance) are treated as eyes, as long as they are a small part of the sprite.
struct Sprite {
    static let size = 32
    static let defaultPath = "sprites/placeholder.png"
    /// Overlays are wider than the sprite so the paws fit beside a wide head.
    static let overlayWidth = size + 8
    /// How many pixels he rises out of the peek while thinking.
    static let thinkRise = 3
    private static let paw = [".##.",
                              "#BB#",
                              "#BB#"]

    let open: CGImage
    let blink: CGImage
    /// Rows, counted from the top, that show while peeking: his head down to just below the eyes.
    let peekRows: Int
    /// Both paws resting on the screen edge, centred on the sprite.
    let paws: Overlay
    /// While thinking: the left paw on the edge and the right tentacle curled up to his chin.
    let thinkingPaws: Overlay
    /// The top row of his head, and the rightmost pixel just below it (where the thought bubble starts).
    let headTop: (row: Int, rightCol: Int)
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

        let eyeBottom = eyes.map { $0 / n }.max()
        let peek = min(n, (eyeBottom ?? 10) + 4)

        // Paws and the thinking tentacle use the tentacles' own colours: the darkest pixel of the
        // bottom rows for the outline, a light one for the fill. Each pixel is (x, y, source pixel),
        // with x in overlay columns (sprite column + margin).
        let tentacles = ((n - 6) * n..<n * n).filter { px[$0 * 4 + 3] > 0 }.sorted { luminance[$0] < luminance[$1] }
        let outline = tentacles.first ?? 0
        let paleFill = tentacles.isEmpty ? 0 : tentacles[tentacles.count * 9 / 10]
        let pawFill = tentacles.isEmpty ? 0 : tentacles[tentacles.count * 2 / 3]
        let margin = (Self.overlayWidth - n) / 2
        /// Columns of his head in the last three visible rows: the paws sit one pixel clear of them.
        func headCols(visible: Int) -> [Int] {
            (0..<n).filter { c in (max(0, visible - 3)..<visible).contains { px[($0 * n + c) * 4 + 3] > 0 } }
        }
        func paw(left x0: Int, top: Int) -> [(Int, Int, Int)] {
            Self.paw.enumerated().flatMap { y, line in
                line.enumerated().compactMap { dx, c in c == "." ? nil : (x0 + dx + margin, top + y, c == "#" ? outline : pawFill) }
            }
        }

        let peekCols = headCols(visible: peek)
        let leftPaw = (peekCols.min() ?? 8) - 5, rightPaw = (peekCols.max() ?? 23) + 2

        // Thinking: risen a little, the right tentacle comes up beside his head and bends in to
        // rest under his chin, below the right eye.
        let thinkVisible = min(n, peek + Self.thinkRise)
        let chin = min((eyeBottom ?? 10) + 2, thinkVisible - 3)
        let thinkRows = thinkVisible - (chin - 1)  // the overlay starts one row above the chin
        let thinkCols = headCols(visible: thinkVisible)
        let eyeCols = eyes.map { $0 % n }.sorted()
        let rightEye = eyeCols.suffix(max(1, eyeCols.count / 2))
        let chinX = (rightEye.isEmpty ? n / 2 + 4 : rightEye.reduce(0, +) / rightEye.count) + margin
        let armX = (thinkCols.max() ?? 23) + 2 + margin
        var arm = Set<Int>()  // y * overlayWidth + x
        let w = Self.overlayWidth
        for y in 2..<thinkRows { arm.insert(y * w + armX); arm.insert(y * w + armX + 1) }
        for x in min(chinX, armX)...armX { arm.insert(2 * w + x) }
        arm.insert(w + chinX - 1); arm.insert(w + chinX)
        var armOutline = Set<Int>()
        for p in arm {
            for dy in -1...1 { for dx in -1...1 {
                let x = p % w + dx, y = p / w + dy
                if (0..<w).contains(x) && (0..<thinkRows).contains(y) && !arm.contains(y * w + x) { armOutline.insert(y * w + x) }
            } }
        }
        let armPixels = armOutline.map { ($0 % w, $0 / w, outline) } + arm.map { ($0 % w, $0 / w, paleFill) }

        let top = (0..<n).first { r in (0..<n).contains { px[(r * n + $0) * 4 + 3] > 0 } } ?? 0
        let below = min(top + 2, n - 1)

        open = Art.makeImage(px, width: n, height: n)
        blink = Art.makeImage(closed, width: n, height: n)
        peekRows = peek
        paws = Overlay(rows: 3, pixels: paw(left: leftPaw, top: 0) + paw(left: rightPaw, top: 0), from: px)
        thinkingPaws = Overlay(rows: thinkRows, pixels: armPixels + paw(left: (thinkCols.min() ?? 8) - 5, top: thinkRows - 3), from: px)
        headTop = (top, (0..<n).last { px[(below * n + $0) * 4 + 3] > 0 } ?? n / 2)
        alpha = (0..<n * n).map { px[$0 * 4 + 3] }
    }

    /// Whether the pixel at (`col`, `row`) is visible; row 0 is the top.
    func isOpaque(col: Int, row: Int) -> Bool {
        (0..<Self.size).contains(col) && (0..<Self.size).contains(row) && alpha[row * Self.size + col] > 0
    }
}

/// A small pixel image drawn over the sprite's edge (paws, the thinking tentacle),
/// `Sprite.overlayWidth` wide and centred on the sprite.
struct Overlay {
    let image: CGImage
    let rows: Int
    private let alpha: [UInt8]

    /// `pixels` are (x, y, index of the sprite pixel whose colour to use); later ones win.
    init(rows: Int, pixels: [(Int, Int, Int)], from sprite: [UInt8]) {
        let w = Sprite.overlayWidth
        var buf = [UInt8](repeating: 0, count: w * rows * 4)
        for (x, y, source) in pixels where (0..<w).contains(x) && (0..<rows).contains(y) {
            for k in 0..<4 { buf[(y * w + x) * 4 + k] = sprite[source * 4 + k] }
        }
        image = Art.makeImage(buf, width: w, height: rows)
        self.rows = rows
        alpha = (0..<w * rows).map { buf[$0 * 4 + 3] }
    }

    /// Whether the pixel at (`col`, `row`) is visible; row 0 is the top.
    func isOpaque(col: Int, row: Int) -> Bool {
        (0..<Sprite.overlayWidth).contains(col) && (0..<rows).contains(row) && alpha[row * Sprite.overlayWidth + col] > 0
    }
}
