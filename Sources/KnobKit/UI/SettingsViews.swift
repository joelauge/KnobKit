import AppKit
import KnobCore
import ServiceManagement
import SwiftUI

private func openPrivacyPane(_ anchor: String) {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Permissions (shared by the menu and the Devices page)

struct PermissionsCard: View {
    @EnvironmentObject private var state: AppState
    var compact = false

    private var needsDeviceAccess: Bool { state.config.settings.deviceMode == .selected }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            row(ok: state.axTrusted,
                title: "Accessibility",
                detail: "Lets KnobKit catch the knob's events and send keystrokes and scrolls.",
                action: "Grant…") {
                AX.promptForTrust()
                openPrivacyPane("Privacy_Accessibility")
            }
            row(ok: state.hidAccess == .granted || !needsDeviceAccess,
                title: "Input Monitoring",
                detail: needsDeviceAccess
                    ? "Lets KnobKit tell your keyboard's knob apart from your Mac's own volume keys. Only volume and mute signals are read."
                    : "Not needed while every volume key counts as the knob.",
                action: "Grant…") {
                HIDWatcher.requestAccess()
                openPrivacyPane("Privacy_ListenEvent")
            }
            if state.hidAccess == .granted && !state.hidListening {
                HStack(spacing: 10) {
                    Note("Input Monitoring was just granted. Relaunch to start using it.")
                    Button("Relaunch") { Relauncher.relaunch() }.buttonStyle(.kkSmall)
                }
            }
        }
    }

    private func row(ok: Bool, title: String, detail: String, action: String, perform: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 10) {
            StatusDot(ok: ok)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).fontWeight(.medium)
                if !compact || !ok { Note(detail) }
            }
            Spacer(minLength: 8)
            if !ok {
                Button(action, action: perform).buttonStyle(KKButtonStyle(kind: .solid, small: true))
            } else if !compact {
                Eyebrow("Granted")
            }
        }
    }
}

enum Relauncher {
    static func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.6; /usr/bin/open \"\(path)\""]
        try? task.run()
        NSApp.terminate(nil)
    }
}

// MARK: - Devices

struct DevicesView: View {
    @EnvironmentObject private var state: AppState

    /// Remembered devices that are not connected right now.
    private var offline: [DeviceRef] {
        state.config.settings.devices.filter { ref in
            !state.devices.contains { $0.vendorID == ref.vendorID && $0.productID == ref.productID }
        }
    }

    var body: some View {
        Page(title: "Devices", subtitle: "Which keyboard counts as the knob, and what KnobKit is allowed to see.") {
            Card(title: "Permissions") { PermissionsCard() }

            Card(title: "What counts as the knob") {
                RadioRow(title: "Only the devices ticked below", selected: state.config.settings.deviceMode == .selected) {
                    state.config.settings.deviceMode = .selected
                }
                RadioRow(title: "Any volume or mute key, on any keyboard", selected: state.config.settings.deviceMode == .any) {
                    state.config.settings.deviceMode = .any
                }
                Note("The knob reaches the Mac as volume up, volume down and mute, the same signals as the keyboard's Fn media keys. With device filtering your MacBook's own volume keys and other keyboards keep working normally.")
            }

            Card(title: "Find my knob") {
                HStack(alignment: .center, spacing: 14) {
                    DialView(position: 0.5, size: 46).opacity(state.learningKnob ? 1 : 0.6)
                    VStack(alignment: .leading, spacing: 4) {
                        if state.learningKnob {
                            Text("Turn or press the knob now…").fontWeight(.medium)
                            Note("The first keyboard to send a volume signal becomes the knob.")
                        } else if let name = state.learnedDevice {
                            Text("\(name) is the knob.").fontWeight(.medium)
                            Note("It is ticked in the list below.")
                        } else {
                            Text(state.knobConnected ? "A knob keyboard is connected." : "No knob keyboard is connected.")
                                .fontWeight(.medium)
                            Note("Epomaker keyboards are ticked automatically when their name gives them away. For any other, press the button and turn the knob.")
                        }
                    }
                    Spacer(minLength: 8)
                    if state.learningKnob {
                        Button("Cancel") { state.stopLearningKnob() }
                    } else {
                        Button("Find my knob") { state.startLearningKnob() }
                            .buttonStyle(KKButtonStyle(kind: state.knobConnected ? .outline : .solid))
                            .disabled(state.hidAccess != .granted)
                    }
                }
            }

            Card(title: "Connected devices with volume controls") {
                if state.devices.isEmpty {
                    Text("No devices found.").foregroundStyle(Theme.ink2)
                }
                ForEach(Array(state.devices.enumerated()), id: \.element.id) { index, device in
                    if index > 0 { Rule() }
                    Toggle(isOn: Binding(get: { state.isSelected(device) }, set: { state.setSelected(device, $0) })) {
                        HStack(spacing: 10) {
                            Image(systemName: device.isKeyboard ? "keyboard" : "hifispeaker")
                                .font(.system(size: 14, weight: .light))
                                .frame(width: 22)
                            Text(device.name)
                            Leader()
                            Text("\(device.transport)  ·  \(String(format: "%04X:%04X", device.vendorID, device.productID))")
                                .font(.kkMono).foregroundStyle(Theme.ink2)
                        }
                    }
                    .disabled(state.config.settings.deviceMode == .any)
                }
                if !offline.isEmpty {
                    Rule()
                    Eyebrow("Remembered, not connected")
                    ForEach(offline) { ref in
                        HStack(spacing: 10) {
                            Image(systemName: "keyboard").font(.system(size: 14, weight: .light))
                                .frame(width: 22).foregroundStyle(Theme.ink3)
                            Text(ref.name).foregroundStyle(Theme.ink2)
                            Leader()
                            Text(ref.transport).font(.kkMono).foregroundStyle(Theme.ink2)
                            Button("Forget") { state.config.settings.devices.removeAll { $0 == ref } }
                                .buttonStyle(.kkSmall)
                        }
                    }
                }
                Note("Bluetooth, the 2.4G dongle and USB each show up as a separate device. Connect the keyboard each way once and it is remembered.")
            }
        }
    }
}

// MARK: - Knob feel

struct FeelView: View {
    @EnvironmentObject private var state: AppState

    private func ms(_ v: Double) -> String { "\(Int((v * 1000).rounded())) ms" }
    private func perSecond(_ v: Double) -> String { "\(Int(v.rounded())) detents/s" }

    var body: some View {
        Page(title: "Knob feel", subtitle: "Timing for presses and how turning speed is read.") {
            Card(title: "Presses") {
                SliderRow(title: "Double-press window",
                          help: "Longest gap between presses that still counts as a double or triple press. A single press waits this long only where a double press is bound.",
                          value: $state.config.settings.doublePressInterval, range: 0.15...0.6, step: 0.01, format: ms)
                Rule()
                SliderRow(title: "Long press",
                          help: "How long to hold before a long press fires. The F75 sends every press as an instant tap and cannot signal long presses, so this only matters for keyboards that report the knob being held.",
                          value: $state.config.settings.longPressDuration, range: 0.25...1.5, step: 0.05, format: ms)
            }

            Card(title: "Hold and turn (depends on the keyboard)") {
                SliderRow(title: "Chord grace",
                          help: "Some keyboards report a held press as released the instant a turn starts. A release this close to a turn is treated as still held.",
                          value: $state.config.settings.chordGrace, range: 0.01...0.12, step: 0.005, format: ms)
                Rule()
                SliderRow(title: "Hold memory",
                          help: "After such a release, how long turning keeps counting as hold-and-turn.",
                          value: $state.config.settings.virtualHoldTimeout, range: 0.2...2, step: 0.05, format: ms)
            }

            Card(title: "Speed") {
                Note("The defaults were measured on an F75 over Bluetooth: an ordinary continuous turn reports about 15 to 25 detents per second, and a quick spin tops out near 33. Watch the speeds in the Live monitor to tune them for another keyboard.")
                SliderRow(title: "Fast turn threshold",
                          help: "Turning faster than this triggers a binding's “when spun fast” action.",
                          value: $state.config.settings.fastThreshold, range: 5...40, step: 1, format: perSecond)
                Rule()
                SliderRow(title: "Acceleration starts at",
                          help: "Below this speed every detent counts once.",
                          value: $state.config.settings.accelSlowRate, range: 2...30, step: 1, format: perSecond)
                Rule()
                SliderRow(title: "Acceleration tops out at",
                          help: "At this speed and above the full multiplier applies.",
                          value: $state.config.settings.accelFastRate, range: 10...60, step: 1, format: perSecond)
                Rule()
                SliderRow(title: "Maximum multiplier",
                          help: "Applies to bindings with “Speed up when spun fast” turned on.",
                          value: $state.config.settings.accelMaxMultiplier, range: 1...10, step: 0.5,
                          format: { String(format: "×%.1f", $0) })
            }

            Card(title: "Direction") {
                Toggle("Reverse the knob (turning right acts as left)", isOn: $state.config.settings.invertRotation)
            }
        }
    }
}

// MARK: - General

struct GeneralView: View {
    @EnvironmentObject private var state: AppState
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var confirmReset = false
    @State private var message = ""

    var body: some View {
        Page(title: "General") {
            Card(title: "KnobKit") {
                Toggle("Knob remapping enabled", isOn: $state.config.settings.enabled)
                Toggle("Open at login", isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin))
                Toggle("Show the mode name next to the menu bar icon", isOn: $state.config.settings.menuBarShowsModeName)
            }

            Card(title: "On-screen display") {
                Toggle("Show when the mode or volume changes", isOn: $state.config.settings.showHUD)
                Toggle("Also show for every knob action", isOn: $state.config.settings.hudOnEveryAction)
                    .disabled(!state.config.settings.showHUD)
                HStack(spacing: 10) {
                    Text("Position")
                    KKPicker(selection: $state.config.settings.hudPosition,
                             options: HUDPosition.allCases.map { (value: $0, title: $0.title) })
                }
                Rule()
                SliderRow(title: "Stays for", help: "", value: $state.config.settings.hudDuration,
                          range: 0.4...3, step: 0.1, format: { String(format: "%.1f s", $0) })
            }

            Card(title: "Universal Audio monitor") {
                SliderRow(title: "Monitor level ceiling",
                          help: "The knob never raises an Apollo's monitor level above this, however fast it is spun. Levels set on the hardware itself are left alone.",
                          value: $state.config.settings.monitorCeiling, range: -60...0, step: 1,
                          format: { String(format: "%.0f dB", $0) })
                Rule()
                HStack(alignment: .center, spacing: 12) {
                    Button("Use the Apollo for volume") {
                        let changed = state.config.adoptMonitorVolume()
                        message = changed == 0
                            ? "Global's volume controls already use the Apollo."
                            : "Updated \(changed) Global bindings: turning sets the monitor level, pressing mutes it."
                    }
                    Note("Points Global's volume bindings at the Apollo. They still use the Mac's own volume on other outputs.")
                }
            }

            Card(title: "Configuration file") {
                Note("Everything is stored as readable JSON and can be edited by hand.")
                HStack(spacing: 8) {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([ConfigStore.url]) }
                    Button("Export…", action: exportConfig)
                    Button("Import…", action: importConfig)
                    Button("Reload from disk") {
                        state.config = ConfigStore.load()
                        message = "Reloaded."
                    }
                    Button("Show log") { NSWorkspace.shared.activateFileViewerSelecting([Log.url]) }
                        .buttonStyle(KKButtonStyle(kind: .ghost))
                    Spacer()
                    Button("Reset to defaults…", role: .destructive) { confirmReset = true }
                }
                if !message.isEmpty { Note(message) }
            }
        }
        .confirmationDialog("Reset every profile and setting to the defaults?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) {
                let devices = state.config.settings.devices
                var fresh = ConfigStore.firstRunConfig()
                fresh.settings.devices = devices
                state.config = fresh
                state.selection = .profile(fresh.global.id)
            }
        } message: {
            Text("A copy of the current file is kept next to it.")
        }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLogin = on
            message = ""
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            message = "Could not change the login item: \(error.localizedDescription)"
        }
    }

    private func exportConfig() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "KnobKit config.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try state.config.encoded().write(to: url, options: .atomic)
            message = "Exported to \(url.lastPathComponent)."
        } catch {
            message = "Export failed: \(error.localizedDescription)"
        }
    }

    private func importConfig() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let imported = try Config.decode(Data(contentsOf: url))
            let backup = ConfigStore.directory.appendingPathComponent("config.before-import-\(Int(Date().timeIntervalSince1970)).json")
            try? state.config.encoded().write(to: backup)
            state.config = imported
            state.selection = .profile(imported.global.id)
            message = "Imported. The previous configuration was saved as \(backup.lastPathComponent)."
        } catch {
            message = "That file is not a KnobKit configuration: \(error.localizedDescription)"
        }
    }
}

// MARK: - Live monitor

struct MonitorView: View {
    @ObservedObject var log: MonitorLog
    var simulate: ([String]) -> Void

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageTitle(title: "Live monitor",
                      subtitle: "Turn or press the knob to see what arrives, which device sent it, and what KnobKit did with it. Ordinary typing is never shown or logged.")
            HStack(spacing: 8) {
                Eyebrow("Try without the knob")
                Button { simulate(["ccw"]) } label: { Label("Left", systemImage: "arrow.counterclockwise") }
                Button { simulate(["cw"]) } label: { Label("Right", systemImage: "arrow.clockwise") }
                Button("Press") { simulate(["press"]) }
                Button("Double") { simulate(["press", "wait:60", "press"]) }
                Button("Long") { simulate(["down", "wait:900", "up"]) }
                Spacer()
                Button("Clear") { log.entries.removeAll() }.buttonStyle(.kkGhost)
            }
            .buttonStyle(.kkSmall)

            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Eyebrow("Time").frame(width: 104, alignment: .leading)
                    Eyebrow("Source").frame(width: 190, alignment: .leading)
                    Eyebrow("Event").frame(width: 230, alignment: .leading)
                    Eyebrow("Result")
                    Spacer()
                }
                .padding(.horizontal, 14).frame(height: 30)
                Rule()
                if log.entries.isEmpty {
                    VStack(spacing: 14) {
                        DialView(position: 0.5, size: 72).opacity(0.7)
                        Text("Nothing yet. Turn the knob.").fontWeight(.medium)
                        Text("If only the keyboard's own lighting changes, the knob is in its lighting mode and sends nothing to the Mac. On the F75, hold the knob down for 3 to 5 seconds to switch it to volume mode. If events show up as “not the knob”, use Find my knob under Devices.")
                            .font(.kkCaption)
                            .foregroundStyle(Theme.ink2)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 460)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(log.entries.reversed()) { entry in
                                HStack(spacing: 0) {
                                    Text(Self.time.string(from: entry.time))
                                        .font(.kkMono).foregroundStyle(Theme.ink2)
                                        .frame(width: 104, alignment: .leading)
                                    Text(entry.source).lineLimit(1).frame(width: 190, alignment: .leading)
                                    Text(entry.event).lineLimit(1).frame(width: 230, alignment: .leading)
                                    Image(systemName: entry.swallowed ? "arrow.triangle.branch" : "arrow.right")
                                        .font(.system(size: 11, weight: .light))
                                        .foregroundStyle(entry.swallowed ? Theme.ink : Theme.ink3)
                                        .frame(width: 22, alignment: .leading)
                                    Text(entry.result).lineLimit(1)
                                        .foregroundStyle(entry.swallowed ? Theme.ink : Theme.ink2)
                                    Spacer(minLength: 0)
                                }
                                .font(.system(size: 12))
                                .padding(.horizontal, 14).frame(height: 25)
                                .overlay(alignment: .bottom) { Rule(color: Theme.ink.opacity(0.08)) }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .padding(.horizontal, 30)
        .padding(.top, 38)
        .padding(.bottom, 26)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
