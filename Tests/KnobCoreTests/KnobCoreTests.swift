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

    func testAulaPerKeyFrames() {
        // Captured from the vendor app: two groups in one packet.
        let frame = AulaLighting.perKey([
            .init(red: 0x00, green: 0xff, blue: 0xff, lights: [0x43]),
            .init(red: 0xff, green: 0xff, blue: 0x00, lights: [0x27]),
        ])
        XCTAssertEqual(frame, [[0x13, 0x88, 0x01, 0x00, 0x1a, 0x00, 0xff, 0xff, 0x01, 0x43, 0xff, 0xff, 0x00, 0x01, 0x27,
                                0, 0, 0, 0, 0x1e]])

        // A whole board is one group of 80: 84 bytes in six packets, the first five full.
        let all = AulaLighting.perKey([.init(red: 255, green: 255, blue: 255, lights: F75Board.keys.map(\.light))])
        XCTAssertEqual(all.count, 6)
        XCTAssertEqual(all.map { $0[2] }, [6, 6, 6, 6, 6, 6])
        XCTAssertEqual(all.map { $0[3] }, [0, 1, 2, 3, 4, 5])
        XCTAssertEqual(all.map { $0[4] }, [0x1e, 0x1e, 0x1e, 0x1e, 0x1e, 0x1e])
        for packet in all {
            XCTAssertEqual(packet.count, 20)
            XCTAssertEqual(packet[19], UInt8(truncatingIfNeeded: packet[0..<19].reduce(0) { $0 + Int($1) }))
        }

        // Black groups are dropped; an all-dark frame is a single dark key.
        XCTAssertEqual(AulaLighting.perKeyPayload([.init(red: 0, green: 0, blue: 0, lights: [1, 2])]), [0, 0, 0, 1, 0])
    }

    func testF75BoardIsComplete() {
        XCTAssertEqual(F75Board.keys.count, 80)
        XCTAssertEqual(Set(F75Board.keys.map(\.light)).count, 80, "every key has its own light")
        // Column-major, six to a column: the left edge is lights 0 to 5, top to bottom.
        let leftEdge = F75Board.keys.filter { $0.x == 0 }.sorted { $0.row < $1.row }.map(\.light)
        XCTAssertEqual(leftEdge, [0, 1, 2, 3, 4, 5])
        for key in F75Board.keys { XCTAssertEqual(key.light % 6, key.row, "light \(key.light) is in row \(key.row)") }
        // Every row spans the full sixteen units.
        for row in 1...4 {
            let width = F75Board.keys.filter { $0.row == row }.reduce(0) { $0 + $1.width }
            XCTAssertEqual(width, 16, accuracy: 0.001)
        }
    }

    // MARK: Light show

    func testBitmapAverage() {
        var bitmap = Bitmap(width: 4, height: 2)
        bitmap.set(0, 0, 255, 255, 255)
        bitmap.set(1, 0, 255, 0, 0)
        XCTAssertEqual(bitmap.average(x0: 0, y0: 0, x1: 1, y1: 1).g, 1, accuracy: 0.001)
        // Half white, half red.
        let mixed = bitmap.average(x0: 0.5, y0: 0, x1: 1.5, y1: 1)
        XCTAssertEqual(mixed.r, 1, accuracy: 0.001)
        XCTAssertEqual(mixed.g, 0.5, accuracy: 0.001)
        // Outside the image is black, and counts toward the average.
        XCTAssertEqual(bitmap.average(x0: -1, y0: 0, x1: 1, y1: 1).r, 0.5, accuracy: 0.001)
        XCTAssertEqual(bitmap.average(x0: 10, y0: 10, x1: 11, y1: 11).r, 0)
    }

    func testPixelFontRendersFiveRows() {
        let bitmap = PixelFont.render("HI")
        // H is 4 wide, a gap, I is 3 wide.
        XCTAssertEqual(bitmap.width, 8)
        XCTAssertEqual(bitmap.height, 6)
        func lit(_ x: Int, _ y: Int) -> Bool { bitmap.pixels[(y * bitmap.width + x) * 3] > 0 }
        XCTAssertTrue(lit(0, 0) && lit(3, 0) && !lit(1, 0), "top of the H")
        XCTAssertTrue(lit(0, 2) && lit(1, 2) && lit(2, 2) && lit(3, 2), "bar of the H")
        XCTAssertFalse((0..<8).contains { lit($0, 5) }, "the bottom row stays dark")
        // Lower case falls back to capitals, unknown characters to a question mark.
        XCTAssertEqual(PixelFont.render("hi"), bitmap)
        XCTAssertEqual(PixelFont.render("\u{1F600}"), PixelFont.render("?"))
    }

    func testLightShowScrollsRightToLeft() {
        // A banner that is one white column, six rows tall.
        var bitmap = Bitmap(width: 1, height: 6)
        for y in 0..<6 { bitmap.set(0, y, 255, 255, 255) }
        var show = LightShow(bitmap: bitmap)
        show.speed = 1
        show.upright = false
        XCTAssertEqual(show.pixelsPerKey, 1, accuracy: 0.0001)
        XCTAssertEqual(show.lineDuration, 17, accuracy: 0.0001)

        func litKeys(_ time: Double) -> [F75Board.Key] {
            let lights = Set(show.frame(at: time).flatMap(\.lights))
            return F75Board.keys.filter { lights.contains($0.light) }
        }
        // At the start the column is still off the right edge.
        XCTAssertTrue(litKeys(0).isEmpty)
        // One second in it covers x 15…16: the rightmost keys.
        let entering = litKeys(1)
        XCTAssertFalse(entering.isEmpty)
        XCTAssertTrue(entering.allSatisfy { $0.centerX > 14.5 }, "enters at the right edge")
        // Later it has moved left.
        let later = litKeys(9)
        // Key under key: 7, U, J, M and the function key above them.
        XCTAssertEqual(Set(later.compactMap(\.keyCode)), [26, 32, 38, 46, 97])
        XCTAssertEqual(Set(later.map(\.row)).count, 5, "one key in each row that has a key there")
        // After a full pass it is gone, then the loop brings it back.
        XCTAssertTrue(litKeys(16.99).allSatisfy { F75Board.column(of: $0) == 0 }, "leaves by the left edge")
        XCTAssertEqual(litKeys(17 + 9).map(\.light), later.map(\.light))
        show.loop = false
        XCTAssertTrue(litKeys(40).isEmpty, "without looping it ends dark")
    }

    func testLightShowFramesFitTheirBudget() {
        // A busy picture: every pixel a different colour.
        var bitmap = Bitmap(width: 64, height: 6)
        for y in 0..<6 { for x in 0..<64 { bitmap.set(x, y, UInt8(x * 4), UInt8(y * 40), UInt8(255 - x * 3)) } }
        var show = LightShow(bitmap: bitmap)
        show.colorSteps = 6
        for time in stride(from: 3.0, to: 9.0, by: 0.7) {
            let frame = show.frame(at: time, budget: 56)
            let lights = frame.flatMap(\.lights)
            XCTAssertEqual(Set(lights).count, lights.count, "no key is listed twice")
            // Either it fits, or it is down to a single colour.
            XCTAssertTrue(LightShow.size(frame) <= 56 || frame.count == 1)
        }
        // Reading an image in two lines halves its scale.
        var tall = LightShow(bitmap: Bitmap(width: 24, height: 12))
        tall.lines = 2
        XCTAssertEqual(tall.pixelsPerKey, 1, accuracy: 0.0001)
        XCTAssertEqual(tall.duration, tall.lineDuration * 2, accuracy: 0.0001)
    }

    func testGridColumnsIgnoreTheStagger() {
        func column(_ code: Int) -> Int { F75Board.column(of: F75Board.keys.first { $0.keyCode == code }!) }
        // 1 over Q over A over Z.
        XCTAssertEqual([18, 12, 0, 6].map(column), [1, 1, 1, 1])
        // 0 over P over ; over /.
        XCTAssertEqual([29, 35, 41, 44].map(column), [10, 10, 10, 10])
        XCTAssertEqual(column(53), 0)   // Esc
        XCTAssertEqual(column(117), 15) // Delete, the last column

        // Upright mode puts a column where it truly is: over 7, between Y and U.
        var bitmap = Bitmap(width: 1, height: 6)
        for y in 0..<6 { bitmap.set(0, y, 255, 255, 255) }
        var show = LightShow(bitmap: bitmap)
        show.speed = 1
        XCTAssertTrue(show.upright, "true key positions are the default")
        // At 9 s the column covers x 7…8: exactly the 7 key; half of Y and half of U.
        show.softEdges = true
        show.colorSteps = 3
        let soft = Set(show.frame(at: 9).flatMap(\.lights))
        let codes = Set(F75Board.keys.filter { soft.contains($0.light) }.compactMap(\.keyCode))
        XCTAssertTrue(codes.isSuperset(of: [26, 16, 32]), "7 fully, Y and U half each")
        // With hard edges a stroke lights the nearest key in each row. A little later it
        // has moved left to x 6.8…7.8: over 7 (7…8), Y (6.5…7.5), H (6.75…7.75) and
        // N (7.25…8.25), which is one key per row in an upright line.
        show.softEdges = false
        let hard = Set(show.frame(at: 9.2).flatMap(\.lights))
        let nearest = Set(F75Board.keys.filter { hard.contains($0.light) && (1...4).contains($0.row) }.compactMap(\.keyCode))
        XCTAssertEqual(nearest, [26, 16, 4, 45])
    }

    /// A key on the edge of a letter must be the letter's colour or dark, never a
    /// colour of its own. (Rounding red, green and blue separately once turned the
    /// edges of purple text blue for an instant.)
    func testHardEdgesNeverInventAColour() {
        var show = LightShow(bitmap: PixelFont.render("KNOW DRIVE", red: 0xBF, green: 0x5A, blue: 0xF2))
        show.speed = 11
        show.colorSteps = 16
        var seen = Set<[UInt8]>()
        var time = 0.0
        while time < show.duration {
            for group in show.frame(at: time) { seen.insert([group.red, group.green, group.blue]) }
            time += 0.0007
        }
        XCTAssertEqual(seen.count, 1, "one colour only: \(seen)")
        // And it is close to the purple that was asked for.
        let colour = seen.first ?? [0, 0, 0]
        XCTAssertEqual(Double(colour[0]), 0xBF, accuracy: 10)
        XCTAssertEqual(Double(colour[1]), 0x5A, accuracy: 10)
        XCTAssertEqual(Double(colour[2]), 0xF2, accuracy: 10)
    }
}
