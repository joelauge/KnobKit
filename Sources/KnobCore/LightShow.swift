import Foundation

/// An image as plain RGB bytes, already composited on black.
public struct Bitmap: Sendable, Equatable {
    public let width: Int
    public let height: Int
    /// Three bytes per pixel, row by row from the top.
    public var pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(pixels.count == width * height * 3)
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public init(width: Int, height: Int) {
        self.init(width: width, height: height, pixels: [UInt8](repeating: 0, count: max(width, 0) * max(height, 0) * 3))
    }

    public mutating func set(_ x: Int, _ y: Int, _ r: UInt8, _ g: UInt8, _ b: UInt8) {
        guard x >= 0, y >= 0, x < width, y < height else { return }
        let i = (y * width + x) * 3
        pixels[i] = r
        pixels[i + 1] = g
        pixels[i + 2] = b
    }

    /// Average colour over a rectangle given in pixel coordinates, 0…1 per channel.
    /// Everything outside the image counts as black.
    public func average(x0: Double, y0: Double, x1: Double, y1: Double) -> (r: Double, g: Double, b: Double) {
        let area = (x1 - x0) * (y1 - y0)
        guard area > 0, width > 0, height > 0 else { return (0, 0, 0) }
        let fromX = max(Int(x0.rounded(.down)), 0), toX = min(Int(x1.rounded(.up)), width)
        let fromY = max(Int(y0.rounded(.down)), 0), toY = min(Int(y1.rounded(.up)), height)
        guard fromX < toX, fromY < toY else { return (0, 0, 0) }
        var r = 0.0, g = 0.0, b = 0.0
        for y in fromY..<toY {
            let wy = min(Double(y + 1), y1) - max(Double(y), y0)
            guard wy > 0 else { continue }
            for x in fromX..<toX {
                let wx = min(Double(x + 1), x1) - max(Double(x), x0)
                guard wx > 0 else { continue }
                let i = (y * width + x) * 3
                let w = wx * wy
                r += Double(pixels[i]) * w
                g += Double(pixels[i + 1]) * w
                b += Double(pixels[i + 2]) * w
            }
        }
        let scale = 1 / (area * 255)
        return (r * scale, g * scale, b * scale)
    }
}

/// An image played across the keyboard as if the keys were pixels and the keyboard a
/// small window sliding over it.
///
/// The image is read like text. It is cut into `lines` horizontal bands, each as tall
/// as the keyboard's six rows; a band enters from the right, crosses to the left, and
/// then the next band follows. A wide banner is one line.
public struct LightShow: Sendable, Equatable {
    public var bitmap: Bitmap
    /// How many bands the image is read in.
    public var lines = 1
    /// Travel in key widths per second.
    public var speed = 8.0
    /// 0…1.
    public var brightness = 1.0
    /// Brightness steps per colour channel: 2 gives hard on / off edges, more gives
    /// softer ones (and more to send).
    public var levels = 2
    public var loop = true
    /// How the picture is laid over the staggered rows.
    ///
    /// On (the default): each key shows the part of the picture that is physically
    /// above it. The rows of a keyboard are offset from one another (the Q row half a
    /// key to the right of the number row, the A row three quarters, the Z row one and
    /// a quarter), so a vertical stroke lights the nearest key in each row and stays
    /// upright. Off: every row is read as a plain grid, key under key, moving a whole
    /// key at a time; strokes then lean with the keys.
    public var upright = true
    /// Move the picture a whole key at a time, so its shape holds still between steps,
    /// instead of gliding. Worth trying when the connection carries few frames a second.
    public var wholeKeySteps = false

    public init(bitmap: Bitmap) {
        self.bitmap = bitmap
    }

    /// Image pixels per key width.
    public var pixelsPerKey: Double {
        max(Double(bitmap.height) / Double(F75Board.rows * max(lines, 1)), 0.0001)
    }

    /// Width of the image in key widths.
    public var widthInKeys: Double { Double(bitmap.width) / pixelsPerKey }

    /// Seconds one band takes: fully off the right edge to fully off the left.
    public var lineDuration: Double { (widthInKeys + F75Board.width) / max(speed, 0.01) }

    public var duration: Double { lineDuration * Double(max(lines, 1)) }

    /// The colour under every key at `time`, by light index, 0…1 per channel.
    public func colors(at time: Double) -> [Int: (r: Double, g: Double, b: Double)] {
        let total = duration
        var t = max(time, 0)
        if loop, total > 0 { t = t.truncatingRemainder(dividingBy: total) }
        let line = min(Int(t / lineDuration), max(lines, 1) - 1)
        // Left edge of the keyboard, in key widths along the image.
        let offset = -F75Board.width + speed * (t - Double(line) * lineDuration)
        let ppk = pixelsPerKey
        let soft = levels > 2
        // On the plain grid the picture steps key by key unless soft edges are wanted.
        let shift = wholeKeySteps || (!upright && !soft) ? offset.rounded(.down) : offset
        // With soft edges a key averages the key-wide patch of picture above it. With
        // hard edges it shows the point at its centre, so fine detail is kept as the
        // picture moves instead of being averaged away. (The sliver starts a hair right
        // of centre so a key sitting exactly on a pixel boundary picks one side.)
        let aperture = soft ? 1.0 : 0.02
        var out: [Int: (r: Double, g: Double, b: Double)] = [:]
        for key in F75Board.keys {
            let centre = upright ? key.centerX : Double(F75Board.column(of: key)) + 0.5
            let left = soft ? centre - 0.5 : centre + 0.001
            let x0 = (left + shift) * ppk
            let y0 = Double(line * F75Board.rows + key.row) * ppk
            let c = bitmap.average(x0: x0, y0: y0, x1: x0 + aperture * ppk, y1: y0 + ppk)
            out[key.light] = (c.r * brightness, c.g * brightness, c.b * brightness)
        }
        return out
    }

    /// The frame to send at `time`: keys grouped by colour, small enough to fit in
    /// `budget` payload bytes where that is possible.
    public func frame(at time: Double, budget: Int = 4 * AulaLighting.chunk) -> [AulaLighting.Group] {
        let colors = colors(at: time)
        var steps = max(levels, 2)
        while true {
            let groups = Self.groups(colors, levels: steps)
            if Self.size(groups) <= budget || steps == 2 {
                return Self.fit(groups, budget: budget)
            }
            steps -= 1
        }
    }

    static func size(_ groups: [AulaLighting.Group]) -> Int {
        groups.reduce(0) { $0 + 4 + $1.lights.count }
    }

    /// Rounds each channel to one of `levels` steps and groups keys by the result.
    static func groups(_ colors: [Int: (r: Double, g: Double, b: Double)], levels: Int) -> [AulaLighting.Group] {
        let top = Double(levels - 1)
        func step(_ v: Double) -> UInt8 {
            UInt8(((min(max(v, 0), 1) * top).rounded() / top * 255).rounded())
        }
        var byColor: [UInt32: [Int]] = [:]
        for (light, c) in colors {
            let r = step(c.r), g = step(c.g), b = step(c.b)
            guard r != 0 || g != 0 || b != 0 else { continue }
            byColor[UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b), default: []].append(light)
        }
        return byColor
            .map { AulaLighting.Group(red: UInt8($0.key >> 16), green: UInt8(($0.key >> 8) & 0xff), blue: UInt8($0.key & 0xff),
                                      lights: $0.value.sorted()) }
            .sorted { ($0.lights.count, $0.lights.first ?? 0) > ($1.lights.count, $1.lights.first ?? 0) }
    }

    /// Folds the smallest colour groups into their nearest neighbours until the frame
    /// fits, so a busy picture loses colours before it loses frame rate.
    static func fit(_ groups: [AulaLighting.Group], budget: Int) -> [AulaLighting.Group] {
        var groups = groups
        while size(groups) > budget, groups.count > 1 {
            let smallest = groups.removeLast()
            func distance(_ g: AulaLighting.Group) -> Int {
                let dr = Int(g.red) - Int(smallest.red), dg = Int(g.green) - Int(smallest.green), db = Int(g.blue) - Int(smallest.blue)
                return dr * dr + dg * dg + db * db
            }
            let nearest = groups.indices.min { distance(groups[$0]) < distance(groups[$1]) }!
            groups[nearest].lights = (groups[nearest].lights + smallest.lights).sorted()
            groups.sort { ($0.lights.count, $0.lights.first ?? 0) > ($1.lights.count, $1.lights.first ?? 0) }
        }
        return groups
    }
}

/// A five-row pixel font for text banners. The keyboard has six rows of keys, and the
/// bottom one is mostly space bar, so letters live on the top five.
public enum PixelFont {
    /// Renders `text` as a bitmap six pixels tall (one per key row), one pixel per key
    /// width, with the bottom row left dark.
    public static func render(_ text: String, red: UInt8 = 255, green: UInt8 = 255, blue: UInt8 = 255) -> Bitmap {
        var columns: [[Bool]] = []
        for character in text {
            let glyph = glyphs[character] ?? glyphs[Character(character.uppercased())] ?? glyphs["?"]!
            let width = glyph.map(\.count).max() ?? 0
            for x in 0..<width {
                columns.append(glyph.map { row in
                    let cells = Array(row)
                    return x < cells.count && cells[x] == "#"
                })
            }
            columns.append([false, false, false, false, false])
        }
        if !columns.isEmpty { columns.removeLast() }
        var bitmap = Bitmap(width: max(columns.count, 1), height: F75Board.rows)
        for (x, column) in columns.enumerated() {
            for (y, on) in column.enumerated() where on { bitmap.set(x, y, red, green, blue) }
        }
        return bitmap
    }

    static let glyphs: [Character: [String]] = [
        " ": ["..", "..", "..", "..", ".."],
        "A": [".##.", "#..#", "####", "#..#", "#..#"],
        "B": ["###.", "#..#", "###.", "#..#", "###."],
        "C": [".###", "#...", "#...", "#...", ".###"],
        "D": ["###.", "#..#", "#..#", "#..#", "###."],
        "E": ["####", "#...", "###.", "#...", "####"],
        "F": ["####", "#...", "###.", "#...", "#..."],
        "G": [".###", "#...", "#.##", "#..#", ".###"],
        "H": ["#..#", "#..#", "####", "#..#", "#..#"],
        "I": ["###", ".#.", ".#.", ".#.", "###"],
        "J": ["..##", "...#", "...#", "#..#", ".##."],
        "K": ["#..#", "#.#.", "##..", "#.#.", "#..#"],
        "L": ["#...", "#...", "#...", "#...", "####"],
        "M": ["#...#", "##.##", "#.#.#", "#...#", "#...#"],
        "N": ["#..#", "##.#", "#.##", "#..#", "#..#"],
        "O": [".##.", "#..#", "#..#", "#..#", ".##."],
        "P": ["###.", "#..#", "###.", "#...", "#..."],
        "Q": [".##.", "#..#", "#..#", "#.#.", ".#.#"],
        "R": ["###.", "#..#", "###.", "#.#.", "#..#"],
        "S": [".###", "#...", ".##.", "...#", "###."],
        "T": ["###", ".#.", ".#.", ".#.", ".#."],
        "U": ["#..#", "#..#", "#..#", "#..#", ".##."],
        "V": ["#...#", "#...#", ".#.#.", ".#.#.", "..#.."],
        "W": ["#...#", "#...#", "#.#.#", "##.##", "#...#"],
        "X": ["#..#", "#..#", ".##.", "#..#", "#..#"],
        "Y": ["#.#", "#.#", ".#.", ".#.", ".#."],
        "Z": ["####", "..#.", ".#..", "#...", "####"],
        "0": [".##.", "#.##", "#..#", "##.#", ".##."],
        "1": [".#.", "##.", ".#.", ".#.", "###"],
        "2": ["###.", "...#", ".##.", "#...", "####"],
        "3": ["###.", "...#", ".##.", "...#", "###."],
        "4": ["#..#", "#..#", "####", "...#", "...#"],
        "5": ["####", "#...", "###.", "...#", "###."],
        "6": [".##.", "#...", "###.", "#..#", ".##."],
        "7": ["####", "...#", "..#.", ".#..", ".#.."],
        "8": [".##.", "#..#", ".##.", "#..#", ".##."],
        "9": [".##.", "#..#", ".###", "...#", ".##."],
        ".": [".", ".", ".", ".", "#"],
        ",": ["..", "..", "..", ".#", "#."],
        "!": ["#", "#", "#", ".", "#"],
        "?": ["###.", "...#", ".##.", "....", ".#.."],
        "'": ["#", "#", ".", ".", "."],
        "’": ["#", "#", ".", ".", "."],
        "\"": ["#.#", "#.#", "...", "...", "..."],
        "-": ["...", "...", "###", "...", "..."],
        "_": ["...", "...", "...", "...", "###"],
        ":": [".", "#", ".", "#", "."],
        ";": ["..", ".#", "..", ".#", "#."],
        "/": ["..#", "..#", ".#.", "#..", "#.."],
        "(": [".#", "#.", "#.", "#.", ".#"],
        ")": ["#.", ".#", ".#", ".#", "#."],
        "+": ["...", ".#.", "###", ".#.", "..."],
        "=": ["...", "###", "...", "###", "..."],
        "&": [".#..", "#.#.", ".#..", "#.#.", ".#.#"],
        "@": [".###.", "#.#.#", "#.###", "#....", ".###."],
        "#": [".#.#.", "#####", ".#.#.", "#####", ".#.#."],
        "%": ["#..#", "...#", ".##.", "#...", "#..#"],
        "*": ["#.#", ".#.", "#.#", "...", "..."],
        "<": ["..#", ".#.", "#..", ".#.", "..#"],
        ">": ["#..", ".#.", "..#", ".#.", "#.."],
        "♥": [".#.#.", "#####", "#####", ".###.", "..#.."],
        "❤": [".#.#.", "#####", "#####", ".###.", "..#.."],
    ]
}
