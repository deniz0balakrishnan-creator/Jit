import AppKit

/// Small original pixel drawings: the tool marks and the menu bar icon.
enum Art {
    /// Claude mark: an orange spark.
    static let claudeMark = pixelImage([
        "....#....",
        ".#..#..#.",
        "..#.#.#..",
        "...###...",
        "#########",
        "...###...",
        "..#.#.#..",
        ".#..#..#.",
        "....#....",
    ], palette: ["#": (217, 119, 87)])

    /// Codex mark: a terminal prompt on a dark tile.
    static let codexMark = pixelImage([
        ".#######.",
        "#########",
        "#w#######",
        "##w######",
        "###w#####",
        "##w######",
        "#w##www##",
        "#########",
        ".#######.",
    ], palette: ["#": (32, 33, 36), "w": (255, 255, 255)])

    /// 16×16 squid silhouette for the menu bar, drawn as a template so macOS tints it.
    static let menuIcon: NSImage = {
        let rows = [
            ".....######.....",
            "...##########...",
            "..############..",
            ".##############.",
            ".##############.",
            ".###..####..###.",
            ".###..####..###.",
            ".##############.",
            ".##############.",
            "..############..",
            "..##.##..##.##..",
            "..##.##..##.##..",
            ".##..##..##..##.",
            ".##..##..##..##.",
            ".#...##..##...#.",
            "................",
        ]
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            NSColor.black.setFill()
            for (y, row) in rows.enumerated() {
                for (x, c) in row.enumerated() where c == "#" {
                    NSRect(x: x + 1, y: y + 1, width: 1, height: 1).fill()
                }
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Jit"
        return image
    }()

    /// Builds an image from rows of characters; `.` is transparent.
    static func pixelImage(_ rows: [String], palette: [Character: (UInt8, UInt8, UInt8)]) -> CGImage {
        let width = rows[0].count, height = rows.count
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for (y, row) in rows.enumerated() {
            for (x, c) in row.enumerated() {
                guard let (r, g, b) = palette[c] else { continue }
                let i = (y * width + x) * 4
                pixels[i] = r; pixels[i + 1] = g; pixels[i + 2] = b; pixels[i + 3] = 255
            }
        }
        return makeImage(pixels, width: width, height: height)
    }

    /// Wraps premultiplied RGBA bytes (top row first) in a CGImage.
    static func makeImage(_ pixels: [UInt8], width: Int, height: Int) -> CGImage {
        CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: CGDataProvider(data: Data(pixels) as CFData)!,
                decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }
}
