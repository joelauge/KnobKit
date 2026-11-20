import AppKit
import KnobCore
import SwiftUI

// MARK: - App icons and names

enum AppInfo {
    private static var icons: [String: NSImage] = [:]
    private static var names: [String: String] = [:]

    private static func url(for pattern: String) -> URL? {
        if pattern.hasSuffix("*") {
            let prefix = String(pattern.dropLast())
            return NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier?.hasPrefix(prefix) == true }?.bundleURL
        }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: pattern)
    }

    static func icon(for bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let cached = icons[bundleID] { return cached }
        guard let url = url(for: bundleID) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        icons[bundleID] = image
        return image
    }

    static func name(for bundleID: String) -> String {
        if let cached = names[bundleID] { return cached }
        guard let url = url(for: bundleID) else { return bundleID }
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        names[bundleID] = name
        return name
    }

    /// pid of a running app matching any of the patterns.
    static func runningPID(for patterns: [String]) -> pid_t? {
        for app in NSWorkspace.shared.runningApplications {
            guard let id = app.bundleIdentifier else { continue }
            for p in patterns {
                if p.hasSuffix("*") ? id.hasPrefix(String(p.dropLast())) : id.caseInsensitiveCompare(p) == .orderedSame {
                    return app.processIdentifier
                }
            }
        }
        return nil
    }
}

struct AppIcon: View {
    let bundleID: String?
    var size: CGFloat = 18

    var body: some View {
        if let image = AppInfo.icon(for: bundleID) {
            // Drawn in the theme's two tones so a row of app icons does not shout.
            Image(nsImage: image).resizable().interpolation(.high).frame(width: size, height: size)
                .saturation(0).colorMultiply(Theme.ink)
        } else {
            Image(systemName: "app.dashed").font(.system(size: size * 0.8, weight: .light)).frame(width: size, height: size)
                .foregroundStyle(Theme.ink2)
        }
    }
}

// MARK: - Modifier toggles

struct ModifierToggles: View {
    @Binding var modifiers: ModifierSet

    var body: some View {
        HStack(spacing: 4) {
            ForEach(ModifierSet.ordered, id: \.rawValue) { m in
                KeyToggle(text: m.symbols, isOn: Binding(
                    get: { modifiers.contains(m) },
                    set: { on in if on { modifiers.insert(m) } else { modifiers.remove(m) } }))
            }
        }
    }
}

// MARK: - Key combo editor

/// Modifier toggles + a key menu + a recorder. The menu exists because some combos
/// (⌘⇥, ⌃→ …) are taken by the system and can never be recorded by pressing them.
struct KeyComboEditor: View {
    @Binding var combo: KeyCombo
    @EnvironmentObject private var state: AppState
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 8) {
            ModifierToggles(modifiers: $combo.modifiers)
            KKMenu(items: {
                KeyNames.groups.map { group in
                    .submenu(group.0, group.1.map { code in
                        .action(KeyNames.name(code), checked: code == combo.keyCode) { combo.keyCode = code }
                    })
                }
            }) {
                KKMenuLabel(title: KeyNames.name(combo.keyCode), chevron: "chevron.up.chevron.down")
                    .frame(minWidth: 38)
            }
            Button(recording ? "Press a key…" : "Record") {
                if recording { stop() } else { start() }
            }
            .buttonStyle(KKButtonStyle(kind: recording ? .solid : .outline))
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        state.isRecordingKey = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            combo = KeyCombo(Int(event.keyCode), ModifierSet(nsFlags: event.modifierFlags))
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        state.isRecordingKey = false
    }
}

// MARK: - Symbol picker

struct SymbolPicker: View {
    @Binding var symbol: String
    @State private var open = false

    var body: some View {
        Button {
            open = true
        } label: {
            Image(systemName: symbol).font(.system(size: 14, weight: .light)).frame(width: 30)
        }
        .help("Mode icon")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(32), spacing: 4), count: 8), spacing: 4) {
                ForEach(Presets.modeSymbols, id: \.self) { name in
                    Button {
                        symbol = name
                        open = false
                    } label: {
                        Image(systemName: name).font(.system(size: 14, weight: .light))
                            .frame(width: 32, height: 30)
                            .foregroundStyle(name == symbol ? Theme.bg : Theme.ink)
                            .background(RoundedRectangle(cornerRadius: Theme.radius).fill(name == symbol ? Theme.ink : .clear))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
            // Scaled so the popover's arrow takes the same black.
            .background(Theme.bg.scaleEffect(1.6))
            .kkRoot()
        }
    }
}

// MARK: - Small layout helpers

/// A labelled ruler: name, leader line, value, then the slider and what it does.
struct SliderRow: View {
    let title: String
    let help: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(title)
                Leader()
                Text(format(value)).font(.kkMono).foregroundStyle(Theme.ink)
            }
            KKSlider(value: $value, in: range, step: step)
            if !help.isEmpty { Note(help) }
        }
        .padding(.vertical, 3)
    }
}

/// Granted / needs attention.
struct StatusDot: View {
    let ok: Bool

    var body: some View {
        Image(systemName: ok ? "checkmark.circle" : "exclamationmark.triangle")
            .font(.system(size: 14, weight: .light))
            .foregroundStyle(ok ? Theme.ink : Theme.warn)
    }
}

// MARK: - Choosing apps

enum AppChooser {
    /// Regular, visible apps currently running, sorted by name.
    static func running() -> [(name: String, bundleID: String)] {
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> (String, String)? in
                guard let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier, seen.insert(id).inserted else { return nil }
                return (app.localizedName ?? id, id)
            }
            .sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
            .map { (name: $0.0, bundleID: $0.1) }
    }

    /// Open panel on /Applications; returns (name, bundle id).
    static func pick() -> (name: String, bundleID: String)? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier else { return nil }
        return (FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""), id)
    }
}
