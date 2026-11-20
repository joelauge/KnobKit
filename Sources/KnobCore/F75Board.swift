import Foundation

/// The Epomaker x Aula F75's keys: where each sits, which macOS key it is, and the
/// index of the light under it in AULA lighting frames.
///
/// Positions are in key units (one ordinary key is 1 wide). The light indices are
/// column-major with a stride of six (Esc 0, ` 1, Tab 2, Caps 3, Shift 4, Ctrl 5, then
/// the next column), from the key table in bakiakyol/aula-f75-hub, which took it from
/// the vendor app's own layout file.
public enum F75Board {
    public struct Key: Sendable, Hashable {
        /// Left edge.
        public let x: Double
        /// Top edge. The function row sits a quarter unit above the others.
        public let y: Double
        public let width: Double
        /// 0 (function row) to 5 (space bar row).
        public let row: Int
        /// macOS virtual key code, nil for modifier keys.
        public let keyCode: Int?
        /// Index of this key's light.
        public let light: Int

        public var centerX: Double { x + width / 2 }
    }

    public static let width = 16.0
    public static let height = 6.25
    public static let rows = 6
    public static let knobCenterX = 15.4
    public static let knobCenterY = 0.5
    public static let knobRadius = 0.58

    /// How far each row sits to the right of the number row, in key widths.
    static let stagger: [Double] = [0, 0, 0.5, 0.75, 1.25, 0]

    /// The key's column when the rows are read as a plain grid, key under key, ignoring
    /// their stagger: ` 1 2 3 over Tab Q W E over Caps A S D.
    public static func column(of key: Key) -> Int {
        max(Int((key.centerX - stagger[key.row] - 0.5).rounded()), 0)
    }

    public static let keys: [Key] = {
        var out: [Key] = []
        func row(_ index: Int, start: Double = 0, _ keys: [(Double, Int?, Int)]) {
            let y = index == 0 ? 0 : Double(index) + 0.25
            var x = start
            for (w, code, light) in keys {
                out.append(Key(x: x, y: y, width: w, row: index, keyCode: code, light: light))
                x += w
            }
        }
        func k(_ w: Double, _ code: Int?, _ light: Int) -> (Double, Int?, Int) { (w, code, light) }
        func ones(_ codes: [Int], _ lights: [Int]) -> [(Double, Int?, Int)] {
            zip(codes, lights).map { (1, $0, $1) }
        }

        // Function row: Esc, a key-wide gap, three groups of four a quarter key apart,
        // then the knob. Measured off the drawing on the card in the F75's box and the
        // vendor app's layout file.
        row(0, [k(1, 53, 0)])
        row(0, start: 2, ones([122, 120, 99, 118], [12, 18, 24, 30]))
        row(0, start: 6.25, ones([96, 97, 98, 100], [36, 42, 48, 54]))
        row(0, start: 10.5, ones([101, 109, 103, 111], [60, 66, 72, 78]))
        row(1, ones([50, 18, 19, 20, 21, 23, 22, 26, 28, 25, 29, 27, 24],
                    [1, 7, 13, 19, 25, 31, 37, 43, 49, 55, 61, 67, 73])
               + [k(2, 51, 79), k(1, 117, 85)])
        row(2, [k(1.5, 48, 2)]
               + ones([12, 13, 14, 15, 17, 16, 32, 34, 31, 35, 33, 30], [8, 14, 20, 26, 32, 38, 44, 50, 56, 62, 68, 74])
               + [k(1.5, 42, 80), k(1, 116, 86)])
        row(3, [k(1.75, nil, 3)]
               + ones([0, 1, 2, 3, 5, 4, 38, 40, 37, 41, 39], [9, 15, 21, 27, 33, 39, 45, 51, 57, 63, 69])
               + [k(2.25, 36, 81), k(1, 121, 87)])
        row(4, [k(2.25, nil, 4)]
               + ones([6, 7, 8, 9, 11, 45, 46, 43, 47, 44], [10, 16, 22, 28, 34, 40, 46, 52, 58, 64])
               + [k(1.75, nil, 70), k(1, 126, 82), k(1, 119, 88)])
        row(5, [k(1.25, nil, 5), k(1.25, nil, 11), k(1.25, nil, 17), k(6.25, 49, 35), k(1.25, nil, 53), k(1.25, nil, 59)])
        row(5, start: 13, ones([123, 125, 124], [77, 83, 89]))
        return out
    }()
}
