import Foundation

/// A clockwise/counter-clockwise pair that can be dropped onto a rotation row in one click.
public struct TurnPreset: Identifiable, Sendable {
    public var name: String
    public var group: String
    public var cw: Action
    public var ccw: Action
    public var accelerate: Bool
    public var every: Int

    public var id: String { name }

    public init(_ name: String, group: String, cw: Action, ccw: Action, accelerate: Bool = false, every: Int = 1) {
        self.name = name
        self.group = group
        self.cw = cw
        self.ccw = ccw
        self.accelerate = accelerate
        self.every = every
    }

    public func bindings(pressRotate: Bool = false, modifiers: ModifierSet = []) -> [KnobBinding] {
        [
            KnobBinding(pressRotate ? .pressRotateCW : .rotateCW, modifiers, cw, accelerate: accelerate, every: every, label: name),
            KnobBinding(pressRotate ? .pressRotateCCW : .rotateCCW, modifiers, ccw, accelerate: accelerate, every: every, label: name),
        ]
    }
}

public enum Presets {
    public static let turns: [TurnPreset] = [
        TurnPreset("System volume", group: "Sound", cw: .passthrough, ccw: .passthrough),
        TurnPreset("Fine volume (1%)", group: "Sound", cw: .volume(1), ccw: .volume(-1)),
        TurnPreset("Volume with acceleration", group: "Sound", cw: .volume(2), ccw: .volume(-2), accelerate: true),
        TurnPreset("Next / previous track", group: "Sound", cw: .media(.next), ccw: .media(.previous), every: 3),
        TurnPreset("Apollo monitor level (1 dB)", group: "Sound", cw: .monitor(1), ccw: .monitor(-1)),
        TurnPreset("Apollo monitor level, fine (0.5 dB)", group: "Sound", cw: .monitor(0.5), ccw: .monitor(-0.5)),

        TurnPreset("Display brightness", group: "Display", cw: .media(.brightnessUp), ccw: .media(.brightnessDown)),
        TurnPreset("Fine brightness", group: "Display", cw: .media(.brightnessUp, fine: true), ccw: .media(.brightnessDown, fine: true)),

        TurnPreset("Scroll vertically", group: "Scroll", cw: .scroll(dy: 70), ccw: .scroll(dy: -70), accelerate: true),
        TurnPreset("Scroll horizontally", group: "Scroll", cw: .scroll(dx: 70), ccw: .scroll(dx: -70), accelerate: true),
        TurnPreset("Page down / up", group: "Scroll", cw: .key(Key.pageDown), ccw: .key(Key.pageUp), every: 2),

        TurnPreset("Zoom (⌘= / ⌘−)", group: "Zoom", cw: .key(Key.equal, .command), ccw: .key(Key.minus, .command)),
        TurnPreset("Zoom (⌘ scroll)", group: "Zoom", cw: .scroll(dy: -24, smooth: false, mods: .command), ccw: .scroll(dy: 24, smooth: false, mods: .command)),
        TurnPreset("Zoom (⌃ scroll / pinch)", group: "Zoom", cw: .scroll(dy: -24, smooth: false, mods: .control), ccw: .scroll(dy: 24, smooth: false, mods: .control)),

        TurnPreset("Switch tabs (⌃⇥)", group: "Switch", cw: .key(Key.tab, .control), ccw: .key(Key.tab, [.control, .shift]), every: 2),
        TurnPreset("Switch apps (⌘⇥ held)", group: "Switch", cw: .sticky(hold: .command, Key.tab), ccw: .sticky(hold: .command, Key.tab, .shift), every: 2),
        TurnPreset("Switch windows (⌘`)", group: "Switch", cw: .key(Key.grave, .command), ccw: .key(Key.grave, [.command, .shift]), every: 2),
        TurnPreset("Switch Spaces (⌃← / ⌃→)", group: "Switch", cw: .key(Key.right, .control), ccw: .key(Key.left, .control), every: 4),
        TurnPreset("Next / previous mode", group: "Switch", cw: .modeNext, ccw: .modePrevious, every: 2),

        TurnPreset("Undo / Redo", group: "Edit", cw: .key(Key.z, [.command, .shift]), ccw: .key(Key.z, .command)),
        TurnPreset("Arrows ← →", group: "Edit", cw: .key(Key.right), ccw: .key(Key.left)),
        TurnPreset("Arrows ↑ ↓", group: "Edit", cw: .key(Key.down), ccw: .key(Key.up)),
        TurnPreset("Brackets [ ] (brush size)", group: "Edit", cw: .key(Key.rightBracket), ccw: .key(Key.leftBracket)),
        TurnPreset("Comma / period (nudge)", group: "Edit", cw: .key(Key.period), ccw: .key(Key.comma)),
        TurnPreset("J / L (shuttle)", group: "Edit", cw: .key(Key.l), ccw: .key(Key.j), every: 3),
    ]

    public static var turnGroups: [(String, [TurnPreset])] {
        var order: [String] = []
        var map: [String: [TurnPreset]] = [:]
        for p in turns {
            if map[p.group] == nil { order.append(p.group) }
            map[p.group, default: []].append(p)
        }
        return order.map { ($0, map[$0]!) }
    }

    /// SF Symbols offered for mode icons.
    public static let modeSymbols: [String] = [
        "dial.medium", "dial.low", "dial.high", "speaker.wave.2.fill", "speaker.slash.fill", "music.note",
        "playpause.fill", "forward.fill", "backward.fill", "film", "scissors", "timeline.selection",
        "arrow.up.arrow.down", "arrow.left.arrow.right", "arrow.left.and.right", "plus.magnifyingglass",
        "minus.magnifyingglass", "arrow.uturn.backward", "clock.arrow.circlepath", "sun.max.fill",
        "paintbrush.fill", "paintbrush.pointed.fill", "pencil.tip", "eyedropper", "square.on.square",
        "rectangle.stack", "macwindow", "rectangle.split.3x1", "square.grid.2x2", "globe", "safari",
        "chevron.left.forwardslash.chevron.right", "terminal", "keyboard", "command", "cursorarrow",
        "hand.draw", "slider.horizontal.3", "waveform", "mic.fill", "camera.fill", "sparkles", "bolt.fill",
        "star.fill", "infinity",
    ]
}

// MARK: - Default configuration

extension Config {
    /// Out-of-the-box configuration: a Global profile with five modes and common modifier layers.
    public static func makeDefault(profiles: [Profile] = []) -> Config {
        var global = Profile("Global")
        global.always = Mode("Always", symbol: "infinity", knob: [
            // The F75 reports a knob press as an instant tap, so mode switching lives on
            // multi-presses rather than long press or hold-and-turn.
            KnobBinding(.doublePress, [], .modeNext, label: "Next mode"),
            KnobBinding(.triplePress, [], .modePrevious, label: "Previous mode"),
            KnobBinding(.press, .option, .media(.playPause)),

            KnobBinding(.rotateCW, .option, .volume(1), label: "Fine volume"),
            KnobBinding(.rotateCCW, .option, .volume(-1), label: "Fine volume"),
            KnobBinding(.rotateCW, .shift, .media(.brightnessUp), label: "Brightness"),
            KnobBinding(.rotateCCW, .shift, .media(.brightnessDown), label: "Brightness"),
            KnobBinding(.rotateCW, .command, .key(Key.tab, .command), every: 2, label: "Next app"),
            KnobBinding(.rotateCCW, .command, .key(Key.tab, [.command, .shift]), every: 2, label: "Previous app"),
            KnobBinding(.rotateCW, .control, .key(Key.tab, .control), every: 2, label: "Next tab"),
            KnobBinding(.rotateCCW, .control, .key(Key.tab, [.control, .shift]), every: 2, label: "Previous tab"),
        ])
        global.modes = [
            Mode("Volume", symbol: "speaker.wave.2.fill", knob: [
                KnobBinding(.rotateCW, [], .passthrough, label: "Volume up"),
                KnobBinding(.rotateCCW, [], .passthrough, label: "Volume down"),
                KnobBinding(.press, [], .passthrough, label: "Mute"),
            ]),
            Mode("Scroll", symbol: "arrow.up.arrow.down", knob: [
                KnobBinding(.rotateCW, [], .scroll(dy: 70), accelerate: true, label: "Scroll down"),
                KnobBinding(.rotateCCW, [], .scroll(dy: -70), accelerate: true, label: "Scroll up"),
                KnobBinding(.rotateCW, .shift, .scroll(dx: 70), accelerate: true, label: "Scroll right"),
                KnobBinding(.rotateCCW, .shift, .scroll(dx: -70), accelerate: true, label: "Scroll left"),
            ]),
            Mode("Zoom", symbol: "plus.magnifyingglass", knob: [
                KnobBinding(.rotateCW, [], .key(Key.equal, .command), label: "Zoom in"),
                KnobBinding(.rotateCCW, [], .key(Key.minus, .command), label: "Zoom out"),
                KnobBinding(.press, [], .key(Key.zero, .command), label: "Actual size"),
            ]),
            Mode("Media", symbol: "playpause.fill", knob: [
                KnobBinding(.rotateCW, [], .media(.next), every: 3, label: "Next track"),
                KnobBinding(.rotateCCW, [], .media(.previous), every: 3, label: "Previous track"),
                KnobBinding(.press, [], .media(.playPause)),
            ]),
            Mode("History", symbol: "clock.arrow.circlepath", knob: [
                KnobBinding(.rotateCW, [], .key(Key.z, [.command, .shift]), label: "Redo"),
                KnobBinding(.rotateCCW, [], .key(Key.z, .command), label: "Undo"),
            ]),
        ]
        return Config(global: global, profiles: profiles)
    }
}

// MARK: - Universal Audio

public enum MonitorLevel {
    /// The level (dB) a knob step should produce, on the mixer's 0.5 dB grid.
    ///
    /// Safety rules: an increase never ends above `ceiling`; a level that is already at
    /// or above the ceiling (set on the hardware) is left exactly where it is rather
    /// than pulled down; decreases are always allowed down to the device minimum.
    public static func next(current: Double, delta: Double, ceiling: Double, range: ClosedRange<Double>) -> Double {
        func grid(_ x: Double) -> Double { (x * 2).rounded() / 2 }
        let top = min(ceiling, range.upperBound)
        if delta > 0 {
            if current >= top { return current }
            return min(grid(current + delta), top)
        }
        if delta < 0 {
            return max(grid(current + delta), range.lowerBound)
        }
        return current
    }
}

extension Config {
    /// Points the Global profile's volume controls at the Apollo monitor output:
    /// plain turns and presses that were "System default", and custom-step volume
    /// bindings. The monitor actions fall back to the Mac's own volume on outputs that
    /// have one, so nothing is lost on headphones or built-in speakers.
    /// Returns how many bindings changed.
    @discardableResult
    public mutating func adoptMonitorVolume() -> Int {
        var changed = 0
        func convert(_ mode: inout Mode) {
            for i in mode.knob.indices {
                let b = mode.knob[i]
                switch (b.action.kind, b.gesture) {
                case (.passthrough, .rotateCW) where b.modifiers.isEmpty:
                    mode.knob[i].action = .monitor(1)
                case (.passthrough, .rotateCCW) where b.modifiers.isEmpty:
                    mode.knob[i].action = .monitor(-1)
                case (.passthrough, .press) where b.modifiers.isEmpty:
                    mode.knob[i].action = .monitorToggle(.mute)
                case (.volume, _):
                    mode.knob[i].action = .monitor(b.action.amount < 0 ? -0.5 : 0.5)
                default:
                    continue
                }
                changed += 1
            }
        }
        convert(&global.always)
        for i in global.modes.indices { convert(&global.modes[i]) }
        return changed
    }
}

// MARK: - App profile templates

public struct ProfileTemplate: Identifiable, Sendable {
    public var name: String
    public var bundleIDs: [String]
    /// Added on first launch when one of the apps is installed.
    public var installByDefault: Bool
    public var build: @Sendable () -> Profile

    public var id: String { name }
}

public enum Templates {
    private static func turn(_ cw: Action, _ ccw: Action, _ mods: ModifierSet = [], speed: SpeedClass = .any,
                             every: Int = 1, cwLabel: String = "", ccwLabel: String = "") -> [KnobBinding] {
        [
            KnobBinding(.rotateCW, mods, cw, speed: speed, every: every, label: cwLabel),
            KnobBinding(.rotateCCW, mods, ccw, speed: speed, every: every, label: ccwLabel),
        ]
    }

    public static let all: [ProfileTemplate] = [
        ProfileTemplate(name: "DaVinci Resolve",
                        bundleIDs: ["com.blackmagic-design.DaVinciResolve", "com.blackmagic-design.DaVinciResolveLite"],
                        installByDefault: true) {
            var p = Profile("DaVinci Resolve", bundleIDs: ["com.blackmagic-design.DaVinciResolve", "com.blackmagic-design.DaVinciResolveLite"])
            p.always = Mode("Always", symbol: "infinity", knob:
                turn(.key(Key.equal, .command), .key(Key.minus, .command), .option, cwLabel: "Zoom timeline in", ccwLabel: "Zoom timeline out")
                + turn(.key(Key.right, .shift), .key(Key.left, .shift), .shift, cwLabel: "1 second forward", ccwLabel: "1 second back"))
            p.modes = [
                Mode("Jog", symbol: "film", knob:
                    turn(.key(Key.right), .key(Key.left), cwLabel: "Frame forward", ccwLabel: "Frame back")
                    + turn(.key(Key.right, .shift), .key(Key.left, .shift), speed: .fast, cwLabel: "1 second forward", ccwLabel: "1 second back")
                    + [KnobBinding(.press, [], .key(Key.space), label: "Play / Stop")]),
                Mode("Edits", symbol: "scissors", knob:
                    turn(.key(Key.down), .key(Key.up), every: 2, cwLabel: "Next edit", ccwLabel: "Previous edit")
                    + [KnobBinding(.press, [], .key(Key.space), label: "Play / Stop")]),
                Mode("Timeline zoom", symbol: "plus.magnifyingglass", knob:
                    turn(.key(Key.equal, .command), .key(Key.minus, .command), cwLabel: "Zoom in", ccwLabel: "Zoom out")
                    + [KnobBinding(.press, [], .key(Key.z, .shift), label: "Zoom to fit")]),
                Mode("Nudge", symbol: "arrow.left.and.right", knob:
                    turn(.key(Key.period), .key(Key.comma), cwLabel: "Nudge right", ccwLabel: "Nudge left")
                    + turn(.key(Key.period, .shift), .key(Key.comma, .shift), speed: .fast, cwLabel: "Nudge right ×5", ccwLabel: "Nudge left ×5")
                    + [KnobBinding(.press, [], .key(Key.space), label: "Play / Stop")]),
                Mode("Shuttle", symbol: "forward.fill", knob:
                    turn(.key(Key.l), .key(Key.j), every: 3, cwLabel: "Shuttle forward", ccwLabel: "Shuttle back")
                    + [KnobBinding(.press, [], .key(Key.k), label: "Stop")]),
            ]
            return p
        },
        ProfileTemplate(name: "Photoshop", bundleIDs: ["com.adobe.Photoshop"], installByDefault: true) {
            var p = Profile("Photoshop", bundleIDs: ["com.adobe.Photoshop"])
            p.always = Mode("Always", symbol: "infinity", knob:
                turn(.key(Key.equal, .command), .key(Key.minus, .command), .option, cwLabel: "Zoom in", ccwLabel: "Zoom out")
                + turn(.key(Key.rightBracket, .shift), .key(Key.leftBracket, .shift), .shift, cwLabel: "Harder brush", ccwLabel: "Softer brush"))
            p.modes = [
                Mode("Brush size", symbol: "paintbrush.fill", knob:
                    turn(.key(Key.rightBracket), .key(Key.leftBracket), cwLabel: "Bigger brush", ccwLabel: "Smaller brush")
                    + [KnobBinding(.press, [], .key(Key.x), label: "Swap colors")]),
                Mode("Zoom", symbol: "plus.magnifyingglass", knob:
                    turn(.key(Key.equal, .command), .key(Key.minus, .command), cwLabel: "Zoom in", ccwLabel: "Zoom out")
                    + [KnobBinding(.press, [], .key(Key.zero, .command), label: "Fit on screen")]),
                Mode("History", symbol: "clock.arrow.circlepath", knob:
                    turn(.key(Key.z, [.command, .shift]), .key(Key.z, .command), cwLabel: "Redo", ccwLabel: "Undo")),
            ]
            return p
        },
        ProfileTemplate(name: "Premiere Pro", bundleIDs: ["com.adobe.PremierePro*"], installByDefault: false) {
            var p = Profile("Premiere Pro", bundleIDs: ["com.adobe.PremierePro*"])
            p.modes = [
                Mode("Jog", symbol: "film", knob:
                    turn(.key(Key.right), .key(Key.left), cwLabel: "Frame forward", ccwLabel: "Frame back")
                    + turn(.key(Key.right, .shift), .key(Key.left, .shift), speed: .fast, cwLabel: "5 frames forward", ccwLabel: "5 frames back")
                    + [KnobBinding(.press, [], .key(Key.space), label: "Play / Stop")]),
                Mode("Edits", symbol: "scissors", knob:
                    turn(.key(Key.down), .key(Key.up), every: 2, cwLabel: "Next edit", ccwLabel: "Previous edit")),
                Mode("Timeline zoom", symbol: "plus.magnifyingglass", knob:
                    turn(.key(Key.equal), .key(Key.minus), cwLabel: "Zoom in", ccwLabel: "Zoom out")
                    + [KnobBinding(.press, [], .key(Key.backslash), label: "Zoom to sequence")]),
            ]
            return p
        },
        ProfileTemplate(name: "After Effects", bundleIDs: ["com.adobe.AfterEffects*"], installByDefault: false) {
            var p = Profile("After Effects", bundleIDs: ["com.adobe.AfterEffects*"])
            p.modes = [
                Mode("Jog", symbol: "film", knob:
                    turn(.key(Key.pageDown), .key(Key.pageUp), cwLabel: "Frame forward", ccwLabel: "Frame back")
                    + turn(.key(Key.pageDown, .shift), .key(Key.pageUp, .shift), speed: .fast, cwLabel: "10 frames forward", ccwLabel: "10 frames back")
                    + [KnobBinding(.press, [], .key(Key.space), label: "Preview")]),
                Mode("Timeline zoom", symbol: "plus.magnifyingglass", knob:
                    turn(.key(Key.equal), .key(Key.minus), cwLabel: "Zoom in", ccwLabel: "Zoom out")),
            ]
            return p
        },
        ProfileTemplate(name: "Figma", bundleIDs: ["com.figma.Desktop"], installByDefault: false) {
            var p = Profile("Figma", bundleIDs: ["com.figma.Desktop"])
            p.always = Mode("Always", symbol: "infinity", knob:
                turn(.key(Key.equal, .command), .key(Key.minus, .command), .option, cwLabel: "Zoom in", ccwLabel: "Zoom out"))
            p.modes = [
                Mode("Zoom", symbol: "plus.magnifyingglass", knob:
                    turn(.key(Key.equal, .command), .key(Key.minus, .command), cwLabel: "Zoom in", ccwLabel: "Zoom out")
                    + [KnobBinding(.press, [], .key(Key.one, .shift), label: "Zoom to fit")]),
                Mode("Pan", symbol: "arrow.up.arrow.down", knob: [
                    KnobBinding(.rotateCW, [], .scroll(dy: 70), accelerate: true, label: "Pan down"),
                    KnobBinding(.rotateCCW, [], .scroll(dy: -70), accelerate: true, label: "Pan up"),
                    KnobBinding(.rotateCW, .shift, .scroll(dx: 70), accelerate: true, label: "Pan right"),
                    KnobBinding(.rotateCCW, .shift, .scroll(dx: -70), accelerate: true, label: "Pan left"),
                ]),
            ]
            return p
        },
        ProfileTemplate(name: "Browsers",
                        bundleIDs: ["com.google.Chrome", "com.apple.Safari", "org.mozilla.firefox", "company.thebrowser.Browser",
                                    "com.microsoft.edgemac", "com.brave.Browser", "com.openai.atlas"],
                        installByDefault: true) {
            var p = Profile("Browsers", bundleIDs: ["com.google.Chrome", "com.apple.Safari", "org.mozilla.firefox",
                                                    "company.thebrowser.Browser", "com.microsoft.edgemac", "com.brave.Browser",
                                                    "com.openai.atlas"])
            p.always = Mode("Always", symbol: "infinity", knob:
                turn(.key(Key.equal, .command), .key(Key.minus, .command), .option, cwLabel: "Page zoom in", ccwLabel: "Page zoom out")
                + [KnobBinding(.press, .option, .key(Key.zero, .command), label: "Reset page zoom")])
            return p
        },
        ProfileTemplate(name: "Code editors",
                        bundleIDs: ["com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.apple.dt.Xcode",
                                    "com.sublimetext.4", "dev.zed.Zed"],
                        installByDefault: false) {
            var p = Profile("Code editors", bundleIDs: ["com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92",
                                                        "com.apple.dt.Xcode", "com.sublimetext.4", "dev.zed.Zed"])
            p.always = Mode("Always", symbol: "infinity", knob:
                turn(.key(Key.equal, .command), .key(Key.minus, .command), .option, cwLabel: "Bigger text", ccwLabel: "Smaller text"))
            return p
        },
    ]
}
