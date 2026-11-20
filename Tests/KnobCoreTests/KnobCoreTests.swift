import XCTest
@testable import KnobCore

/// Virtual clock so gesture timing is tested deterministically.
final class ManualScheduler: KnobScheduler {
    final class T: KnobTimer {
        let fireAt: TimeInterval
        let block: () -> Void
        var cancelled = false
        init(fireAt: TimeInterval, block: @escaping () -> Void) { self.fireAt = fireAt; self.block = block }
        func cancel() { cancelled = true }
    }

    var now: TimeInterval = 0
    private var timers: [T] = []

    func schedule(after delay: TimeInterval, _ block: @escaping () -> Void) -> KnobTimer {
        let t = T(fireAt: now + delay, block: block)
        timers.append(t)
        return t
    }

    func advance(to time: TimeInterval) {
        while let next = timers.filter({ !$0.cancelled && $0.fireAt <= time }).min(by: { $0.fireAt < $1.fireAt }) {
            now = next.fireAt
            next.cancelled = true
            next.block()
        }
        timers.removeAll { $0.cancelled }
        now = time
    }
}

final class GestureEngineTests: XCTestCase {
    var clock: ManualScheduler!
    var engine: GestureEngine!
    var got: [KnobGesture] = []
    var bound: Set<KnobGesture> = []

    override func setUp() {
        clock = ManualScheduler()
        engine = GestureEngine(scheduler: clock)
        got = []
        bound = Set(KnobGesture.allCases)
        engine.needs = { [unowned self] in self.bound.contains($0) }
        engine.onGesture = { [unowned self] in self.got.append($0.gesture) }
    }

    private func down(_ t: TimeInterval) { clock.advance(to: t); engine.pressDown(at: t) }
    private func up(_ t: TimeInterval) { clock.advance(to: t); engine.pressUp(at: t) }
    @discardableResult private func tick(_ t: TimeInterval, cw: Bool = true) -> GestureEvent {
        clock.advance(to: t)
        return engine.tick(clockwise: cw, at: t)
    }

    func testPlainRotation() {
        XCTAssertEqual(tick(0).gesture, .rotateCW)
        XCTAssertEqual(tick(0.2, cw: false).gesture, .rotateCCW)
    }

    func testSingleClickIsImmediateWhenNothingSlowerIsBound() {
        bound = [.press]
        down(0); up(0.08)
        XCTAssertEqual(got, [.press])
    }

    func testSingleClickWaitsForDoubleWindow() {
        bound = [.press, .doublePress]
        down(0); up(0.08)
        XCTAssertEqual(got, [])
        clock.advance(to: 0.6)
        XCTAssertEqual(got, [.press])
    }

    func testDoubleClick() {
        bound = [.press, .doublePress]
        down(0); up(0.06); down(0.18); up(0.24)
        XCTAssertEqual(got, [.doublePress])
        clock.advance(to: 1)
        XCTAssertEqual(got, [.doublePress])
    }

    func testTripleClick() {
        bound = [.press, .doublePress, .triplePress]
        down(0); up(0.05); down(0.15); up(0.2); down(0.3); up(0.35)
        XCTAssertEqual(got, [.triplePress])
    }

    func testLongPressFiresWhileHeldAndSuppressesClick() {
        bound = [.press, .longPress]
        down(0)
        clock.advance(to: 0.6)
        XCTAssertEqual(got, [.longPress])
        up(0.9)
        clock.advance(to: 2)
        XCTAssertEqual(got, [.longPress])
    }

    func testHoldAndTurnWithSteadyPress() {
        down(0)
        XCTAssertEqual(tick(0.1).gesture, .pressRotateCW)
        XCTAssertEqual(tick(0.2, cw: false).gesture, .pressRotateCCW)
        up(0.5)
        clock.advance(to: 2)
        XCTAssertEqual(got, [], "a hold-and-turn must not also count as a click or long press")
        XCTAssertEqual(tick(2.1).gesture, .rotateCW)
    }

    /// Firmware swaps the single consumer slot: mute is released in the same report the tick arrives in.
    func testHoldAndTurnWhenReleaseArrivesJustBeforeTick() {
        down(0)
        up(0.200)
        XCTAssertEqual(tick(0.201).gesture, .pressRotateCW)
        XCTAssertEqual(tick(0.3).gesture, .pressRotateCW)
        clock.advance(to: 2)
        XCTAssertEqual(got, [])
        XCTAssertEqual(tick(2.1).gesture, .rotateCW, "virtual hold ends after the timeout")
    }

    func testHoldAndTurnWhenTickArrivesJustBeforeRelease() {
        down(0)
        XCTAssertEqual(tick(0.200).gesture, .pressRotateCW)
        up(0.201)
        XCTAssertEqual(tick(0.3).gesture, .pressRotateCW, "release inside the grace window keeps the hold")
        down(0.31)
        XCTAssertEqual(tick(0.4).gesture, .pressRotateCW)
        up(0.8)
        XCTAssertEqual(tick(0.9).gesture, .rotateCW, "a real release ends the hold")
        clock.advance(to: 3)
        XCTAssertEqual(got, [])
    }

    func testClickStillWorksWhenHoldAndTurnIsBound() {
        bound = [.press, .pressRotateCW, .pressRotateCCW]
        down(0); up(0.08)
        XCTAssertEqual(got, [], "waits one grace window for a possible tick")
        clock.advance(to: 0.2)
        XCTAssertEqual(got, [.press])
    }

    func testSpeedAndAcceleration() {
        // Real F75 figures: ~20 detents/s is an ordinary turn, 33+/s is a spin.
        var e = tick(0)
        XCTAssertEqual(e.speed, .slow)
        XCTAssertEqual(e.multiplier, 1, accuracy: 0.001)
        // 5 detents per second: below the acceleration floor.
        e = tick(0.2)
        XCTAssertEqual(e.speed, .slow)
        XCTAssertEqual(e.multiplier, 1, accuracy: 0.001)
        // An ordinary continuous turn (20/s) is still "slow" and barely accelerated.
        for i in 1...6 { e = tick(0.5 + Double(i) * 0.05) }
        XCTAssertEqual(e.speed, .slow)
        XCTAssertLessThan(e.multiplier, 2)
        // Spin at 50 detents per second.
        for i in 1...6 { e = tick(1.0 + Double(i) * 0.02) }
        XCTAssertEqual(e.speed, .fast)
        XCTAssertGreaterThan(e.multiplier, 3.5)
        // Reversing direction resets the measurement.
        e = tick(1.13, cw: false)
        XCTAssertEqual(e.multiplier, 1, accuracy: 0.001)
    }
}

final class ResolverTests: XCTestCase {
    private func makeConfig() -> Config {
        var app = Profile("Editor", bundleIDs: ["com.example.editor", "com.vendor.Suite*"])
        app.modes = [
            Mode("Jog", knob: [
                KnobBinding(.rotateCW, [], .key(Key.right)),
                KnobBinding(.rotateCW, [], .key(Key.right, .shift), speed: .fast),
            ]),
            Mode("Zoom", knob: [KnobBinding(.rotateCW, [], .key(Key.equal, .command))]),
        ]
        app.always = Mode("Always", knob: [KnobBinding(.rotateCW, .option, .key(Key.up))])
        return Config.makeDefault(profiles: [app])
    }

    private func ctx(_ c: Config, _ bundle: String?, modes: [UUID: Int] = [:]) -> ActiveContext {
        Resolver.context(config: c, bundleID: bundle, title: { nil }, modeIndex: modes)
    }

    func testGlobalWhenNoProfileMatches() {
        let c = ctx(makeConfig(), "com.other.app")
        XCTAssertNil(c.app)
        let r = c.binding(.rotateCW, [])
        XCTAssertEqual(r?.source, .globalMode)
        XCTAssertEqual(r?.binding.action.kind, .passthrough)
        XCTAssertEqual(c.binding(.doublePress, [])?.source, .globalAlways)
    }

    func testAppModeWinsAndFallsThrough() {
        let c = ctx(makeConfig(), "com.example.editor")
        XCTAssertEqual(c.binding(.rotateCW, [], speed: .slow)?.binding.action.key, KeyCombo(Key.right))
        XCTAssertEqual(c.binding(.rotateCW, [], speed: .fast)?.binding.action.key, KeyCombo(Key.right, .shift))
        XCTAssertEqual(c.binding(.rotateCW, .option)?.source, .appAlways)
        // Not bound by the app: falls through to Global.
        XCTAssertEqual(c.binding(.rotateCCW, [])?.source, .globalMode)
        XCTAssertEqual(c.binding(.rotateCW, .command)?.source, .globalAlways)
    }

    func testPrefixMatchAndModeIndex() {
        let cfg = makeConfig()
        let app = cfg.profiles[0]
        let c = ctx(cfg, "com.vendor.Suite.2026", modes: [app.id: 1])
        XCTAssertEqual(c.appMode?.name, "Zoom")
        XCTAssertEqual(c.binding(.rotateCW, [])?.binding.action.key, KeyCombo(Key.equal, .command))
        XCTAssertTrue(c.modeOwnerIsApp)
    }

    func testInheritanceCanBeTurnedOff() {
        var cfg = makeConfig()
        cfg.profiles[0].inheritsGlobal = false
        let c = ctx(cfg, "com.example.editor")
        XCTAssertNil(c.binding(.rotateCCW, []))
        XCTAssertNil(c.binding(.doublePress, []))
    }

    func testTitleFilterIsMoreSpecific() {
        var cfg = makeConfig()
        var special = Profile("Editor: Color page", bundleIDs: ["com.example.editor"])
        special.titleContains = "Color"
        cfg.profiles.append(special)
        let plain = Resolver.profile(in: cfg, bundleID: "com.example.editor", title: { "Project - Edit" })
        XCTAssertEqual(plain?.name, "Editor")
        let color = Resolver.profile(in: cfg, bundleID: "com.example.editor", title: { "Project - Color" })
        XCTAssertEqual(color?.name, "Editor: Color page")
    }

    func testDisabledProfileIsIgnored() {
        var cfg = makeConfig()
        cfg.profiles[0].enabled = false
        XCTAssertNil(ctx(cfg, "com.example.editor").app)
    }
}

final class ConfigTests: XCTestCase {
    func testDefaultConfigRoundTrips() throws {
        let cfg = Config.makeDefault(profiles: Templates.all.map { $0.build() })
        let data = try cfg.encoded()
        let back = try Config.decode(data)
        XCTAssertEqual(cfg, back)
    }

    func testSparseHandWrittenConfigLoads() throws {
        let json = """
        {"global": {"name": "Global", "modes": [{"name": "Only", "knob": [
            {"gesture": "rotateCW", "modifiers": "cmd+shift", "action": {"kind": "keystroke", "key": {"key": 124, "mods": "opt"}}}
        ]}]}}
        """
        let cfg = try Config.decode(Data(json.utf8))
        let b = cfg.global.modes[0].knob[0]
        XCTAssertEqual(b.modifiers, [.command, .shift])
        XCTAssertEqual(b.action.key, KeyCombo(Key.right, .option))
        XCTAssertEqual(b.everyNTicks, 1)
        XCTAssertTrue(cfg.settings.enabled)
    }

    func testAdoptMonitorVolumeRewritesOnlyVolumeControls() throws {
        var cfg = Config.makeDefault()
        let changed = cfg.adoptMonitorVolume()
        XCTAssertEqual(changed, 5, "turn x2 and press in Volume mode, plus the two fine-volume bindings")
        let volume = cfg.global.modes[0]
        XCTAssertEqual(volume.binding(.rotateCW, [], speed: .any)?.action, .monitor(1))
        XCTAssertEqual(volume.binding(.rotateCCW, [], speed: .any)?.action, .monitor(-1))
        XCTAssertEqual(volume.binding(.press, [], speed: .any)?.action, .monitorToggle(.mute))
        XCTAssertEqual(cfg.global.always.binding(.rotateCCW, .option, speed: .any)?.action, .monitor(-0.5))
        // Unrelated bindings are untouched, and a second pass is a no-op.
        XCTAssertEqual(cfg.global.always.binding(.doublePress, [], speed: .any)?.action.kind, .modeNext)
        XCTAssertEqual(cfg.adoptMonitorVolume(), 0)
        // The new action kinds survive a save and reload.
        XCTAssertEqual(try Config.decode(cfg.encoded()), cfg)
        XCTAssertEqual(cfg.settings.monitorCeiling, -20)
    }

    func testMigrationReplacesOnlyUntouchedOldDefaults() throws {
        func v1(_ settings: String) throws -> Config {
            try Config.decode(Data("""
            {"version": 1, "settings": {\(settings)}, "global": {"name": "Global", "modes": [{"name": "Only"}]}}
            """.utf8))
        }
        var old = try v1(#""fastThreshold": 14, "accelSlowRate": 6, "accelFastRate": 25"#)
        XCTAssertTrue(old.migrate())
        XCTAssertEqual(old.settings.fastThreshold, 28)
        XCTAssertEqual(old.settings.accelSlowRate, 16)
        XCTAssertEqual(old.settings.accelFastRate, 32)
        XCTAssertFalse(old.migrate(), "a second pass does nothing")

        var tuned = try v1(#""fastThreshold": 20, "accelSlowRate": 6, "accelFastRate": 40"#)
        tuned.migrate()
        XCTAssertEqual(tuned.settings.fastThreshold, 20, "hand-tuned values are kept")
        XCTAssertEqual(tuned.settings.accelFastRate, 40)
        XCTAssertEqual(tuned.settings.accelSlowRate, 16)
    }

    /// What the F75 really sends: a ~20 ms tap per press, whatever the hold time.
    func testF75TapPulsesGiveSingleDoubleAndTriplePress() {
        let clock = ManualScheduler()
        let engine = GestureEngine(scheduler: clock)
        var got: [KnobGesture] = []
        engine.needs = { [.press, .doublePress, .triplePress].contains($0) }
        engine.onGesture = { got.append($0.gesture) }
        func tap(_ t: TimeInterval) {
            clock.advance(to: t); engine.pressDown(at: t)
            clock.advance(to: t + 0.017); engine.pressUp(at: t + 0.017)
        }
        tap(0)
        clock.advance(to: 1)
        tap(1); tap(1.25)
        clock.advance(to: 2)
        tap(2); tap(2.22); tap(2.45)
        clock.advance(to: 3)
        XCTAssertEqual(got, [.press, .doublePress, .triplePress])
    }

    func testMigrationMovesStockModeSwitchingOffHoldGestures() throws {
        // A version 2 config as first shipped: long press / hold-and-turn switch modes.
        var cfg = Config.makeDefault()
        cfg.version = 2
        cfg.settings.doublePressInterval = 0.28
        cfg.global.always.knob.removeAll { [.doublePress, .triplePress].contains($0.gesture) || ($0.gesture == .press && $0.modifiers == .option) }
        cfg.global.always.knob.append(contentsOf: [
            KnobBinding(.longPress, [], .modeNext),
            KnobBinding(.pressRotateCW, [], .modeNext, every: 2),
            KnobBinding(.pressRotateCCW, [], .modePrevious, every: 2),
            KnobBinding(.doublePress, [], .media(.playPause)),
        ])
        XCTAssertTrue(cfg.migrate())
        let always = cfg.global.always
        XCTAssertEqual(always.binding(.doublePress, [], speed: .any)?.action.kind, .modeNext)
        XCTAssertEqual(always.binding(.triplePress, [], speed: .any)?.action.kind, .modePrevious)
        XCTAssertEqual(always.binding(.press, .option, speed: .any)?.action, .media(.playPause))
        XCTAssertNil(always.binding(.longPress, [], speed: .any))
        XCTAssertNil(always.binding(.pressRotateCW, [], speed: .any))
        XCTAssertEqual(cfg.settings.doublePressInterval, 0.35)

        // Someone who rebound double press themselves keeps their setup.
        var custom = Config.makeDefault()
        custom.version = 2
        custom.global.always.knob.removeAll { $0.gesture == .doublePress || $0.gesture == .triplePress }
        custom.global.always.knob.append(contentsOf: [
            KnobBinding(.longPress, [], .modeNext),
            KnobBinding(.doublePress, [], .key(Key.space)),
        ])
        custom.migrate()
        XCTAssertEqual(custom.global.always.binding(.doublePress, [], speed: .any)?.action, .key(Key.space))
        XCTAssertNotNil(custom.global.always.binding(.longPress, [], speed: .any))
    }

    func testMonitorLevelNeverPassesTheCeiling() {
        let range = -96.0...0.0
        func next(_ current: Double, _ delta: Double, ceiling: Double = -20) -> Double {
            MonitorLevel.next(current: current, delta: delta, ceiling: ceiling, range: range)
        }
        XCTAssertEqual(next(-60, 1), -59)
        XCTAssertEqual(next(-60, -0.5), -60.5)
        XCTAssertEqual(next(-20.5, 1), -20, "stops at the ceiling")
        XCTAssertEqual(next(-20, 1), -20)
        XCTAssertEqual(next(-60, 40), -20, "a fast accelerated spin still stops at the ceiling")
        XCTAssertEqual(next(-60, 400), -20)
        XCTAssertEqual(next(-10, 1), -10, "already above the ceiling: not raised, and not pulled down")
        XCTAssertEqual(next(-19.7, 1), -19.7)
        XCTAssertEqual(next(-10, -1), -11, "turning down always works")
        XCTAssertEqual(next(-96, -1), -96)
        XCTAssertEqual(next(-1, 4, ceiling: 6), 0, "a ceiling above the device maximum is capped by the device")
        XCTAssertEqual(next(-42, 0), -42)
    }

    func testEveryTemplateHasUniqueBindingsPerSlot() {
        for t in Templates.all {
            let p = t.build()
            for mode in [p.always] + p.modes {
                var seen = Set<String>()
                for b in mode.knob {
                    let key = "\(b.gesture)|\(b.modifiers.rawValue)|\(b.speed)"
                    XCTAssertTrue(seen.insert(key).inserted, "\(t.name)/\(mode.name) binds \(key) twice")
                }
            }
        }
    }

    // MARK: Aula lighting packets

    /// Two packets captured from the vendor's app, byte for byte.
    func testAulaPacketsMatchVendorCaptures() {
        let cyan = AulaLighting.packet(command: 0x88, sub: 1, payload: [0x00, 0xff, 0xff, 0x01, 0x37])
        XCTAssertEqual(cyan, [0x13, 0x88, 0x01, 0x00, 0x15, 0x00, 0xff, 0xff, 0x01, 0x37,
                              0, 0, 0, 0, 0, 0, 0, 0, 0, 0xe7])
        let blue = AulaLighting.packet(command: 0x88, sub: 1, payload: [0x00, 0x00, 0xff, 0x02, 0x24, 0x2a])
        XCTAssertEqual(blue, [0x13, 0x88, 0x01, 0x00, 0x16, 0x00, 0x00, 0xff, 0x02, 0x24, 0x2a,
                              0, 0, 0, 0, 0, 0, 0, 0, 0x01])
    }

    func testAulaWholeBoardFrame() {
        // The vendor app's own "whole board dark" frame is 13 88 01 00 23 00…
        let dark = AulaLighting.wholeBoard(red: 0, green: 0, blue: 0)
        XCTAssertEqual(Array(dark[0..<8]), [0x13, 0x88, 0x01, 0x00, 0x23, 0x00, 0x00, 0x00])
        XCTAssertEqual(dark.count, 20)
        XCTAssertEqual(dark[19], 0xbf)
        let white = AulaLighting.wholeBoard(red: 255, green: 255, blue: 255)
        XCTAssertEqual(Array(white[4..<8]), [0x23, 0xff, 0xff, 0xff])
        XCTAssertEqual(white[19], 0xbc)
        XCTAssertNil(AulaLighting.packet(command: 0x88, sub: 1, payload: [UInt8](repeating: 0, count: 15)))
    }
}
