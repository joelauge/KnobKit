import Foundation

/// macOS virtual key codes (US ANSI positions) and their display names.
public enum Key {
    public static let a = 0, s = 1, d = 2, f = 3, h = 4, g = 5, z = 6, x = 7, c = 8, v = 9
    public static let b = 11, q = 12, w = 13, e = 14, r = 15, y = 16, t = 17
    public static let one = 18, two = 19, three = 20, four = 21, six = 22, five = 23
    public static let equal = 24, nine = 25, seven = 26, minus = 27, eight = 28, zero = 29
    public static let rightBracket = 30, o = 31, u = 32, leftBracket = 33, i = 34, p = 35
    public static let returnKey = 36, l = 37, j = 38, quote = 39, k = 40, semicolon = 41
    public static let backslash = 42, comma = 43, slash = 44, n = 45, m = 46, period = 47
    public static let tab = 48, space = 49, grave = 50, delete = 51, escape = 53
    public static let command = 55, shift = 56, capsLock = 57, option = 58, control = 59
    public static let f17 = 64, f18 = 79, f19 = 80, f20 = 90
    public static let f5 = 96, f6 = 97, f7 = 98, f3 = 99, f8 = 100, f9 = 101, f11 = 103
    public static let f13 = 105, f16 = 106, f14 = 107, f10 = 109, f12 = 111, f15 = 113
    public static let home = 115, pageUp = 116, forwardDelete = 117, f4 = 118, end = 119
    public static let f2 = 120, pageDown = 121, f1 = 122
    public static let left = 123, right = 124, down = 125, up = 126
}

public enum KeyNames {
    public static let table: [Int: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 10: "§",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
        30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "↩", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";",
        42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 48: "⇥", 49: "Space", 50: "`", 51: "⌫", 53: "⎋",
        64: "F17", 65: "Keypad .", 67: "Keypad *", 69: "Keypad +", 71: "Keypad Clear", 75: "Keypad /",
        76: "Keypad ↩", 78: "Keypad -", 79: "F18", 80: "F19", 81: "Keypad =",
        82: "Keypad 0", 83: "Keypad 1", 84: "Keypad 2", 85: "Keypad 3", 86: "Keypad 4", 87: "Keypad 5",
        88: "Keypad 6", 89: "Keypad 7", 90: "F20", 91: "Keypad 8", 92: "Keypad 9",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11", 105: "F13", 106: "F16",
        107: "F14", 109: "F10", 111: "F12", 113: "F15", 114: "Help", 115: "Home", 116: "Page Up", 117: "⌦",
        118: "F4", 119: "End", 120: "F2", 121: "Page Down", 122: "F1", 123: "←", 124: "→", 125: "↓", 126: "↑",
    ]

    public static func name(_ code: Int) -> String { table[code] ?? "Key \(code)" }

    /// Key groups for the manual key picker (for combos that cannot be recorded, like ⌘⇥).
    public static let groups: [(String, [Int])] = [
        ("Navigation", [123, 124, 126, 125, 115, 119, 116, 121]),
        ("Editing", [49, 36, 48, 51, 117, 53]),
        ("Letters", [0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46, 45, 31, 35, 12, 15, 1, 17, 32, 9, 13, 7, 16, 6]),
        ("Digits", [18, 19, 20, 21, 23, 22, 26, 28, 25, 29]),
        ("Symbols", [27, 24, 33, 30, 42, 41, 39, 43, 47, 44, 50]),
        ("Function", [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]),
    ]
}
