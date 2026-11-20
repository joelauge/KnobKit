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
        VStack(alignment: .leading, spacing: 10) {
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
                    ? "Lets KnobKit tell the F75's knob apart from your Mac's own volume keys. Only volume and mute signals are read."
                    : "Not needed while every volume key counts as the knob.",
                action: "Grant…") {
                HIDWatcher.requestAccess()
                openPrivacyPane("Privacy_ListenEvent")
            }
            if state.hidAccess == .granted && !state.hidListening {
                HStack {
                    Text("Input Monitoring was just granted. Relaunch to start using it.").font(.callout)
                    Button("Relaunch") { Relauncher.relaunch() }
                }
            }
        }
    }

    private func row(ok: Bool, title: String, detail: String, action: String, perform: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 8) {
            StatusDot(ok: ok)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                if !compact || !ok {
                    Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            if !ok { Button(action, action: perform).controlSize(.small) }
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
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Devices").font(.title2.bold())
                Card(title: "Permissions") { PermissionsCard() }

                Card(title: "What counts as the knob") {
                    Picker("", selection: $state.config.settings.deviceMode) {
                        Text("Only the devices ticked below").tag(DeviceMode.selected)
                        Text("Any volume or mute key, on any keyboard").tag(DeviceMode.any)
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    Text("The F75 sends its knob as volume up, volume down and mute, the same signals as its Fn media keys. With device filtering your MacBook's own volume keys and other keyboards keep working normally.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }

                Card(title: "Connected devices with volume controls") {
                    if state.devices.isEmpty {
                        Text("No devices found.").foregroundStyle(.secondary)
                    }
                    ForEach(state.devices) { device in
                        Toggle(isOn: Binding(get: { state.isSelected(device) }, set: { state.setSelected(device, $0) })) {
                            HStack {
                                Image(systemName: device.isKeyboard ? "keyboard" : "hifispeaker")
                                    .frame(width: 22)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(device.name)
                                    Text("\(device.transport)  ·  \(String(format: "%04X:%04X", device.vendorID, device.productID))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .disabled(state.config.settings.deviceMode == .any)
                    }
                    if !offline.isEmpty {
                        Divider()
                        Text("Remembered, not connected").font(.subheadline).foregroundStyle(.secondary)
                        ForEach(offline) { ref in
                            HStack {
                                Image(systemName: "keyboard").frame(width: 22).foregroundStyle(.secondary)
                                Text("\(ref.name)  ·  \(ref.transport)").foregroundStyle(.secondary)
                                Spacer()
                                Button("Forget") { state.config.settings.devices.removeAll { $0 == ref } }
                                    .controlSize(.small)
                            }
                        }
                    }
                    Text("Bluetooth, the 2.4G dongle and USB each show up as a separate device. Connect the keyboard each way once and it is remembered.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Knob feel

struct FeelView: View {
    @EnvironmentObject private var state: AppState

    private func ms(_ v: Double) -> String { "\(Int((v * 1000).rounded())) ms" }
    private func perSecond(_ v: Double) -> String { "\(Int(v.rounded())) detents/s" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Knob feel").font(.title2.bold())

                Card(title: "Presses") {
                    SliderRow(title: "Double-press window",
                              help: "Longest gap between presses that still counts as a double or triple press. A single press waits this long only where a double press is bound.",
                              value: $state.config.settings.doublePressInterval, range: 0.15...0.6, step: 0.01, format: ms)
                    SliderRow(title: "Long press",
                              help: "How long to hold before a long press fires. The F75 cannot signal long presses (it sends every press as an instant tap), so this only matters for other controllers.",
                              value: $state.config.settings.longPressDuration, range: 0.25...1.5, step: 0.05, format: ms)
                }

                Card(title: "Hold and turn (not sent by the F75)") {
                    SliderRow(title: "Chord grace",
                              help: "The F75 can report a held press as released the instant a turn starts. A release this close to a turn is treated as still held.",
                              value: $state.config.settings.chordGrace, range: 0.01...0.12, step: 0.005, format: ms)
                    SliderRow(title: "Hold memory",
                              help: "After such a release, how long turning keeps counting as hold-and-turn.",
                              value: $state.config.settings.virtualHoldTimeout, range: 0.2...2, step: 0.05, format: ms)
                }

                Card(title: "Speed") {
                    Text("Over Bluetooth the F75 reports an ordinary continuous turn at about 15 to 25 detents per second, and a quick spin tops out near 33.")
                        .font(.caption).foregroundStyle(.secondary)
                    SliderRow(title: "Fast turn threshold",
                              help: "Turning faster than this triggers a binding's “when spun fast” action.",
                              value: $state.config.settings.fastThreshold, range: 5...40, step: 1, format: perSecond)
                    SliderRow(title: "Acceleration starts at",
                              help: "Below this speed every detent counts once.",
                              value: $state.config.settings.accelSlowRate, range: 2...30, step: 1, format: perSecond)
                    SliderRow(title: "Acceleration tops out at",
                              help: "At this speed and above the full multiplier applies.",
                              value: $state.config.settings.accelFastRate, range: 10...60, step: 1, format: perSecond)
                    SliderRow(title: "Maximum multiplier",
                              help: "Applies to bindings with “Speed up when spun fast” turned on.",
                              value: $state.config.settings.accelMaxMultiplier, range: 1...10, step: 0.5,
                              format: { String(format: "×%.1f", $0) })
                }

                Card(title: "Direction") {
                    Toggle("Reverse the knob (turning right acts as left)", isOn: $state.config.settings.invertRotation)
                }
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
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
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("General").font(.title2.bold())

                Card(title: "KnobKit") {
                    Toggle("Knob remapping enabled", isOn: $state.config.settings.enabled)
                    Toggle("Open at login", isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin))
                    Toggle("Show the mode name next to the menu bar icon", isOn: $state.config.settings.menuBarShowsModeName)
                }

                Card(title: "On-screen display") {
                    Toggle("Show when the mode or volume changes", isOn: $state.config.settings.showHUD)
                    Toggle("Also show for every knob action", isOn: $state.config.settings.hudOnEveryAction)
                        .disabled(!state.config.settings.showHUD)
                    Picker("Position", selection: $state.config.settings.hudPosition) {
                        ForEach(HUDPosition.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .fixedSize()
                    SliderRow(title: "Stays for", help: "", value: $state.config.settings.hudDuration,
                              range: 0.4...3, step: 0.1, format: { String(format: "%.1f s", $0) })
                }

                Card(title: "Universal Audio monitor") {
                    SliderRow(title: "Monitor level ceiling",
                              help: "The knob never raises an Apollo's monitor level above this, however fast it is spun. Levels set on the hardware itself are left alone.",
                              value: $state.config.settings.monitorCeiling, range: -60...0, step: 1,
                              format: { String(format: "%.0f dB", $0) })
                    HStack {
                        Button("Use the Apollo for volume") {
                            let changed = state.config.adoptMonitorVolume()
                            message = changed == 0
                                ? "Global's volume controls already use the Apollo."
                                : "Updated \(changed) Global bindings: turning sets the monitor level, pressing mutes it."
                        }
                        Text("Points Global's volume bindings at the Apollo. They still use the Mac's own volume on other outputs.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }

                Card(title: "Configuration file") {
                    Text("Everything is stored as readable JSON and can be edited by hand.")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([ConfigStore.url]) }
                        Button("Export…", action: exportConfig)
                        Button("Import…", action: importConfig)
                        Button("Reload from disk") {
                            state.config = ConfigStore.load()
                            message = "Reloaded."
                        }
                        Spacer()
                        Button("Reset to defaults…", role: .destructive) { confirmReset = true }
                    }
                    Button("Show log") { NSWorkspace.shared.activateFileViewerSelecting([Log.url]) }
                        .buttonStyle(.link)
                    if !message.isEmpty { Text(message).font(.callout).foregroundStyle(.secondary) }
                }
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
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
        VStack(alignment: .leading, spacing: 12) {
            Text("Live monitor").font(.title2.bold())
            Text("Turn or press the knob to see what arrives, which device sent it, and what KnobKit did with it. Ordinary typing is never shown or logged.")
                .font(.callout).foregroundStyle(.secondary).lineLimit(3)
            HStack {
                Text("Try without the knob:").foregroundStyle(.secondary)
                Button { simulate(["ccw"]) } label: { Label("Left", systemImage: "arrow.counterclockwise") }
                Button { simulate(["cw"]) } label: { Label("Right", systemImage: "arrow.clockwise") }
                Button("Press") { simulate(["press"]) }
                Button("Double") { simulate(["press", "wait:60", "press"]) }
                Button("Long") { simulate(["down", "wait:900", "up"]) }
                Spacer()
                Button("Clear") { log.entries.removeAll() }
            }
            .controlSize(.small)

            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Text("Time").frame(width: 100, alignment: .leading)
                    Text("Source").frame(width: 190, alignment: .leading)
                    Text("Event").frame(width: 230, alignment: .leading)
                    Text("Result")
                    Spacer()
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.vertical, 7)
                Divider()
                if log.entries.isEmpty {
                    VStack(spacing: 8) {
                        Text("Nothing yet. Turn the knob.")
                        Text("If only the keyboard's own lighting changes, the knob is in the F75's lighting mode and sends nothing to the Mac. Hold the knob down for 3 to 5 seconds to switch it to volume mode.")
                            .font(.callout)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 460)
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(log.entries.reversed().enumerated()), id: \.element.id) { index, entry in
                                HStack(spacing: 0) {
                                    Text(Self.time.string(from: entry.time)).monospacedDigit()
                                        .frame(width: 100, alignment: .leading)
                                    Text(entry.source).lineLimit(1).frame(width: 190, alignment: .leading)
                                    Text(entry.event).lineLimit(1).frame(width: 230, alignment: .leading)
                                    Image(systemName: entry.swallowed ? "arrow.triangle.branch" : "arrow.right")
                                        .foregroundStyle(entry.swallowed ? Color.accentColor : Color.secondary)
                                        .frame(width: 22, alignment: .leading)
                                    Text(entry.result).lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .font(.callout)
                                .padding(.horizontal, 12).padding(.vertical, 4)
                                .background(index % 2 == 1 ? Color.primary.opacity(0.035) : Color.clear)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(nsColor: .separatorColor).opacity(0.6)))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
