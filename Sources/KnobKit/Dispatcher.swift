import AppKit
import KnobCore

private final class MainScheduler: KnobScheduler {
    private final class Item: KnobTimer {
        var work: DispatchWorkItem?
        func cancel() { work?.cancel(); work = nil }
    }

    func schedule(after delay: TimeInterval, _ block: @escaping () -> Void) -> KnobTimer {
        let item = Item()
        let work = DispatchWorkItem(block: block)
        item.work = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        return item
    }
}

/// Decides, synchronously inside the event tap, what each knob or key event means in
/// the current app and mode, runs the bound action, and says whether to swallow it.
final class Dispatcher {
    private let state: AppState
    private let hid: HIDWatcher
    private let runner: ActionRunner
    private let hud: HUDController
    private let engine: GestureEngine

    /// Per media key: did we swallow its key-down (so the key-up must go too)?
    private var swallowedDown: [Int: Bool] = [:]
    /// Per media key: did the current press come from a knob device?
    private var fromKnob: [Int: Bool] = [:]
    private var lastSource = ""
    private var pressMods: ModifierSet = []
    private var divider: (id: UUID, count: Int, at: TimeInterval)?
    private var swallowedKeys = Set<Int>()

    init(state: AppState, hid: HIDWatcher, runner: ActionRunner, hud: HUDController) {
        self.state = state
        self.hid = hid
        self.runner = runner
        self.hud = hud
        engine = GestureEngine(scheduler: MainScheduler(), tuning: .init(state.config.settings))
        engine.needs = { [unowned self] gesture in
            let ctx = self.state.context
            if gesture.isPressRotate { return ctx.hasGesture(gesture) }
            return ctx.binding(gesture, self.pressMods) != nil
        }
        engine.onGesture = { [unowned self] event in self.handlePressGesture(event) }
    }

    func settingsChanged() {
        engine.tuning = .init(state.config.settings)
    }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    // MARK: Entry point from the event tap

    func handle(_ event: TapEvent) -> Bool {
        guard state.config.settings.enabled else { return false }
        switch event {
        case .aux(let code, let down, let isRepeat, let flags):
            return handleAux(code: code, down: down, isRepeat: isRepeat, mods: ModifierSet(cgFlags: flags), simulated: false)
        case .key(let code, let down, let isRepeat, let flags):
            return handleKey(code: code, down: down, isRepeat: isRepeat, mods: ModifierSet(cgFlags: flags))
        }
    }

    // MARK: Knob (volume up / down / mute)

    /// Is this press from the knob? In "selected devices" mode the HID layer tells us
    /// which device sent it; anything it cannot identify is left alone.
    private func identify(usage: Int, simulated: Bool) -> Bool {
        if simulated { lastSource = "simulated"; return true }
        let settings = state.config.settings
        switch settings.deviceMode {
        case .any:
            lastSource = hid.attribute(usage: usage, waitMs: 0)?.name ?? "any keyboard"
            return true
        case .selected:
            guard let device = hid.attribute(usage: usage, waitMs: 12) else {
                lastSource = hid.isListening ? "unidentified" : "unidentified (no Input Monitoring)"
                return false
            }
            lastSource = device.name
            return settings.devices.contains { $0.vendorID == device.vendorID && $0.productID == device.productID }
        }
    }

    private func handleAux(code: Int, down: Bool, isRepeat: Bool, mods: ModifierSet, simulated: Bool) -> Bool {
        switch code {
        case SystemKeys.auxVolumeUp, SystemKeys.auxVolumeDown:
            guard down else { return swallowedDown.removeValue(forKey: code) ?? false }
            if !isRepeat || fromKnob[code] == nil {
                let usage = code == SystemKeys.auxVolumeUp ? HIDWatcher.usageVolumeUp : HIDWatcher.usageVolumeDown
                fromKnob[code] = identify(usage: usage, simulated: simulated)
            }
            guard fromKnob[code] == true else {
                swallowedDown[code] = false
                state.record(source: lastSource, event: code == 0 ? "volume up" : "volume down", result: "not the knob", swallowed: false)
                return false
            }
            var clockwise = code == SystemKeys.auxVolumeUp
            if state.config.settings.invertRotation { clockwise.toggle() }
            let handled = processTick(clockwise: clockwise, mods: mods, systemAux: code)
            swallowedDown[code] = handled
            return handled

        case SystemKeys.auxMute:
            guard down else {
                guard swallowedDown.removeValue(forKey: code) == true else { return false }
                engine.pressUp(at: now)
                return true
            }
            if isRepeat { return swallowedDown[code] ?? false }
            guard identify(usage: HIDWatcher.usageMute, simulated: simulated) else {
                swallowedDown[code] = false
                state.record(source: lastSource, event: "mute", result: "not the knob", swallowed: false)
                return false
            }
            state.refreshContextIfStale()
            guard state.context.tracksPress else {
                swallowedDown[code] = false
                state.record(source: lastSource, event: "press", result: "System default", swallowed: false)
                return false
            }
            pressMods = mods
            engine.pressDown(at: now)
            swallowedDown[code] = true
            return true

        default:
            return false
        }
    }

    private func processTick(clockwise: Bool, mods: ModifierSet, systemAux: Int) -> Bool {
        let t = now
        let event = engine.tick(clockwise: clockwise, at: t)
        state.refreshContextIfStale()
        let ctx = state.context

        var resolved = ctx.binding(event.gesture, mods, speed: event.speed)
        if resolved == nil, let plain = event.gesture.plainRotation {
            resolved = ctx.binding(plain, mods, speed: event.speed)
        }
        let what = "\(mods.symbols)\(event.gesture.title) (\(Int(event.rate.rounded()))/s)"
        guard let resolved else {
            state.record(source: lastSource, event: what, result: "unbound", swallowed: false)
            return false
        }
        let binding = resolved.binding
        if binding.action.kind == .passthrough {
            state.record(source: lastSource, event: what, result: "System default", swallowed: false)
            return false
        }

        // "Every N detents": count ticks for this binding, restart after a pause or a change.
        if binding.everyNTicks > 1 {
            var count = 1
            if let d = divider, d.id == binding.id, t - d.at < 0.6 { count = d.count + 1 }
            divider = (binding.id, count, t)
            if count % binding.everyNTicks != 0 {
                state.record(source: lastSource, event: what, result: "\(binding.displayName) (\(count % binding.everyNTicks)/\(binding.everyNTicks))", swallowed: true)
                return true
            }
        } else {
            divider = nil
        }

        let info = RunInfo(direction: event.gesture.direction,
                           multiplier: binding.accelerate ? event.multiplier : 1,
                           systemAux: systemAux, gesture: event.gesture)
        runner.run(binding.action, info: info)
        announce(binding, gesture: event.gesture)
        state.record(source: lastSource, event: what,
                     result: binding.displayName + (info.multiplier > 1.05 ? String(format: " ×%.1f", info.multiplier) : ""),
                     swallowed: true)
        return true
    }

    private func handlePressGesture(_ event: GestureEvent) {
        let ctx = state.context
        let what = "\(pressMods.symbols)\(event.gesture.title)"
        let info = RunInfo(systemAux: SystemKeys.auxMute, gesture: event.gesture)

        if let resolved = ctx.binding(event.gesture, pressMods) {
            runner.run(resolved.binding.action, info: info)
            announce(resolved.binding, gesture: event.gesture)
            state.record(source: lastSource, event: what, result: resolved.binding.displayName, swallowed: true)
            return
        }
        // No binding for this exact gesture: behave like that many plain presses.
        let repeats: Int
        switch event.gesture {
        case .press: repeats = 1
        case .doublePress: repeats = 2
        case .triplePress: repeats = 3
        default: return
        }
        let single = event.gesture == .press ? nil : ctx.binding(.press, pressMods)
        for _ in 0..<repeats {
            if let single { runner.run(single.binding.action, info: info) } else { SystemKeys.postAux(SystemKeys.auxMute) }
        }
        state.record(source: lastSource, event: what, result: single?.binding.displayName ?? "System default (mute)", swallowed: true)
    }

    /// Optional HUD for actions that do not show one themselves.
    private func announce(_ binding: KnobBinding, gesture: KnobGesture) {
        guard state.config.settings.hudOnEveryAction else { return }
        switch binding.action.kind {
        case .volume, .muteToggle, .monitorLevel, .monitorToggle, .modeNext, .modePrevious, .modeSet: return
        default: break
        }
        hud.show(symbol: state.context.displayMode?.symbol ?? "dial.medium", title: binding.displayName,
                 subtitle: state.context.displayMode?.name)
    }

    // MARK: Key remaps

    private func handleKey(code: Int, down: Bool, isRepeat: Bool, mods: ModifierSet) -> Bool {
        if state.isRecordingKey { return false }
        guard down else { return swallowedKeys.remove(code) != nil }
        let ctx = state.context
        guard ctx.hasKeyBindings, let binding = ctx.keyBinding(KeyCombo(code, mods)),
              binding.action.kind != .passthrough
        else { return false }
        swallowedKeys.insert(code)
        if isRepeat && !binding.repeats { return true }
        runner.run(binding.action, info: RunInfo())
        return true
    }

    // MARK: Simulation

    /// Feeds synthetic knob input through the same path as real events. Tokens:
    /// `cw`, `ccw`, `down`, `up`, `press`, `wait:<ms>`, each optionally prefixed with
    /// modifiers, e.g. `opt+cw` or `cmd+shift+press`.
    func simulate(_ tokens: [String]) {
        var delay = 0.0
        for token in tokens {
            let parts = token.lowercased().split(separator: "+").map(String.init)
            guard let verb = parts.last else { continue }
            let mods = ModifierSet(text: parts.dropLast().joined(separator: "+"))
            if verb.hasPrefix("wait:") {
                delay += (Double(verb.dropFirst(5)) ?? 0) / 1000
                continue
            }
            let run: () -> Void
            switch verb {
            case "cw", "ccw":
                let code = verb == "cw" ? SystemKeys.auxVolumeUp : SystemKeys.auxVolumeDown
                run = { [weak self] in
                    guard let self else { return }
                    let swallowed = self.handleAux(code: code, down: true, isRepeat: false, mods: mods, simulated: true)
                    _ = self.handleAux(code: code, down: false, isRepeat: false, mods: mods, simulated: true)
                    // A real unswallowed event would reach the system; mirror that.
                    if !swallowed { SystemKeys.postAux(code) }
                }
            case "down":
                run = { [weak self] in
                    _ = self?.handleAux(code: SystemKeys.auxMute, down: true, isRepeat: false, mods: mods, simulated: true)
                }
            case "up":
                run = { [weak self] in
                    _ = self?.handleAux(code: SystemKeys.auxMute, down: false, isRepeat: false, mods: mods, simulated: true)
                }
            case "press":
                run = { [weak self] in
                    guard let self else { return }
                    let swallowed = self.handleAux(code: SystemKeys.auxMute, down: true, isRepeat: false, mods: mods, simulated: true)
                    if !swallowed { SystemKeys.postAux(SystemKeys.auxMute); return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        _ = self.handleAux(code: SystemKeys.auxMute, down: false, isRepeat: false, mods: mods, simulated: true)
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: run)
                delay += 0.06
                continue
            default:
                Log.write("simulate: unknown token \(token)")
                continue
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: run)
            delay += 0.03
        }
    }
}
