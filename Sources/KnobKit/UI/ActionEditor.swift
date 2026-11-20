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
        VStack(alignment: .leading, spacing: 8) {
            Picker("Action", selection: kind) {
                ForEach(Self.groups, id: \.0) { group in
                    Section(group.0) {
                        ForEach(group.1.filter { allowMacro || $0 != .macro }, id: \.self) { k in
                            Text(k.title).tag(k)
                        }
                    }
                }
            }
            .labelsHidden()
            .fixedSize()
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
            HStack {
                Text("Step")
                TextField("", value: $action.amount, format: .number.precision(.fractionLength(0...1)))
                    .frame(width: 60)
                    .multilineTextAlignment(.trailing)
                Stepper("", value: $action.amount, in: -25...25, step: 0.5).labelsHidden()
                Text("% of full volume per detent").foregroundStyle(.secondary)
            }
        case .muteToggle, .modeNext, .modePrevious:
            EmptyView()
        case .monitorLevel:
            HStack {
                Text("Step")
                TextField("", value: $action.amount, format: .number.precision(.fractionLength(0...1)))
                    .frame(width: 60)
                    .multilineTextAlignment(.trailing)
                Stepper("", value: $action.amount, in: -12...12, step: 0.5).labelsHidden()
                Text("dB per detent (0.5 dB resolution)").foregroundStyle(.secondary)
            }
            Toggle("Use the Mac's own volume when the current output has one", isOn: $action.auto)
            hint("Sets the monitor level of a Universal Audio Apollo through the UA mixer on this Mac. It never raises the level above the ceiling set under General.")
        case .monitorToggle:
            HStack {
                Picker("Switch", selection: $action.monitorSwitch) {
                    ForEach(MonitorSwitch.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
                if action.monitorSwitch == .mute {
                    Toggle("Use the Mac's own mute when the current output has one", isOn: $action.auto)
                }
            }
            hint("Toggles mute, dim or mono on the Apollo's monitor output.")
        case .mediaKey:
            HStack {
                Picker("Key", selection: $action.mediaKey) {
                    ForEach(MediaKey.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                Toggle("Fine (quarter step)", isOn: $action.fine)
                Stepper("×\(action.count)", value: $action.count, in: 1...10)
            }
        case .keystroke:
            HStack {
                KeyComboEditor(combo: $action.key)
                Stepper("×\(action.count)", value: $action.count, in: 1...20)
            }
        case .stickyKeystroke:
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Keep held")
                    ModifierToggles(modifiers: $action.hold)
                    Text("then tap").foregroundStyle(.secondary)
                }
                KeyComboEditor(combo: $action.key)
                HStack {
                    Text("Release after")
                    Slider(value: $action.releaseAfter, in: 0.2...3, step: 0.1).frame(width: 160)
                    Text(String(format: "%.1f s of no turning", action.releaseAfter)).foregroundStyle(.secondary)
                }
                hint("For switchers that commit when the modifier is released, such as ⌘⇥ or ⌃⇥.")
            }
        case .typeText:
            TextField("Text to type", text: $action.text)
        case .scroll:
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Down")
                    TextField("", value: $action.dy, format: .number.precision(.fractionLength(0)))
                        .frame(width: 56).multilineTextAlignment(.trailing)
                    Stepper("", value: $action.dy, in: -2000...2000, step: 10).labelsHidden()
                    Text("Right").padding(.leading, 8)
                    TextField("", value: $action.dx, format: .number.precision(.fractionLength(0)))
                        .frame(width: 56).multilineTextAlignment(.trailing)
                    Stepper("", value: $action.dx, in: -2000...2000, step: 10).labelsHidden()
                    Picker("", selection: $action.unit) {
                        Text("pixels").tag(ScrollUnit.pixel)
                        Text("lines").tag(ScrollUnit.line)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                HStack {
                    Toggle("Smooth", isOn: $action.smooth).disabled(action.unit == .line)
                    Text("With").padding(.leading, 8)
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
            HStack {
                TextField("URL, file path or bundle id", text: $action.text)
                Button("Choose app…") {
                    if let picked = AppChooser.pick() { action.text = picked.bundleID }
                }
            }
        case .modeSet:
            if modeNames.isEmpty {
                TextField("Mode name", text: $action.text)
            } else {
                Picker("Mode", selection: $action.text) {
                    ForEach(modeNames, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
        case .macro:
            MacroEditor(steps: $action.steps, modeNames: modeNames, targetBundleIDs: targetBundleIDs)
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
                .frame(minHeight: 54, maxHeight: 120)
                .scrollContentBackground(.hidden)
                .padding(4)
            if text.isEmpty {
                Text(placeholder)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .allowsHitTesting(false)
            }
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
    }
}

// MARK: - Menu item picker

private struct MenuNodeView: View {
    let node: AX.MenuNode
    let path: [String]
    let pick: ([String]) -> Void

    var body: some View {
        if node.children.isEmpty {
            Button(node.title) { pick(path + [node.title]) }
        } else {
            Menu(node.title) {
                ForEach(node.children) { child in
                    MenuNodeView(node: child, path: path + [node.title], pick: pick)
                }
            }
        }
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
            HStack {
                TextField("View > Zoom In", text: $text)
                if tree.isEmpty {
                    Button(loading ? "Reading…" : "Read menus") { load() }.disabled(loading)
                } else {
                    Menu("Pick") {
                        ForEach(tree) { node in
                            MenuNodeView(node: node, path: []) { text = $0.joined(separator: " > ") }
                        }
                    }
                    .fixedSize()
                }
            }
            Text(status.isEmpty ? "Clicks a menu bar item by name, even ones without a shortcut. Separate levels with >." : status)
                .font(.caption).foregroundStyle(.secondary)
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
        HStack {
            TextField("Shortcut name", text: $name)
            Menu("Pick") {
                if available.isEmpty { Text("No shortcuts found") }
                ForEach(available, id: \.self) { s in Button(s) { name = s } }
            }
            .fixedSize()
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
                HStack(alignment: .top, spacing: 8) {
                    Text("\((steps.firstIndex(where: { $0.id == step.id }) ?? 0) + 1).")
                        .monospacedDigit().foregroundStyle(.secondary).frame(width: 18, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 6) {
                        ActionEditor(action: $step.action, modeNames: modeNames, targetBundleIDs: targetBundleIDs, allowMacro: false)
                        Stepper("Wait \(step.delayMs) ms before this step", value: $step.delayMs, in: 0...5000, step: 50)
                            .font(.caption)
                    }
                    Spacer(minLength: 0)
                    Button {
                        steps.removeAll { $0.id == step.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
            }
            Button {
                steps.append(MacroStep(.key(Key.space)))
            } label: {
                Label("Add step", systemImage: "plus")
            }
            .buttonStyle(.borderless)
        }
    }
}
