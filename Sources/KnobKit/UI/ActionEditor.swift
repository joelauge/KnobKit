import AppKit
import KnobCore
import SwiftUI

/// Editor for a single action: a kind picker plus the fields that kind needs.
struct ActionEditor: View {
    @Binding var action: Action
    /// +1 / -1 for rotation rows so new actions start with a sensible sign.
    var direction = 0
    var modeNames: [String] = []
    /// Apps this binding targets, used to browse their menus.
    var targetBundleIDs: [String] = []
    var allowMacro = true

    private static let groups: [(String, [ActionKind])] = [
        ("Basics", [.passthrough, .none]),
        ("Sound and media", [.volume, .muteToggle, .mediaKey, .monitorLevel, .monitorToggle]),
        ("Keyboard", [.keystroke, .stickyKeystroke, .typeText]),
        ("Pointer", [.scroll]),
        ("Apps", [.menuItem, .open]),
        ("Modes", [.modeNext, .modePrevious, .modeSet]),
        ("Automation", [.shell, .appleScript, .shortcut, .macro]),
    ]

    /// Changing the kind fills in reasonable starting values for that kind.
    private var kind: Binding<ActionKind> {
        Binding(get: { action.kind }, set: { new in
            var a = action
            a.kind = new
            let sign = direction < 0 ? -1.0 : 1.0
            switch new {
            case .volume:
                if a.amount == 0 { a.amount = 2 * sign }
            case .monitorLevel:
                // Volume steps are percentages; start a monitor step at a sane 1 dB.
                a.amount = sign
            case .scroll:
                if a.dx == 0 && a.dy == 0 { a.dy = 70 * sign }
            case .stickyKeystroke:
                if a.hold.isEmpty {
                    a.hold = .command
                    a.key = KeyCombo(Key.tab, direction < 0 ? .shift : [])
                }
            case .mediaKey:
                if direction != 0 { a.mediaKey = direction > 0 ? .next : .previous }
            case .modeSet:
                if a.text.isEmpty { a.text = modeNames.first ?? "" }
            case .macro:
                if a.steps.isEmpty { a.steps = [MacroStep(.key(Key.space))] }
            default:
                break
            }
            action = a
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            KKPicker(selection: kind, groups: Self.groups.map { group in
                (title: Optional(group.0),
                 options: group.1.filter { allowMacro || $0 != .macro }.map { (value: $0, title: $0.title) })
            })
            fields
        }
    }

    @ViewBuilder private var fields: some View {
        switch action.kind {
        case .passthrough:
            hint("Leaves the event alone: the knob changes volume, a press mutes.")
        case .none:
            hint("Swallows the event so nothing happens.")
        case .volume:
            HStack(spacing: 10) {
                Text("Step").foregroundStyle(Theme.ink2)
                NumberField(value: $action.amount, range: -25...25, step: 0.5, decimals: 1)
                Text("% of full volume per detent").foregroundStyle(Theme.ink2)
            }
        case .muteToggle, .modeNext, .modePrevious:
            EmptyView()
        case .monitorLevel:
            HStack(spacing: 10) {
                Text("Step").foregroundStyle(Theme.ink2)
                NumberField(value: $action.amount, range: -12...12, step: 0.5, decimals: 1)
                Text("dB per detent (0.5 dB resolution)").foregroundStyle(Theme.ink2)
            }
            Toggle("Use the Mac's own volume when the current output has one", isOn: $action.auto)
            hint("Sets the monitor level of a Universal Audio Apollo through the UA mixer on this Mac. It never raises the level above the ceiling set under General.")
        case .monitorToggle:
            HStack(spacing: 14) {
                Segmented(selection: $action.monitorSwitch,
                          options: MonitorSwitch.allCases.map { (value: $0, title: $0.title) })
                if action.monitorSwitch == .mute {
                    Toggle("Use the Mac's own mute when the current output has one", isOn: $action.auto)
                }
            }
            hint("Toggles mute, dim or mono on the Apollo's monitor output.")
        case .mediaKey:
            HStack(spacing: 14) {
                KKPicker(selection: $action.mediaKey, options: MediaKey.allCases.map { (value: $0, title: $0.title) })
                Toggle("Fine (quarter step)", isOn: $action.fine)
                KKStepper("×\(action.count)", value: $action.count, in: 1...10)
            }
        case .keystroke:
            HStack(spacing: 14) {
                KeyComboEditor(combo: $action.key)
                KKStepper("×\(action.count)", value: $action.count, in: 1...20)
            }
        case .stickyKeystroke:
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Text("Keep held").foregroundStyle(Theme.ink2)
                    ModifierToggles(modifiers: $action.hold)
                    Text("then tap").foregroundStyle(Theme.ink2)
                }
                KeyComboEditor(combo: $action.key)
                HStack(spacing: 10) {
                    Text("Release after").foregroundStyle(Theme.ink2)
                    KKSlider(value: $action.releaseAfter, in: 0.2...3, step: 0.1).frame(width: 170)
                    Text(String(format: "%.1f s of no turning", action.releaseAfter))
                        .font(.kkMono).foregroundStyle(Theme.ink2)
                }
                hint("For switchers that commit when the modifier is released, such as ⌘⇥ or ⌃⇥.")
            }
        case .typeText:
            TextField("Text to type", text: $action.text)
        case .scroll:
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Text("Down").foregroundStyle(Theme.ink2)
                    NumberField(value: $action.dy, range: -2000...2000, step: 10, width: 54)
                    Text("Right").foregroundStyle(Theme.ink2).padding(.leading, 6)
                    NumberField(value: $action.dx, range: -2000...2000, step: 10, width: 54)
                    Segmented(selection: $action.unit,
                              options: [(value: ScrollUnit.pixel, title: "pixels"), (value: ScrollUnit.line, title: "lines")])
                }
                HStack(spacing: 10) {
                    Toggle("Smooth", isOn: $action.smooth).disabled(action.unit == .line)
                    Text("With").foregroundStyle(Theme.ink2).padding(.leading, 8)
                    ModifierToggles(modifiers: $action.hold)
                }
                hint("Negative values scroll up or left. Scrolling goes to whatever is under the pointer.")
            }
        case .menuItem:
            MenuItemField(text: $action.text, targetBundleIDs: targetBundleIDs)
        case .shell:
            ScriptField(text: $action.text, placeholder: "echo \"$KNOB_DIRECTION\" >> /tmp/knob.txt")
            hint("Runs in zsh. Variables: KNOB_DIRECTION (1 / -1), KNOB_MULTIPLIER, KNOB_GESTURE, KNOB_APP, KNOB_MODE.")
        case .appleScript:
            ScriptField(text: $action.text, placeholder: "tell application \"Music\" to playpause")
        case .shortcut:
            ShortcutField(name: $action.text)
        case .open:
            HStack(spacing: 8) {
                TextField("URL, file path or bundle id", text: $action.text)
                Button("Choose app…") {
                    if let picked = AppChooser.pick() { action.text = picked.bundleID }
                }
            }
        case .modeSet:
            if modeNames.isEmpty {
                TextField("Mode name", text: $action.text)
            } else {
                KKPicker(selection: $action.text,
                         options: (modeNames.contains(action.text) ? modeNames : [action.text] + modeNames)
                             .map { (value: $0, title: $0.isEmpty ? "Choose a mode" : $0) })
            }
        case .macro:
            MacroEditor(steps: $action.steps, modeNames: modeNames, targetBundleIDs: targetBundleIDs)
        }
    }

    private func hint(_ text: String) -> some View {
        Note(text).fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Script text

private struct ScriptField: View {
    @Binding var text: String
    let placeholder: String

    var body: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.ink)
                .frame(minHeight: 54, maxHeight: 120)
                .scrollContentBackground(.hidden)
                .padding(4)
            if text.isEmpty {
                Text(placeholder)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.ink3)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .allowsHitTesting(false)
            }
        }
        .background(RoundedRectangle(cornerRadius: Theme.radius).fill(Theme.raised.opacity(0.6)))
        .kkOutline(Theme.lineStrong)
    }
}

// MARK: - Menu item picker

private func menuItems(_ nodes: [AX.MenuNode], path: [String], pick: @escaping ([String]) -> Void) -> [KKMenuItem] {
    nodes.map { node in
        node.children.isEmpty
            ? .action(node.title) { pick(path + [node.title]) }
            : .submenu(node.title, menuItems(node.children, path: path + [node.title], pick: pick))
    }
}

private struct MenuItemField: View {
    @Binding var text: String
    let targetBundleIDs: [String]
    @EnvironmentObject private var state: AppState
    @State private var tree: [AX.MenuNode] = []
    @State private var status = ""
    @State private var loading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("View > Zoom In", text: $text)
                if tree.isEmpty {
                    Button(loading ? "Reading…" : "Read menus") { load() }.disabled(loading)
                } else {
                    KKMenu("Pick", items: {
                        menuItems(tree, path: []) { text = $0.joined(separator: " > ") }
                    })
                }
            }
            Note(status.isEmpty ? "Clicks a menu bar item by name, even ones without a shortcut. Separate levels with >." : status)
        }
    }

    private func load() {
        let pid: pid_t
        let name: String
        if !targetBundleIDs.isEmpty {
            guard let found = AppInfo.runningPID(for: targetBundleIDs) else {
                status = "Open the app first, then read its menus."
                return
            }
            pid = found
            name = AppInfo.name(for: targetBundleIDs[0])
        } else {
            pid = state.frontApp.pid
            name = state.frontApp.name
        }
        loading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let nodes = AX.menuTree(pid: pid)
            DispatchQueue.main.async {
                loading = false
                tree = nodes
                status = nodes.isEmpty ? "Could not read menus from \(name). Is Accessibility granted?" : "Menus read from \(name)."
            }
        }
    }
}

// MARK: - Shortcuts

private struct ShortcutField: View {
    @Binding var name: String
    @State private var available: [String] = []

    var body: some View {
        HStack(spacing: 8) {
            TextField("Shortcut name", text: $name)
            KKMenu("Pick", items: {
                available.isEmpty
                    ? [.action("No shortcuts found", enabled: false) {}]
                    : available.map { s in .action(s, checked: s == name) { name = s } }
            })
        }
        .onAppear(perform: load)
    }

    private func load() {
        guard available.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            p.arguments = ["list"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let names = (String(data: data, encoding: .utf8) ?? "").split(separator: "\n").map(String.init).sorted()
            DispatchQueue.main.async { available = names }
        }
    }
}

// MARK: - Macro steps

private struct MacroEditor: View {
    @Binding var steps: [MacroStep]
    let modeNames: [String]
    let targetBundleIDs: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach($steps) { $step in
                HStack(alignment: .top, spacing: 10) {
                    Text(String(format: "%02d", (steps.firstIndex(where: { $0.id == step.id }) ?? 0) + 1))
                        .font(.kkMono).foregroundStyle(Theme.ink2).frame(width: 20, alignment: .trailing)
                        .padding(.top, 6)
                    VStack(alignment: .leading, spacing: 10) {
                        ActionEditor(action: $step.action, modeNames: modeNames, targetBundleIDs: targetBundleIDs, allowMacro: false)
                        KKStepper("Wait \(step.delayMs) ms before this step", value: $step.delayMs, in: 0...5000, step: 50)
                            .foregroundStyle(Theme.ink2)
                    }
                    Spacer(minLength: 0)
                    Button {
                        steps.removeAll { $0.id == step.id }
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .medium))
                    }
                    .buttonStyle(.kkIcon)
                    .help("Remove this step")
                }
                .padding(10)
                .kkOutline(Theme.line)
            }
            Button {
                steps.append(MacroStep(.key(Key.space)))
            } label: {
                Label("Add step", systemImage: "plus")
            }
            .buttonStyle(KKButtonStyle(kind: .ghost))
        }
    }
}
