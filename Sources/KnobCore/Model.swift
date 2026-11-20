import Foundation

// MARK: - Decoding helper

extension KeyedDecodingContainer {
    /// Decode a value if present and well-formed, otherwise fall back to a default.
    /// Keeps hand-edited or older config files loadable.
    func val<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
    }
}

// MARK: - Modifiers

public struct ModifierSet: OptionSet, Hashable, Sendable, Codable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let control = ModifierSet(rawValue: 1 << 0)
    public static let option = ModifierSet(rawValue: 1 << 1)
    public static let shift = ModifierSet(rawValue: 1 << 2)
    public static let command = ModifierSet(rawValue: 1 << 3)

    public static let ordered: [ModifierSet] = [.control, .option, .shift, .command]
    private static let names: [(ModifierSet, String, String)] = [
        (.control, "ctrl", "⌃"), (.option, "opt", "⌥"), (.shift, "shift", "⇧"), (.command, "cmd", "⌘"),
    ]

    /// "⌃⌥⇧⌘" style string, empty for no modifiers.
    public var symbols: String {
        Self.names.filter { contains($0.0) }.map { $0.2 }.joined()
    }

    public var text: String {
        Self.names.filter { contains($0.0) }.map { $0.1 }.joined(separator: "+")
    }

    public init(text: String) {
        var set: ModifierSet = []
        for part in text.lowercased().split(whereSeparator: { $0 == "+" || $0 == " " || $0 == "," }) {
            switch part {
            case "ctrl", "control", "⌃": set.insert(.control)
            case "opt", "option", "alt", "⌥": set.insert(.option)
            case "shift", "⇧": set.insert(.shift)
            case "cmd", "command", "⌘": set.insert(.command)
            default: break
            }
        }
        self = set
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { self.init(text: s) }
        else { self.init(rawValue: (try? c.decode(Int.self)) ?? 0) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(text)
    }
}

// MARK: - Keys

public struct KeyCombo: Hashable, Sendable, Codable {
    public var keyCode: Int
    public var modifiers: ModifierSet

    public init(_ keyCode: Int, _ modifiers: ModifierSet = []) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    enum CodingKeys: String, CodingKey { case keyCode = "key", modifiers = "mods" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        keyCode = c.val(.keyCode, 49)
        modifiers = c.val(.modifiers, [])
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(keyCode, forKey: .keyCode)
        if !modifiers.isEmpty { try c.encode(modifiers, forKey: .modifiers) }
    }

    public var display: String { modifiers.symbols + KeyNames.name(keyCode) }
}

// MARK: - Knob gestures

public enum KnobGesture: String, Codable, CaseIterable, Sendable {
    case rotateCW, rotateCCW
    case press, doublePress, triplePress, longPress
    case pressRotateCW, pressRotateCCW

    public var isRotation: Bool {
        switch self {
        case .rotateCW, .rotateCCW, .pressRotateCW, .pressRotateCCW: return true
        default: return false
        }
    }

    public var isPressRotate: Bool { self == .pressRotateCW || self == .pressRotateCCW }

    /// +1 clockwise, -1 counter-clockwise, 0 for presses.
    public var direction: Int {
        switch self {
        case .rotateCW, .pressRotateCW: return 1
        case .rotateCCW, .pressRotateCCW: return -1
        default: return 0
        }
    }

    /// The plain rotation a press-rotate falls back to when it has no binding of its own.
    public var plainRotation: KnobGesture? {
        switch self {
        case .pressRotateCW: return .rotateCW
        case .pressRotateCCW: return .rotateCCW
        default: return nil
        }
    }

    public var title: String {
        switch self {
        case .rotateCW: return "Turn right"
        case .rotateCCW: return "Turn left"
        case .press: return "Press"
        case .doublePress: return "Double press"
        case .triplePress: return "Triple press"
        case .longPress: return "Long press"
        case .pressRotateCW: return "Hold + turn right"
        case .pressRotateCCW: return "Hold + turn left"
        }
    }

    public var symbol: String {
        switch self {
        case .rotateCW: return "arrow.clockwise"
        case .rotateCCW: return "arrow.counterclockwise"
        case .press: return "button.programmable"
        case .doublePress: return "2.circle"
        case .triplePress: return "3.circle"
        case .longPress: return "timer"
        case .pressRotateCW: return "arrow.clockwise.circle.fill"
        case .pressRotateCCW: return "arrow.counterclockwise.circle.fill"
        }
    }
}

/// Lets one rotation carry two meanings: a binding marked `.fast` only fires when the
/// knob is spun quickly and takes priority over the `.any` binding for the same gesture.
public enum SpeedClass: String, Codable, Sendable, CaseIterable {
    case any, slow, fast
}

// MARK: - Actions

public enum ActionKind: String, Codable, CaseIterable, Sendable {
    case passthrough, none
    case volume, muteToggle, mediaKey
    /// Universal Audio Apollo monitor output, through the UA mixer engine on this Mac.
    case monitorLevel, monitorToggle
    case keystroke, stickyKeystroke, typeText
    case scroll
    case menuItem
    case shell, appleScript, shortcut, open
    case modeNext, modePrevious, modeSet
    case macro

    public var title: String {
        switch self {
        case .passthrough: return "System default"
        case .none: return "Do nothing"
        case .volume: return "Volume (custom step)"
        case .muteToggle: return "Toggle mute"
        case .mediaKey: return "Media / system key"
        case .monitorLevel: return "Apollo monitor level"
        case .monitorToggle: return "Apollo monitor mute / dim / mono"
        case .keystroke: return "Keystroke"
        case .stickyKeystroke: return "Keystroke with held modifier"
        case .typeText: return "Type text"
        case .scroll: return "Scroll"
        case .menuItem: return "Menu bar item"
        case .shell: return "Shell command"
        case .appleScript: return "AppleScript"
        case .shortcut: return "Run Shortcut"
        case .open: return "Open app, file or URL"
        case .modeNext: return "Next mode"
        case .modePrevious: return "Previous mode"
        case .modeSet: return "Switch to mode"
        case .macro: return "Macro (sequence)"
        }
    }
}

public enum MediaKey: String, Codable, CaseIterable, Sendable {
    case playPause, next, previous, fastForward, rewind
    case volumeUp, volumeDown, mute
    case brightnessUp, brightnessDown
    case keyboardBrightnessUp, keyboardBrightnessDown

    public var title: String {
        switch self {
        case .playPause: return "Play / Pause"
        case .next: return "Next track"
        case .previous: return "Previous track"
        case .fastForward: return "Fast forward"
        case .rewind: return "Rewind"
        case .volumeUp: return "Volume up"
        case .volumeDown: return "Volume down"
        case .mute: return "Mute"
        case .brightnessUp: return "Brightness up"
        case .brightnessDown: return "Brightness down"
        case .keyboardBrightnessUp: return "Keyboard light up"
        case .keyboardBrightnessDown: return "Keyboard light down"
        }
    }

    /// NX_KEYTYPE_* code used in system-defined aux key events.
    public var auxCode: Int {
        switch self {
        case .volumeUp: return 0
        case .volumeDown: return 1
        case .brightnessUp: return 2
        case .brightnessDown: return 3
        case .mute: return 7
        case .playPause: return 16
        case .next: return 17
        case .previous: return 18
        case .fastForward: return 19
        case .rewind: return 20
        case .keyboardBrightnessUp: return 21
        case .keyboardBrightnessDown: return 22
        }
    }
}

/// Switches on a Universal Audio monitor output.
public enum MonitorSwitch: String, Codable, Sendable, CaseIterable {
    case mute, dim, mono

    public var title: String {
        switch self {
        case .mute: return "Mute"
        case .dim: return "Dim"
        case .mono: return "Mono"
        }
    }

    /// Property name in the UA mixer's control tree.
    public var property: String {
        switch self {
        case .mute: return "Mute"
        case .dim: return "DimOn"
        case .mono: return "MixToMono"
        }
    }
}

public enum ScrollUnit: String, Codable, Sendable, CaseIterable {
    case pixel, line
}

/// One thing the knob (or a remapped key) can do. Flat on purpose: every field has a
/// default, only the fields relevant to `kind` are written to disk.
public struct Action: Hashable, Sendable, Codable {
    public var kind: ActionKind
    /// volume: signed step in percent of full scale. monitorLevel: signed step in dB.
    public var amount: Double = 0
    public var monitorSwitch: MonitorSwitch = .mute
    /// monitorLevel / monitorToggle: when the Mac's current output has its own volume
    /// control, drive that instead of the Apollo.
    public var auto: Bool = true
    /// scroll: positive dy scrolls down, positive dx scrolls right.
    public var dx: Double = 0
    public var dy: Double = 0
    public var unit: ScrollUnit = .pixel
    public var smooth: Bool = true
    public var mediaKey: MediaKey = .playPause
    /// mediaKey: send with ⌥⇧ for quarter steps (volume/brightness).
    public var fine: Bool = false
    public var key: KeyCombo = KeyCombo(49)
    public var count: Int = 1
    /// stickyKeystroke: modifiers kept down between ticks. scroll: modifiers attached to the scroll.
    public var hold: ModifierSet = []
    public var releaseAfter: Double = 0.7
    /// typeText / menuItem ("View > Zoom In") / shell / appleScript / shortcut / open / modeSet.
    public var text: String = ""
    public var steps: [MacroStep] = []

    public init(_ kind: ActionKind) { self.kind = kind }

    enum CodingKeys: String, CodingKey {
        case kind, amount, dx, dy, unit, smooth, mediaKey, fine, key, count, hold, releaseAfter, text, steps
        case monitorSwitch, auto
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = c.val(.kind, .none)
        amount = c.val(.amount, 0)
        dx = c.val(.dx, 0)
        dy = c.val(.dy, 0)
        unit = c.val(.unit, .pixel)
        smooth = c.val(.smooth, true)
        mediaKey = c.val(.mediaKey, .playPause)
        fine = c.val(.fine, false)
        key = c.val(.key, KeyCombo(49))
        count = max(1, c.val(.count, 1))
        hold = c.val(.hold, [])
        releaseAfter = c.val(.releaseAfter, 0.7)
        text = c.val(.text, "")
        steps = c.val(.steps, [])
        monitorSwitch = c.val(.monitorSwitch, .mute)
        auto = c.val(.auto, true)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        switch kind {
        case .volume:
            try c.encode(amount, forKey: .amount)
        case .monitorLevel:
            try c.encode(amount, forKey: .amount)
            try c.encode(auto, forKey: .auto)
        case .monitorToggle:
            try c.encode(monitorSwitch, forKey: .monitorSwitch)
            try c.encode(auto, forKey: .auto)
        case .mediaKey:
            try c.encode(mediaKey, forKey: .mediaKey)
            if fine { try c.encode(fine, forKey: .fine) }
            if count > 1 { try c.encode(count, forKey: .count) }
        case .keystroke:
            try c.encode(key, forKey: .key)
            if count > 1 { try c.encode(count, forKey: .count) }
        case .stickyKeystroke:
            try c.encode(key, forKey: .key)
            try c.encode(hold, forKey: .hold)
            try c.encode(releaseAfter, forKey: .releaseAfter)
        case .scroll:
            try c.encode(dx, forKey: .dx)
            try c.encode(dy, forKey: .dy)
            try c.encode(unit, forKey: .unit)
            try c.encode(smooth, forKey: .smooth)
            if !hold.isEmpty { try c.encode(hold, forKey: .hold) }
        case .typeText, .menuItem, .shell, .appleScript, .shortcut, .open, .modeSet:
            try c.encode(text, forKey: .text)
        case .macro:
            try c.encode(steps, forKey: .steps)
        case .passthrough, .none, .muteToggle, .modeNext, .modePrevious:
            break
        }
    }

    // MARK: Convenience constructors

    public static let passthrough = Action(.passthrough)
    public static let nothing = Action(.none)
    public static let muteToggle = Action(.muteToggle)
    public static let modeNext = Action(.modeNext)
    public static let modePrevious = Action(.modePrevious)

    public static func volume(_ step: Double) -> Action {
        var a = Action(.volume); a.amount = step; return a
    }

    public static func monitor(_ dB: Double, auto: Bool = true) -> Action {
        var a = Action(.monitorLevel); a.amount = dB; a.auto = auto; return a
    }

    public static func monitorToggle(_ which: MonitorSwitch, auto: Bool = true) -> Action {
        var a = Action(.monitorToggle); a.monitorSwitch = which; a.auto = auto; return a
    }

    public static func media(_ key: MediaKey, fine: Bool = false) -> Action {
        var a = Action(.mediaKey); a.mediaKey = key; a.fine = fine; return a
    }

    public static func key(_ code: Int, _ mods: ModifierSet = [], count: Int = 1) -> Action {
        var a = Action(.keystroke); a.key = KeyCombo(code, mods); a.count = count; return a
    }

    public static func sticky(hold: ModifierSet, _ code: Int, _ extra: ModifierSet = [], releaseAfter: Double = 0.7) -> Action {
        var a = Action(.stickyKeystroke); a.hold = hold; a.key = KeyCombo(code, extra); a.releaseAfter = releaseAfter; return a
    }

    public static func scroll(dx: Double = 0, dy: Double = 0, unit: ScrollUnit = .pixel, smooth: Bool = true, mods: ModifierSet = []) -> Action {
        var a = Action(.scroll); a.dx = dx; a.dy = dy; a.unit = unit; a.smooth = smooth; a.hold = mods; return a
    }

    public static func text(_ kind: ActionKind, _ value: String) -> Action {
        var a = Action(kind); a.text = value; return a
    }

    public static func macro(_ steps: [MacroStep]) -> Action {
        var a = Action(.macro); a.steps = steps; return a
    }

    /// Short human description, used in the menu, the HUD and the binding grid.
    public var summary: String {
        switch kind {
        case .passthrough: return "System default"
        case .none: return "Do nothing"
        case .volume:
            let v = amount.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(amount.magnitude)) : String(format: "%.1f", amount.magnitude)
            return "Volume \(amount < 0 ? "−" : "+")\(v)%"
        case .muteToggle: return "Toggle mute"
        case .monitorLevel:
            let v = amount.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(amount.magnitude)) : String(format: "%.1f", amount.magnitude)
            return "Monitor \(amount < 0 ? "−" : "+")\(v) dB"
        case .monitorToggle: return "Monitor \(monitorSwitch.title.lowercased())"
        case .mediaKey: return mediaKey.title + (fine ? " (fine)" : "") + (count > 1 ? " ×\(count)" : "")
        case .keystroke: return key.display + (count > 1 ? " ×\(count)" : "")
        case .stickyKeystroke: return "Hold \(hold.symbols) + \(key.display)"
        case .typeText: return "Type “\(text.prefix(24))”"
        case .scroll:
            var parts: [String] = []
            let u = unit == .pixel ? "px" : " lines"
            if dy != 0 { parts.append("\(dy > 0 ? "↓" : "↑") \(Int(dy.magnitude))\(u)") }
            if dx != 0 { parts.append("\(dx > 0 ? "→" : "←") \(Int(dx.magnitude))\(u)") }
            return "Scroll " + (parts.isEmpty ? "0" : parts.joined(separator: " ")) + (hold.isEmpty ? "" : " with \(hold.symbols)")
        case .menuItem: return "Menu: " + text.replacingOccurrences(of: " > ", with: " ▸ ")
        case .shell: return "Shell: " + text.prefix(28)
        case .appleScript: return "AppleScript"
        case .shortcut: return "Shortcut: " + text
        case .open: return "Open " + (text as NSString).lastPathComponent
        case .modeNext: return "Next mode"
        case .modePrevious: return "Previous mode"
        case .modeSet: return "Mode: " + text
        case .macro: return "Macro (\(steps.count) steps)"
        }
    }
}

public struct MacroStep: Hashable, Sendable, Codable, Identifiable {
    public var id: UUID
    public var action: Action
    public var delayMs: Int

    public init(_ action: Action, delayMs: Int = 0) {
        self.id = UUID()
        self.action = action
        self.delayMs = delayMs
    }

    enum CodingKeys: String, CodingKey { case id, action, delayMs }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.val(.id, UUID())
        action = c.val(.action, .nothing)
        delayMs = c.val(.delayMs, 0)
    }
}

// MARK: - Bindings

public struct KnobBinding: Hashable, Sendable, Codable, Identifiable {
    public var id: UUID
    public var gesture: KnobGesture
    public var modifiers: ModifierSet
    public var speed: SpeedClass
    public var action: Action
    /// Scale the action by how fast the knob is spinning.
    public var accelerate: Bool
    /// Fire once per N detents. Makes coarse actions (tab switching, track skipping) less twitchy.
    public var everyNTicks: Int
    /// Optional name shown in the HUD and the menu instead of the action summary.
    public var label: String

    public init(_ gesture: KnobGesture, _ modifiers: ModifierSet = [], _ action: Action,
                speed: SpeedClass = .any, accelerate: Bool = false, every: Int = 1, label: String = "") {
        self.id = UUID()
        self.gesture = gesture
        self.modifiers = modifiers
        self.speed = speed
        self.action = action
        self.accelerate = accelerate
        self.everyNTicks = max(1, every)
        self.label = label
    }

    enum CodingKeys: String, CodingKey { case id, gesture, modifiers, speed, action, accelerate, everyNTicks, label }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.val(.id, UUID())
        gesture = try c.decode(KnobGesture.self, forKey: .gesture)
        modifiers = c.val(.modifiers, [])
        speed = c.val(.speed, .any)
        action = c.val(.action, .nothing)
        accelerate = c.val(.accelerate, false)
        everyNTicks = max(1, c.val(.everyNTicks, 1))
        label = c.val(.label, "")
    }

    public var displayName: String { label.isEmpty ? action.summary : label }
}

public struct KeyBinding: Hashable, Sendable, Codable, Identifiable {
    public var id: UUID
    public var key: KeyCombo
    public var action: Action
    /// Keep firing while the key is held down.
    public var repeats: Bool
    public var label: String

    public init(_ key: KeyCombo, _ action: Action, repeats: Bool = true, label: String = "") {
        self.id = UUID()
        self.key = key
        self.action = action
        self.repeats = repeats
        self.label = label
    }

    enum CodingKeys: String, CodingKey { case id, key, action, repeats, label }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.val(.id, UUID())
        key = c.val(.key, KeyCombo(49))
        action = c.val(.action, .nothing)
        repeats = c.val(.repeats, true)
        label = c.val(.label, "")
    }
}

// MARK: - Modes and profiles

/// A named set of bindings. Each profile has one always-on layer plus any number of
/// switchable modes; the knob cycles through the modes.
public struct Mode: Hashable, Sendable, Codable, Identifiable {
    public var id: UUID
    public var name: String
    public var symbol: String
    public var knob: [KnobBinding]
    public var keys: [KeyBinding]

    public init(_ name: String, symbol: String = "dial.medium", knob: [KnobBinding] = [], keys: [KeyBinding] = []) {
        self.id = UUID()
        self.name = name
        self.symbol = symbol
        self.knob = knob
        self.keys = keys
    }

    enum CodingKeys: String, CodingKey { case id, name, symbol, knob, keys }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.val(.id, UUID())
        name = c.val(.name, "Mode")
        symbol = c.val(.symbol, "dial.medium")
        knob = c.val(.knob, [])
        keys = c.val(.keys, [])
    }

    public func binding(_ gesture: KnobGesture, _ modifiers: ModifierSet, speed: SpeedClass) -> KnobBinding? {
        var fallback: KnobBinding?
        for b in knob where b.gesture == gesture && b.modifiers == modifiers {
            if b.speed == speed && speed != .any { return b }
            if b.speed == .any && fallback == nil { fallback = b }
        }
        return fallback
    }
}

public struct Profile: Hashable, Sendable, Codable, Identifiable {
    public var id: UUID
    public var name: String
    /// Bundle identifiers this profile applies to. A trailing `*` matches by prefix.
    public var bundleIDs: [String]
    /// Optional: only apply while the front window's title contains this text.
    public var titleContains: String
    public var enabled: Bool
    /// When a gesture has no binding here, fall through to the Global profile.
    public var inheritsGlobal: Bool
    /// Bindings that apply in every mode of this profile.
    public var always: Mode
    public var modes: [Mode]

    public init(_ name: String, bundleIDs: [String] = [], always: Mode = Mode("Always", symbol: "infinity"), modes: [Mode] = []) {
        self.id = UUID()
        self.name = name
        self.bundleIDs = bundleIDs
        self.titleContains = ""
        self.enabled = true
        self.inheritsGlobal = true
        self.always = always
        self.modes = modes
    }

    enum CodingKeys: String, CodingKey { case id, name, bundleIDs, titleContains, enabled, inheritsGlobal, always, modes }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.val(.id, UUID())
        name = c.val(.name, "Profile")
        bundleIDs = c.val(.bundleIDs, [])
        titleContains = c.val(.titleContains, "")
        enabled = c.val(.enabled, true)
        inheritsGlobal = c.val(.inheritsGlobal, true)
        always = c.val(.always, Mode("Always", symbol: "infinity"))
        modes = c.val(.modes, [])
    }

    public func matches(bundleID: String) -> Bool {
        bundleIDs.contains { pattern in
            if pattern.hasSuffix("*") { return bundleID.hasPrefix(String(pattern.dropLast())) }
            return pattern.caseInsensitiveCompare(bundleID) == .orderedSame
        }
    }
}

// MARK: - Settings

public enum DeviceMode: String, Codable, Sendable, CaseIterable {
    /// Only volume/mute events that came from a selected HID device count as the knob.
    case selected
    /// Every volume/mute key on any keyboard counts as the knob.
    case any
}

public struct DeviceRef: Hashable, Sendable, Codable, Identifiable {
    public var vendorID: Int
    public var productID: Int
    public var name: String
    public var transport: String

    public init(vendorID: Int, productID: Int, name: String, transport: String) {
        self.vendorID = vendorID
        self.productID = productID
        self.name = name
        self.transport = transport
    }

    public var id: String { "\(vendorID):\(productID)" }
}

public enum HUDPosition: String, Codable, Sendable, CaseIterable {
    case bottomCenter, topCenter, center, topRight

    public var title: String {
        switch self {
        case .bottomCenter: return "Bottom center"
        case .topCenter: return "Top center"
        case .center: return "Center"
        case .topRight: return "Top right"
        }
    }
}

/// What the Light show page plays on the keyboard.
public struct LightShowSettings: Hashable, Sendable, Codable {
    public enum Source: String, Codable, Sendable, CaseIterable {
        case text, image
    }

    public var source: Source = .text
    public var text = "I THINK YOU'RE AMAZING"
    /// Path of the chosen image file.
    public var imagePath = ""
    /// Text colour as RRGGBB.
    public var color = "FFFFFF"
    /// Key widths per second.
    public var speed = 8.0
    /// How many bands an image is read in (1 for a banner).
    public var lines = 1
    public var brightness = 1.0
    public var softEdges = false
    /// Keep the picture upright over the staggered rows (see `LightShow.upright`).
    public var upright = true
    public var wholeKeySteps = false
    /// Most frames a second to send. 21 is the pace of the vendor's own app.
    public var frameRateLimit = 21.0
    public var loop = true

    public init() {}

    enum CodingKeys: String, CodingKey {
        case source, text, imagePath, color, speed, lines, brightness, softEdges, upright, wholeKeySteps, frameRateLimit, loop
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = LightShowSettings()
        source = c.val(.source, d.source)
        text = c.val(.text, d.text)
        imagePath = c.val(.imagePath, d.imagePath)
        color = c.val(.color, d.color)
        speed = c.val(.speed, d.speed)
        lines = c.val(.lines, d.lines)
        brightness = c.val(.brightness, d.brightness)
        softEdges = c.val(.softEdges, d.softEdges)
        upright = c.val(.upright, d.upright)
        wholeKeySteps = c.val(.wholeKeySteps, d.wholeKeySteps)
        frameRateLimit = c.val(.frameRateLimit, d.frameRateLimit)
        loop = c.val(.loop, d.loop)
    }
}

public struct Settings: Hashable, Sendable, Codable {
    public var enabled = true
    public var deviceMode: DeviceMode = .selected
    public var devices: [DeviceRef] = []
    public var invertRotation = false

    public var showHUD = true
    public var hudOnEveryAction = false
    public var hudPosition: HUDPosition = .bottomCenter
    public var hudDuration = 1.1
    public var menuBarShowsModeName = false
    /// Flash the keyboard's lights when KnobKit picks it up.
    public var flashOnConnect = true
    public var lightShow = LightShowSettings()

    /// Highest level (dB) the knob may raise an Apollo monitor output to.
    public var monitorCeiling = -20.0

    /// Max gap between presses for a double/triple press (seconds).
    public var doublePressInterval = 0.35
    public var longPressDuration = 0.5
    /// A press released within this window of a rotation tick is treated as still held.
    public var chordGrace = 0.03
    public var virtualHoldTimeout = 0.7

    /// Detents per second where acceleration starts and where it tops out.
    /// Calibrated on the F75 over Bluetooth: an ordinary continuous turn reports about
    /// 15 to 25 detents per second and a quick spin saturates near 33.
    public var accelSlowRate = 16.0
    public var accelFastRate = 32.0
    public var accelMaxMultiplier = 4.0
    /// Detents per second above which a turn counts as "fast".
    public var fastThreshold = 28.0

    public init() {}

    enum CodingKeys: String, CodingKey {
        case enabled, deviceMode, devices, invertRotation
        case showHUD, hudOnEveryAction, hudPosition, hudDuration, menuBarShowsModeName
        case doublePressInterval, longPressDuration, chordGrace, virtualHoldTimeout
        case accelSlowRate, accelFastRate, accelMaxMultiplier, fastThreshold
        case monitorCeiling, flashOnConnect, lightShow
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        enabled = c.val(.enabled, d.enabled)
        deviceMode = c.val(.deviceMode, d.deviceMode)
        devices = c.val(.devices, d.devices)
        invertRotation = c.val(.invertRotation, d.invertRotation)
        showHUD = c.val(.showHUD, d.showHUD)
        hudOnEveryAction = c.val(.hudOnEveryAction, d.hudOnEveryAction)
        hudPosition = c.val(.hudPosition, d.hudPosition)
        hudDuration = c.val(.hudDuration, d.hudDuration)
        menuBarShowsModeName = c.val(.menuBarShowsModeName, d.menuBarShowsModeName)
        doublePressInterval = c.val(.doublePressInterval, d.doublePressInterval)
        longPressDuration = c.val(.longPressDuration, d.longPressDuration)
        chordGrace = c.val(.chordGrace, d.chordGrace)
        virtualHoldTimeout = c.val(.virtualHoldTimeout, d.virtualHoldTimeout)
        accelSlowRate = c.val(.accelSlowRate, d.accelSlowRate)
        accelFastRate = c.val(.accelFastRate, d.accelFastRate)
        accelMaxMultiplier = c.val(.accelMaxMultiplier, d.accelMaxMultiplier)
        fastThreshold = c.val(.fastThreshold, d.fastThreshold)
        monitorCeiling = c.val(.monitorCeiling, d.monitorCeiling)
        flashOnConnect = c.val(.flashOnConnect, d.flashOnConnect)
        lightShow = c.val(.lightShow, d.lightShow)
    }
}

// MARK: - Config root

public struct Config: Hashable, Sendable, Codable {
    public var version: Int
    public var settings: Settings
    public var global: Profile
    public var profiles: [Profile]

    public static let currentVersion = 3

    public init(settings: Settings = Settings(), global: Profile, profiles: [Profile] = []) {
        self.version = Self.currentVersion
        self.settings = settings
        self.global = global
        self.profiles = profiles
    }

    enum CodingKeys: String, CodingKey { case version, settings, global, profiles }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = c.val(.version, 1)
        settings = c.val(.settings, Settings())
        global = try c.decode(Profile.self, forKey: .global)
        profiles = c.val(.profiles, [])
        if global.modes.isEmpty { global.modes = [Mode("Default")] }
    }

    /// Brings a config written by an older build up to date. Returns true if it changed.
    @discardableResult
    public mutating func migrate() -> Bool {
        guard version < Self.currentVersion else { return false }
        if version < 2 {
            // Version 1 shipped speed thresholds guessed before any real knob data. Only
            // values still at those old defaults are replaced; anything tuned by hand stays.
            if settings.fastThreshold == 14 { settings.fastThreshold = 28 }
            if settings.accelSlowRate == 6 { settings.accelSlowRate = 16 }
            if settings.accelFastRate == 25 { settings.accelFastRate = 32 }
        }
        if version < 3 {
            // The F75 sends a knob press as a ~20 ms tap however long it is held, so long
            // press and hold-and-turn never fire. If the stock mode-switch bindings are
            // still in place, move them to double / triple press.
            let stock = global.always.knob
            let hasStockLong = stock.contains { $0.gesture == .longPress && $0.modifiers.isEmpty && $0.action.kind == .modeNext }
            let hasStockDouble = stock.contains { $0.gesture == .doublePress && $0.modifiers.isEmpty && $0.action == .media(.playPause) }
            if hasStockLong && hasStockDouble {
                global.always.knob.removeAll { b in
                    guard b.modifiers.isEmpty else { return false }
                    switch b.gesture {
                    case .longPress, .pressRotateCW: return b.action.kind == .modeNext
                    case .pressRotateCCW: return b.action.kind == .modePrevious
                    case .doublePress: return true
                    default: return false
                    }
                }
                global.always.knob.insert(contentsOf: [
                    KnobBinding(.doublePress, [], .modeNext, label: "Next mode"),
                    KnobBinding(.triplePress, [], .modePrevious, label: "Previous mode"),
                ], at: 0)
                if global.always.binding(.press, .option, speed: .any) == nil {
                    global.always.knob.append(KnobBinding(.press, .option, .media(.playPause)))
                }
            }
            if settings.doublePressInterval == 0.28 { settings.doublePressInterval = 0.35 }
        }
        version = Self.currentVersion
        return true
    }

    public func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try enc.encode(self)
    }

    public static func decode(_ data: Data) throws -> Config {
        try JSONDecoder().decode(Config.self, from: data)
    }
}
