import Foundation

public protocol KnobTimer: AnyObject {
    func cancel()
}

public protocol KnobScheduler: AnyObject {
    func schedule(after delay: TimeInterval, _ block: @escaping () -> Void) -> KnobTimer
}

public struct GestureEvent: Sendable {
    public var gesture: KnobGesture
    /// Detents per second (rotation only).
    public var rate: Double
    /// `.slow` or `.fast` for rotation, `.any` for presses.
    public var speed: SpeedClass
    /// Acceleration multiplier, 1 when turning slowly.
    public var multiplier: Double

    public init(gesture: KnobGesture, rate: Double = 0, speed: SpeedClass = .any, multiplier: Double = 1) {
        self.gesture = gesture
        self.rate = rate
        self.speed = speed
        self.multiplier = multiplier
    }
}

/// Turns the raw knob signals (detent ticks, press down, press up) into gestures.
///
/// The F75 reports the knob through a single consumer-control slot, so pressing and
/// turning at once can show up as "mute released" and "volume tick" in the same report.
/// `chordGrace` and the virtual hold cover that: a release that lands within the grace
/// window of a tick is treated as the knob still being held.
public final class GestureEngine {
    public struct Tuning: Sendable {
        public var doublePressInterval = 0.35
        public var longPressDuration = 0.5
        public var chordGrace = 0.03
        public var virtualHoldTimeout = 0.7
        public var accelSlowRate = 16.0
        public var accelFastRate = 32.0
        public var accelMaxMultiplier = 4.0
        public var fastThreshold = 28.0

        public init() {}

        public init(_ s: Settings) {
            doublePressInterval = s.doublePressInterval
            longPressDuration = s.longPressDuration
            chordGrace = s.chordGrace
            virtualHoldTimeout = s.virtualHoldTimeout
            accelSlowRate = s.accelSlowRate
            accelFastRate = s.accelFastRate
            accelMaxMultiplier = s.accelMaxMultiplier
            fastThreshold = s.fastThreshold
        }
    }

    private enum Phase {
        case idle
        case pressed(rotated: Bool, longFired: Bool)
        /// Released, waiting one grace window to see whether a tick turns it into a hold.
        case chordPending
        /// Press was released by the firmware's slot swap but the knob is treated as held.
        case virtualHold
    }

    public var tuning: Tuning
    /// Asked before waiting on a slower gesture, so unbound gestures add no latency.
    public var needs: (KnobGesture) -> Bool = { _ in true }
    /// Press-type gestures (press, double, triple, long) are delivered here.
    public var onGesture: (GestureEvent) -> Void = { _ in }

    private let scheduler: KnobScheduler
    private var phase: Phase = .idle
    private var pendingClicks = 0
    private var lastTickAt: TimeInterval?
    private var tickTimes: [TimeInterval] = []
    private var lastClockwise: Bool?

    private var longTimer: KnobTimer?
    private var multiTimer: KnobTimer?
    private var chordTimer: KnobTimer?
    private var holdTimer: KnobTimer?

    public init(scheduler: KnobScheduler, tuning: Tuning = Tuning()) {
        self.scheduler = scheduler
        self.tuning = tuning
    }

    /// True while the knob is physically or virtually held down.
    public var isHeld: Bool {
        switch phase {
        case .pressed, .virtualHold: return true
        default: return false
        }
    }

    public func reset() {
        [longTimer, multiTimer, chordTimer, holdTimer].forEach { $0?.cancel() }
        longTimer = nil; multiTimer = nil; chordTimer = nil; holdTimer = nil
        phase = .idle
        pendingClicks = 0
        tickTimes.removeAll()
        lastTickAt = nil
        lastClockwise = nil
    }

    // MARK: Rotation

    /// One detent. Returns the gesture immediately so the caller can decide whether to
    /// swallow the underlying event.
    public func tick(clockwise: Bool, at t: TimeInterval) -> GestureEvent {
        let (rate, multiplier) = measure(clockwise: clockwise, at: t)
        lastTickAt = t

        var held = false
        switch phase {
        case .pressed(_, let longFired):
            phase = .pressed(rotated: true, longFired: longFired)
            longTimer?.cancel(); longTimer = nil
            multiTimer?.cancel(); multiTimer = nil
            pendingClicks = 0
            held = true
        case .chordPending:
            chordTimer?.cancel(); chordTimer = nil
            phase = .virtualHold
            armVirtualHold()
            held = true
        case .virtualHold:
            armVirtualHold()
            held = true
        case .idle:
            break
        }

        let gesture: KnobGesture = held
            ? (clockwise ? .pressRotateCW : .pressRotateCCW)
            : (clockwise ? .rotateCW : .rotateCCW)
        return GestureEvent(gesture: gesture, rate: rate,
                            speed: rate >= tuning.fastThreshold ? .fast : .slow,
                            multiplier: multiplier)
    }

    private func measure(clockwise: Bool, at t: TimeInterval) -> (rate: Double, multiplier: Double) {
        // Speed is measured over the last few detents of the current burst. A reversal
        // or a pause starts a new burst, so the reading follows the hand without lag
        // (measured on the F75: detents arrive 30 to 75 ms apart while turning).
        if lastClockwise != clockwise { tickTimes.removeAll() }
        if let last = tickTimes.last, t - last > 0.15 { tickTimes.removeAll() }
        lastClockwise = clockwise
        tickTimes.append(t)
        if tickTimes.count > 5 { tickTimes.removeFirst(tickTimes.count - 5) }

        var rate = 0.0
        if tickTimes.count >= 2, let first = tickTimes.first, t > first {
            rate = Double(tickTimes.count - 1) / (t - first)
        }
        let span = max(tuning.accelFastRate - tuning.accelSlowRate, 0.001)
        let f = min(max((rate - tuning.accelSlowRate) / span, 0), 1)
        return (rate, 1 + f * (max(tuning.accelMaxMultiplier, 1) - 1))
    }

    private func armVirtualHold() {
        holdTimer?.cancel()
        holdTimer = scheduler.schedule(after: tuning.virtualHoldTimeout) { [weak self] in
            guard let self, case .virtualHold = self.phase else { return }
            self.phase = .idle
        }
    }

    // MARK: Press

    public func pressDown(at t: TimeInterval) {
        switch phase {
        case .virtualHold:
            // The firmware re-asserted the press after a tick: the real hold continues.
            holdTimer?.cancel(); holdTimer = nil
            phase = .pressed(rotated: true, longFired: false)
            return
        case .chordPending:
            chordTimer?.cancel(); chordTimer = nil
            phase = .idle
            registerClick()
        case .pressed:
            return
        case .idle:
            break
        }

        multiTimer?.cancel(); multiTimer = nil
        phase = .pressed(rotated: false, longFired: false)
        if needs(.longPress) {
            longTimer = scheduler.schedule(after: tuning.longPressDuration) { [weak self] in
                self?.longPressFired()
            }
        }
    }

    private func longPressFired() {
        longTimer = nil
        guard case .pressed(false, false) = phase else { return }
        phase = .pressed(rotated: false, longFired: true)
        pendingClicks = 0
        onGesture(GestureEvent(gesture: .longPress))
    }

    public func pressUp(at t: TimeInterval) {
        longTimer?.cancel(); longTimer = nil
        guard case .pressed(let rotated, let longFired) = phase else { return }

        if rotated {
            if let last = lastTickAt, t - last <= tuning.chordGrace {
                phase = .virtualHold
                armVirtualHold()
            } else {
                phase = .idle
            }
            return
        }
        if longFired {
            phase = .idle
            return
        }
        if needs(.pressRotateCW) || needs(.pressRotateCCW) {
            phase = .chordPending
            chordTimer = scheduler.schedule(after: tuning.chordGrace) { [weak self] in
                guard let self, case .chordPending = self.phase else { return }
                self.chordTimer = nil
                self.phase = .idle
                self.registerClick()
            }
        } else {
            phase = .idle
            registerClick()
        }
    }

    private func registerClick() {
        pendingClicks += 1
        let maxClicks = needs(.triplePress) ? 3 : (needs(.doublePress) ? 2 : 1)
        multiTimer?.cancel(); multiTimer = nil
        if pendingClicks >= maxClicks {
            flushClicks()
        } else {
            multiTimer = scheduler.schedule(after: tuning.doublePressInterval) { [weak self] in
                self?.flushClicks()
            }
        }
    }

    private func flushClicks() {
        multiTimer?.cancel(); multiTimer = nil
        let n = pendingClicks
        pendingClicks = 0
        guard n > 0 else { return }
        let gesture: KnobGesture = n == 1 ? .press : (n == 2 ? .doublePress : .triplePress)
        onGesture(GestureEvent(gesture: gesture))
    }
}
