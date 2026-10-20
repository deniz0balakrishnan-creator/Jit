import AppKit

/// Small original pixel drawings: the tool marks, the thought bubble and the menu bar icon.
enum Art {
    /// Claude mark: an orange spark.
    private static let claudeRows = [
        "....c....",
        ".c..c..c.",
        "..c.c.c..",
        "...ccc...",
        "ccccccccc",
        "...ccc...",
        "..c.c.c..",
        ".c..c..c.",
        "....c....",
    ]

    /// Codex mark: a terminal prompt on a dark tile.
    private static let codexRows = [
        ".kkkkkkk.",
        "kkkkkkkkk",
        "kwkkkkkkk",
        "kkwkkkkkk",
        "kkkwkkkkk",
        "kkwkkkkkk",
        "kwkkwwwkk",
        "kkkkkkkkk",
        ".kkkkkkk.",
    ]

    private static let palette: [Character: (UInt8, UInt8, UInt8)] = [
        "c": (217, 119, 87), "k": (32, 33, 36), "w": (255, 255, 255),  // marks
        "O": (32, 33, 36), "F": (255, 255, 255),                       // bubble outline and fill
    ]

    static let claudeMark = pixelImage(claudeRows, palette: palette)
    static let codexMark = pixelImage(codexRows, palette: palette)
    static func mark(_ tool: Tool) -> CGImage { tool == .claude ? claudeMark : codexMark }

    /// Thought bubble sizes, in pixels: each icon takes 11 columns (9 plus a 2-pixel gap).
    static let bubbleHeight = 13
    static func bubbleWidth(icons: Int) -> Int { 11 * icons + 3 }

    /// A thought bubble holding one mark per tool, left to right.
    static func thoughtBubble(_ tools: [Tool]) -> CGImage {
        let w = bubbleWidth(icons: tools.count), h = bubbleHeight
        var grid = (0..<h).map { y in
            (0..<w).map { x -> Character in
                let corner = (x == 0 || x == w - 1) && (y == 0 || y == h - 1)
                let inner = (x == 1 || x == w - 2) && (y == 1 || y == h - 2)
                if corner { return "." }
                return x == 0 || x == w - 1 || y == 0 || y == h - 1 || inner ? "O" : "F"
            }
        }
        for (i, tool) in tools.enumerated() {
            for (y, line) in (tool == .claude ? claudeRows : codexRows).enumerated() {
                for (dx, c) in line.enumerated() where c != "." { grid[2 + y][2 + 11 * i + dx] = c }
            }
        }
        return pixelImage(grid.map { String($0) }, palette: palette)
    }

    /// The small and the medium circle trailing from his head to the bubble.
    static let bubbleDots = [
        pixelImage([".OO.", "OFFO", "OFFO", ".OO."], palette: palette),
        pixelImage([".OOO.", "OFFFO", "OFFFO", "OFFFO", ".OOO."], palette: palette),
    ]

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
