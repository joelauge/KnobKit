import AppKit
import KnobCore

/// What triggered an action, for actions that scale or need to know the direction.
struct RunInfo {
    /// +1 clockwise, -1 counter-clockwise, 0 for presses and key remaps.
    var direction = 0
    /// Acceleration multiplier (1 unless the binding opted in and the knob is spinning).
    var multiplier = 1.0
    /// The media key the system would have received, used by "System default".
    var systemAux: Int?
    var gesture: KnobGesture?
}

/// Executes actions. Runs on the main thread; slow work (shell, AppleScript, menu
/// lookups) is pushed to a background queue so the event tap never stalls.
final class ActionRunner {
    private unowned let state: AppState
    private let hud: HUDController
    private let scroller = Scroller()
    private let sticky = StickyKeys()
    private let background = DispatchQueue(label: "knobkit.actions", qos: .userInitiated)

    init(state: AppState, hud: HUDController) {
        self.state = state
        self.hud = hud
    }

    func releaseHeldModifiers() { sticky.releaseNow() }

    func run(_ action: Action, info: RunInfo) {
        switch action.kind {
        case .passthrough:
            if let aux = info.systemAux { SystemKeys.postAux(aux) }
        case .none:
            break
        case .volume:
            changeVolume(byPercent: action.amount * info.multiplier, fineFallback: action.amount.magnitude < 3)
        case .muteToggle:
            toggleMute()
        case .monitorLevel:
            changeMonitorLevel(action, multiplier: info.multiplier)
        case .monitorToggle:
            toggleMonitor(action)
        case .mediaKey:
            for _ in 0..<max(1, action.count) {
                SystemKeys.postAux(action.mediaKey.auxCode, flags: action.fine ? [.option, .shift] : [])
            }
        case .keystroke:
            let times = max(1, action.count) * max(1, Int(info.multiplier.rounded()))
            SystemKeys.postKey(action.key.keyCode, action.key.modifiers, count: times)
        case .stickyKeystroke:
            sticky.fire(hold: action.hold, key: action.key, releaseAfter: action.releaseAfter)
        case .typeText:
            SystemKeys.typeText(action.text)
        case .scroll:
            scroller.scroll(dx: action.dx * info.multiplier, dy: action.dy * info.multiplier,
                            unit: action.unit, smooth: action.smooth, modifiers: action.hold)
        case .menuItem:
            pressMenuItem(action.text)
        case .shell:
            launch("/bin/zsh", ["-c", action.text], info: info, what: "shell command")
        case .appleScript:
            launch("/usr/bin/osascript", ["-e", action.text], info: info, what: "AppleScript")
        case .shortcut:
            launch("/usr/bin/shortcuts", ["run", action.text], info: info, what: "shortcut \(action.text)")
        case .open:
            open(action.text)
        case .modeNext:
            if let mode = state.cycleMode(1) { showMode(mode) }
        case .modePrevious:
            if let mode = state.cycleMode(-1) { showMode(mode) }
        case .modeSet:
            if let mode = state.setMode(named: action.text) { showMode(mode) }
            else { Log.write("mode not found: \(action.text)") }
        case .macro:
            runSteps(ArraySlice(action.steps), info: info)
        }
    }

    // MARK: Modes

    func showMode(_ mode: Mode) {
        let ctx = state.context
        hud.show(symbol: mode.symbol, title: mode.name, subtitle: ctx.modeOwner.name,
                 dotIndex: ctx.modeOwnerIndex, dotCount: ctx.modeOwner.modes.count)
    }

    // MARK: Volume

    private func changeVolume(byPercent percent: Double, fineFallback: Bool) {
        if let current = SystemVolume.get() {
            let next = min(max(current + percent / 100, 0), 1)
            if SystemVolume.set(next) {
                if percent > 0, SystemVolume.isMuted() == true { _ = SystemVolume.setMuted(false) }
                hud.show(symbol: next <= 0.001 ? "speaker.slash.fill" : "speaker.wave.2.fill",
                         title: "Volume  \(Int((next * 100).rounded()))%", level: next)
                return
            }
        }
        // Output has no software volume: let the system handle it with its own keys.
        SystemKeys.postAux(percent >= 0 ? SystemKeys.auxVolumeUp : SystemKeys.auxVolumeDown,
                           flags: fineFallback ? [.option, .shift] : [])
    }

    private func toggleMute() {
        if let muted = SystemVolume.isMuted(), SystemVolume.setMuted(!muted) {
            hud.show(symbol: muted ? "speaker.wave.2.fill" : "speaker.slash.fill",
                     title: muted ? "Unmuted" : "Muted", level: muted ? SystemVolume.get() : 0)
        } else {
            SystemKeys.postAux(SystemKeys.auxMute)
        }
    }

    // MARK: Universal Audio monitor

    private func changeMonitorLevel(_ action: Action, multiplier: Double) {
        // On an output macOS can control (headphones, built-in speakers) act like the volume keys.
        if action.auto, SystemVolume.get() != nil {
            SystemKeys.postAux(action.amount >= 0 ? SystemKeys.auxVolumeUp : SystemKeys.auxVolumeDown,
                               flags: action.amount.magnitude < 1 ? [.option, .shift] : [])
            return
        }
        let ceiling = state.config.settings.monitorCeiling
        let raising = action.amount > 0
        UAMixer.shared.adjust(byDB: action.amount * multiplier, ceiling: ceiling) { [weak self] level, range in
            guard let self else { return }
            guard let level else {
                self.hud.show(symbol: "exclamationmark.triangle.fill", title: "UA mixer not reachable",
                              subtitle: "Is the UAD software running?")
                return
            }
            let span = max(range.upperBound - range.lowerBound, 1)
            self.hud.show(symbol: level <= range.lowerBound ? "speaker.slash.fill" : "hifispeaker.fill",
                          title: String(format: "Monitor  %.1f dB", level),
                          subtitle: raising && level >= ceiling ? "At the ceiling set in General" : nil,
                          level: (level - range.lowerBound) / span)
        }
    }

    private func toggleMonitor(_ action: Action) {
        if action.auto, action.monitorSwitch == .mute, SystemVolume.isMuted() != nil {
            SystemKeys.postAux(SystemKeys.auxMute)
            return
        }
        let which = action.monitorSwitch
        UAMixer.shared.toggle(which.property) { [weak self] on in
            guard let self else { return }
            guard let on else {
                self.hud.show(symbol: "exclamationmark.triangle.fill", title: "UA mixer not reachable",
                              subtitle: "Is the UAD software running?")
                return
            }
            switch which {
            case .mute:
                self.hud.show(symbol: on ? "speaker.slash.fill" : "hifispeaker.fill", title: on ? "Monitor muted" : "Monitor unmuted")
            case .dim:
                self.hud.show(symbol: on ? "speaker.wave.1.fill" : "hifispeaker.fill", title: on ? "Monitor dimmed" : "Dim off")
            case .mono:
                self.hud.show(symbol: on ? "circle.fill" : "circle.lefthalf.filled", title: on ? "Monitor mono" : "Monitor stereo")
            }
        }
    }

    // MARK: Menu items, processes, opening things

    private func pressMenuItem(_ text: String) {
        let path = text.components(separatedBy: ">").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let pid = state.frontApp.pid
        let app = state.frontApp.name
        background.async {
            if !AX.pressMenuItem(path: path, pid: pid) {
                Log.write("menu item not found or disabled in \(app): \(path.joined(separator: " > "))")
            }
        }
    }

    private func launch(_ tool: String, _ arguments: [String], info: RunInfo, what: String) {
        var env = ProcessInfo.processInfo.environment
        env["KNOB_DIRECTION"] = String(info.direction)
        env["KNOB_MULTIPLIER"] = String(format: "%.2f", info.multiplier)
        env["KNOB_GESTURE"] = info.gesture?.rawValue ?? ""
        env["KNOB_APP"] = state.frontApp.bundleID ?? ""
        env["KNOB_MODE"] = state.context.displayMode?.name ?? ""
        background.async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            process.environment = env
            process.standardOutput = FileHandle.nullDevice
            let errors = Pipe()
            process.standardError = errors
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus != 0 {
                    let text = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    Log.write("\(what) exited \(process.terminationStatus): \(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))")
                }
            } catch {
                Log.write("\(what) could not start: \(error.localizedDescription)")
            }
        }
    }

    private func open(_ text: String) {
        let target = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return }
        if target.hasPrefix("/") || target.hasPrefix("~") {
            NSWorkspace.shared.open(URL(fileURLWithPath: (target as NSString).expandingTildeInPath))
        } else if let url = URL(string: target), url.scheme != nil {
            NSWorkspace.shared.open(url)
        } else if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: target) {
            NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
        } else {
            Log.write("open: nothing found for \(target)")
        }
    }

    // MARK: Macros

    private func runSteps(_ steps: ArraySlice<MacroStep>, info: RunInfo) {
        guard let step = steps.first else { return }
        let rest = steps.dropFirst()
        let go = { [weak self] in
            guard let self else { return }
            // Macros do not nest: a macro step inside a macro is skipped.
            if step.action.kind != .macro { self.run(step.action, info: info) }
            self.runSteps(rest, info: info)
        }
        if step.delayMs > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(step.delayMs), execute: go)
        } else {
            go()
        }
    }
}
