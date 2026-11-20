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
            Image(nsImage: image).resizable().interpolation(.high).frame(width: size, height: size)
        } else {
            Image(systemName: "app.dashed").font(.system(size: size * 0.8)).frame(width: size, height: size)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Modifier toggles

struct ModifierToggles: View {
    @Binding var modifiers: ModifierSet

    var body: some View {
        HStack(spacing: 3) {
            ForEach(ModifierSet.ordered, id: \.rawValue) { m in
                Toggle(isOn: Binding(
                    get: { modifiers.contains(m) },
                    set: { on in if on { modifiers.insert(m) } else { modifiers.remove(m) } })
                ) {
                    Text(m.symbols).font(.system(size: 13, weight: .medium)).frame(width: 16)
                }
                .toggleStyle(.button)
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
            Menu {
                ForEach(KeyNames.groups, id: \.0) { group in
                    Menu(group.0) {
                        ForEach(group.1, id: \.self) { code in
                            Button(KeyNames.name(code)) { combo.keyCode = code }
                        }
                    }
                }
            } label: {
                Text(KeyNames.name(combo.keyCode)).frame(minWidth: 38)
            }
            .fixedSize()
            Button(recording ? "Press a key…" : "Record") {
                if recording { stop() } else { start() }
            }
            .tint(recording ? .red : nil)
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
            Image(systemName: symbol).font(.system(size: 15)).frame(width: 24, height: 20)
        }
        .help("Mode icon")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(34), spacing: 4), count: 8), spacing: 4) {
                ForEach(Presets.modeSymbols, id: \.self) { name in
                    Button {
                        symbol = name
                        open = false
                    } label: {
                        Image(systemName: name).font(.system(size: 15)).frame(width: 30, height: 28)
                    }
                    .buttonStyle(.plain)
                    .background(RoundedRectangle(cornerRadius: 6).fill(name == symbol ? Color.accentColor.opacity(0.25) : .clear))
                }
            }
            .padding(12)
        }
    }
}

// MARK: - Small layout helpers

struct SliderRow: View {
    let title: String
    let help: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value)).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range, step: step)
            Text(help).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }
}

struct Card<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title).font(.headline)
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(nsColor: .separatorColor).opacity(0.6)))
    }
}

struct StatusDot: View {
    let ok: Bool

    var body: some View {
        Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .foregroundStyle(ok ? Color.green : Color.orange)
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
