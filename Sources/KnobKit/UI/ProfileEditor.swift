import AppKit
import KnobCore
import SwiftUI

// MARK: - Safe element bindings

extension Binding where Value == Mode {
    /// Binding to one knob binding by id. Survives the binding being deleted while a row
    /// is still on screen (index-based bindings would crash).
    func knobBinding(_ id: UUID) -> Binding<KnobBinding>? {
        guard let snapshot = wrappedValue.knob.first(where: { $0.id == id }) else { return nil }
        return Binding<KnobBinding>(
            get: { self.wrappedValue.knob.first(where: { $0.id == id }) ?? snapshot },
            set: { value in
                if let i = self.wrappedValue.knob.firstIndex(where: { $0.id == id }) { self.wrappedValue.knob[i] = value }
            })
    }

    func keyBinding(_ id: UUID) -> Binding<KeyBinding>? {
        guard let snapshot = wrappedValue.keys.first(where: { $0.id == id }) else { return nil }
        return Binding<KeyBinding>(
            get: { self.wrappedValue.keys.first(where: { $0.id == id }) ?? snapshot },
            set: { value in
                if let i = self.wrappedValue.keys.firstIndex(where: { $0.id == id }) { self.wrappedValue.keys[i] = value }
            })
    }
}

// MARK: - Profile editor

struct ProfileEditor: View {
    @Binding var profile: Profile
    let isGlobal: Bool
    @EnvironmentObject private var state: AppState
    /// nil selects the always-on layer.
    @State private var selectedMode: UUID?
    @State private var layer: ModifierSet = []

    private func modeBinding(_ id: UUID) -> Binding<Mode>? {
        guard let snapshot = profile.modes.first(where: { $0.id == id }) else { return nil }
        return Binding<Mode>(
            get: { profile.modes.first(where: { $0.id == id }) ?? snapshot },
            set: { value in
                if let i = profile.modes.firstIndex(where: { $0.id == id }) { profile.modes[i] = value }
            })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ProfileHeader(profile: $profile, isGlobal: isGlobal)
                ModeBar(profile: $profile, selected: $selectedMode, isGlobal: isGlobal)
                if let id = selectedMode, let mode = modeBinding(id) {
                    ModeEditor(mode: mode, profile: $profile, isGlobal: isGlobal, isAlways: false, layer: $layer, selected: $selectedMode)
                } else {
                    ModeEditor(mode: $profile.always, profile: $profile, isGlobal: isGlobal, isAlways: true, layer: $layer, selected: $selectedMode)
                }
            }
            .padding(20)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            // Open on the mode that is live right now, or the first one.
            if selectedMode == nil, !profile.modes.isEmpty {
                let live = state.modeIndex[profile.id] ?? 0
                selectedMode = profile.modes[min(live, profile.modes.count - 1)].id
            }
        }
    }
}

// MARK: - Header

private struct ProfileHeader: View {
    @Binding var profile: Profile
    let isGlobal: Bool
    @EnvironmentObject private var state: AppState
    @State private var manualID = ""
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                if isGlobal {
                    Image(systemName: "globe").font(.system(size: 26)).foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Global").font(.title2.bold())
                        Text("Applies everywhere. App profiles layer on top of this.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                } else {
                    AppIcon(bundleID: profile.bundleIDs.first, size: 34)
                    TextField("Profile name", text: $profile.name)
                        .textFieldStyle(.plain)
                        .font(.title2.bold())
                    Spacer()
                    Toggle("Enabled", isOn: $profile.enabled).toggleStyle(.switch).controlSize(.small)
                    Menu {
                        Button("Duplicate") {
                            var copy = profile
                            copy.id = UUID()
                            copy.name += " copy"
                            state.config.profiles.append(copy)
                            state.selection = .profile(copy.id)
                        }
                        Button("Delete profile…", role: .destructive) { confirmDelete = true }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
            if !isGlobal {
                Card {
                    appsRow
                    Divider()
                    Toggle("Use Global for anything this profile does not set", isOn: $profile.inheritsGlobal)
                    HStack {
                        Text("Only when the window title contains")
                        TextField("optional, e.g. Color", text: $profile.titleContains).frame(maxWidth: 220)
                    }
                    .help("Lets one app have several profiles, picked by the front window's title.")
                }
            }
        }
        .confirmationDialog("Delete the “\(profile.name)” profile?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { state.deleteProfile(profile.id) }
        }
    }

    private var appsRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Applies to").font(.subheadline).foregroundStyle(.secondary)
            FlowLayout(spacing: 6) {
                ForEach(profile.bundleIDs, id: \.self) { id in
                    HStack(spacing: 5) {
                        AppIcon(bundleID: id, size: 16)
                        Text(AppInfo.name(for: id)).lineLimit(1)
                        Button {
                            profile.bundleIDs.removeAll { $0 == id }
                        } label: {
                            Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
                    .help(id)
                }
                Menu {
                    Section("Running now") {
                        ForEach(AppChooser.running().filter { !profile.bundleIDs.contains($0.bundleID) }, id: \.bundleID) { app in
                            Button(app.name) { profile.bundleIDs.append(app.bundleID) }
                        }
                    }
                    Button("Choose application…") {
                        if let picked = AppChooser.pick(), !profile.bundleIDs.contains(picked.bundleID) {
                            profile.bundleIDs.append(picked.bundleID)
                        }
                    }
                } label: {
                    Label("Add app", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            HStack {
                TextField("or a bundle id, * matches a prefix (com.adobe.PremierePro*)", text: $manualID)
                    .onSubmit(addManual)
                Button("Add", action: addManual).disabled(manualID.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .font(.callout)
        }
    }

    private func addManual() {
        let id = manualID.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty, !profile.bundleIDs.contains(id) else { return }
        profile.bundleIDs.append(id)
        manualID = ""
    }
}

/// Wrapping row layout for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for (i, origin) in result.origins.enumerated() {
            subviews[i].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (CGSize(width: maxX, height: y + rowHeight), origins)
    }
}

// MARK: - Mode bar

private struct ModeBar: View {
    @Binding var profile: Profile
    @Binding var selected: UUID?
    let isGlobal: Bool
    @EnvironmentObject private var state: AppState

    private var liveIndex: Int { state.modeIndex[profile.id] ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Modes").font(.headline)
                Text("The knob cycles through these. “Always” applies in every mode.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            FlowLayout(spacing: 6) {
                chip(title: "Always", symbol: "infinity", isSelected: selected == nil, isLive: false) { selected = nil }
                ForEach(Array(profile.modes.enumerated()), id: \.element.id) { index, mode in
                    chip(title: mode.name, symbol: mode.symbol, isSelected: selected == mode.id, isLive: index == liveIndex) {
                        selected = mode.id
                    }
                    .contextMenu {
                        Button("Make this the active mode") { state.setMode(profileID: profile.id, index: index) }
                        Button("Move left") { move(index, by: -1) }.disabled(index == 0)
                        Button("Move right") { move(index, by: 1) }.disabled(index == profile.modes.count - 1)
                        Button("Duplicate") { duplicate(index) }
                        Button("Delete", role: .destructive) { delete(index) }
                            .disabled(isGlobal && profile.modes.count <= 1)
                    }
                }
                Button {
                    let mode = Mode("Mode \(profile.modes.count + 1)")
                    profile.modes.append(mode)
                    selected = mode.id
                } label: {
                    Label("Add mode", systemImage: "plus").padding(.horizontal, 6).padding(.vertical, 3)
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private func chip(title: String, symbol: String, isSelected: Bool, isLive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 12))
                Text(title)
                if isLive {
                    Circle().fill(Color.green).frame(width: 6, height: 6).help("Active right now")
                }
            }
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(Capsule().fill(isSelected ? Color.accentColor : Color.primary.opacity(0.07)))
            .foregroundStyle(isSelected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }

    private func move(_ index: Int, by delta: Int) {
        let target = index + delta
        guard profile.modes.indices.contains(target) else { return }
        profile.modes.swapAt(index, target)
    }

    private func duplicate(_ index: Int) {
        var copy = profile.modes[index]
        copy.id = UUID()
        copy.name += " copy"
        copy.knob = copy.knob.map { var b = $0; b.id = UUID(); return b }
        copy.keys = copy.keys.map { var k = $0; k.id = UUID(); return k }
        profile.modes.insert(copy, at: index + 1)
        selected = copy.id
    }

    private func delete(_ index: Int) {
        let id = profile.modes[index].id
        profile.modes.remove(at: index)
        if selected == id { selected = profile.modes.first?.id }
    }
}

// MARK: - Mode editor

private struct ModeEditor: View {
    @Binding var mode: Mode
    @Binding var profile: Profile
    let isGlobal: Bool
    let isAlways: Bool
    @Binding var layer: ModifierSet
    @Binding var selected: UUID?
    @EnvironmentObject private var state: AppState

    private var modeNames: [String] {
        var names = profile.modes.map(\.name)
        if !isGlobal { names += state.config.global.modes.map(\.name).filter { !names.contains($0) } }
        return names
    }

    /// Modifier layers that already have bindings in this mode.
    private var usedLayers: [ModifierSet] {
        Array(Set(mode.knob.map(\.modifiers))).sorted { $0.rawValue < $1.rawValue }
    }

    /// What happens for a gesture this mode leaves unset.
    private func fallback(_ gesture: KnobGesture) -> String {
        var chain: [(Mode, String)] = []
        if !isAlways { chain.append((profile.always, "Always")) }
        if !isGlobal, profile.inheritsGlobal {
            let global = state.config.global
            let index = min(state.modeIndex[global.id] ?? 0, max(global.modes.count - 1, 0))
            if global.modes.indices.contains(index) { chain.append((global.modes[index], "Global · \(global.modes[index].name)")) }
            chain.append((global.always, "Global · Always"))
        }
        for (m, name) in chain {
            if let b = m.binding(gesture, layer, speed: .any) { return "\(b.displayName)  ·  from \(name)" }
        }
        switch gesture {
        case .rotateCW, .rotateCCW: return "System volume"
        case .press: return "System mute"
        case .pressRotateCW, .pressRotateCCW: return "Same as a plain turn"
        default: return "Not set"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if isAlways {
                Text("Bindings here work in every mode of this profile. A mode's own binding for the same gesture wins.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    SymbolPicker(symbol: $mode.symbol)
                    TextField("Mode name", text: $mode.name).frame(maxWidth: 240)
                    Spacer()
                    if let index = profile.modes.firstIndex(where: { $0.id == mode.id }) {
                        Button("Make active") { state.setMode(profileID: profile.id, index: index) }
                            .disabled((state.modeIndex[profile.id] ?? 0) == index)
                    }
                }
            }

            Card {
                HStack(spacing: 10) {
                    Text("Layer").font(.headline)
                    ModifierToggles(modifiers: $layer)
                    Text(layer.isEmpty ? "knob on its own" : "while holding \(layer.symbols) on the keyboard")
                        .foregroundStyle(.secondary)
                    Spacer()
                    ForEach(usedLayers, id: \.rawValue) { used in
                        Button(used.isEmpty ? "none" : used.symbols) { layer = used }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .tint(used == layer ? .accentColor : nil)
                            .help("Jump to a layer that has bindings")
                    }
                }
            }

            section("Turn", presetTarget: false, gestures: [.rotateCW, .rotateCCW])
            section("Press", presetTarget: nil, gestures: [.press, .doublePress, .triplePress])
            section("Hold gestures", presetTarget: true, gestures: [.longPress, .pressRotateCW, .pressRotateCCW],
                    note: "Not available on the F75: it sends a knob press as an instant tap however long it is held, so it cannot signal a long press or a hold-and-turn. These only work with a controller that reports the knob being held down.")

            KeysEditor(mode: $mode, modeNames: modeNames, targetBundleIDs: isGlobal ? [] : profile.bundleIDs)
        }
    }

    /// `presetTarget`: false = presets apply to plain turns, true = to hold-and-turn, nil = no presets.
    private func section(_ title: String, presetTarget: Bool?, gestures: [KnobGesture], note: String? = nil) -> some View {
        Card {
            HStack {
                Text(title).font(.headline)
                if note != nil {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                Spacer()
                if let pressRotate = presetTarget {
                    Menu("Presets") {
                        ForEach(Presets.turnGroups, id: \.0) { group in
                            Section(group.0) {
                                ForEach(group.1) { preset in
                                    Button(preset.name) { apply(preset, pressRotate: pressRotate) }
                                }
                            }
                        }
                    }
                    .fixedSize()
                    .help("Sets both directions at once for this layer")
                }
            }
            if let note {
                Text(note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(gestures.enumerated()), id: \.element) { i, gesture in
                if i > 0 { Divider() }
                GestureRow(mode: $mode, gesture: gesture, layer: layer, fallback: fallback(gesture),
                           modeNames: modeNames, targetBundleIDs: isGlobal ? [] : profile.bundleIDs)
            }
        }
    }

    private func apply(_ preset: TurnPreset, pressRotate: Bool) {
        let targets: Set<KnobGesture> = pressRotate ? [.pressRotateCW, .pressRotateCCW] : [.rotateCW, .rotateCCW]
        mode.knob.removeAll { targets.contains($0.gesture) && $0.modifiers == layer }
        mode.knob.append(contentsOf: preset.bindings(pressRotate: pressRotate, modifiers: layer))
    }
}

// MARK: - One gesture row

private struct GestureRow: View {
    @Binding var mode: Mode
    let gesture: KnobGesture
    let layer: ModifierSet
    let fallback: String
    let modeNames: [String]
    let targetBundleIDs: [String]
    @State private var expanded = false

    private var current: KnobBinding? {
        mode.knob.first { $0.gesture == gesture && $0.modifiers == layer && $0.speed == .any }
    }

    private var fast: KnobBinding? {
        mode.knob.first { $0.gesture == gesture && $0.modifiers == layer && $0.speed == .fast }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: gesture.symbol).frame(width: 22).foregroundStyle(.tint)
                Text(layer.symbols.isEmpty ? gesture.title : "\(layer.symbols) \(gesture.title)")
                    .frame(width: 170, alignment: .leading)
                if let current {
                    Text(current.displayName).fontWeight(.medium).lineLimit(1)
                    if current.label.isEmpty == false, current.label != current.action.summary {
                        Text(current.action.summary).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if fast != nil {
                        Text("+ fast").font(.caption).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.orange.opacity(0.2)))
                    }
                    Spacer()
                    Button {
                        expanded.toggle()
                    } label: {
                        Image(systemName: expanded ? "chevron.up" : "slider.horizontal.3")
                    }
                    .buttonStyle(.borderless)
                    .help("Edit")
                    Button {
                        mode.knob.removeAll { $0.gesture == gesture && $0.modifiers == layer }
                        expanded = false
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Clear this binding")
                } else {
                    Text(fallback).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Button("Set") {
                        let starter: Action = gesture.isRotation
                            ? .key(gesture.direction > 0 ? Key.right : Key.left)
                            : .media(.playPause)
                        mode.knob.append(KnobBinding(gesture, layer, starter))
                        expanded = true
                    }
                    .controlSize(.small)
                }
            }
            if expanded, let current, let binding = $mode.knobBinding(current.id) {
                detail(binding)
                    .padding(.leading, 32)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private func detail(_ binding: Binding<KnobBinding>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ActionEditor(action: binding.action, direction: gesture.direction, modeNames: modeNames, targetBundleIDs: targetBundleIDs)
            HStack {
                Text("Label")
                TextField("optional name for the menu and HUD", text: binding.label).frame(maxWidth: 280)
            }
            if gesture.isRotation {
                HStack(spacing: 16) {
                    Toggle("Speed up when spun fast", isOn: binding.accelerate)
                        .help("Scales volume steps, scroll distance and key repeats with turning speed")
                    Stepper("Fire every \(binding.wrappedValue.everyNTicks == 1 ? "detent" : "\(binding.wrappedValue.everyNTicks) detents")",
                            value: binding.everyNTicks, in: 1...12)
                        .help("Higher values make coarse actions like tab switching less twitchy")
                }
                Toggle("Do something different when spun fast", isOn: Binding(
                    get: { fast != nil },
                    set: { on in
                        mode.knob.removeAll { $0.gesture == gesture && $0.modifiers == layer && $0.speed == .fast }
                        if on {
                            var copy = binding.wrappedValue
                            copy.id = UUID()
                            copy.speed = .fast
                            copy.label = ""
                            mode.knob.append(copy)
                        }
                    }))
                if let fast, let fastBinding = $mode.knobBinding(fast.id) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("When spun fast").font(.subheadline.weight(.semibold))
                        ActionEditor(action: fastBinding.action, direction: gesture.direction, modeNames: modeNames, targetBundleIDs: targetBundleIDs)
                        HStack {
                            Text("Label")
                            TextField("optional", text: fastBinding.label).frame(maxWidth: 280)
                        }
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.08)))
                }
            }
        }
    }
}

// MARK: - Key remaps

private struct KeysEditor: View {
    @Binding var mode: Mode
    let modeNames: [String]
    let targetBundleIDs: [String]

    var body: some View {
        Card {
            HStack {
                Text("Keys").font(.headline)
                Text("Remap a key or shortcut to any action while this mode is active.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button {
                    mode.keys.append(KeyBinding(KeyCombo(Key.f13), .media(.playPause)))
                } label: {
                    Label("Add key", systemImage: "plus")
                }
                .controlSize(.small)
            }
            if mode.keys.isEmpty {
                Text("No key remaps. These apply to every keyboard, not only the F75.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(mode.keys) { item in
                if let binding = $mode.keyBinding(item.id) {
                    Divider()
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            KeyComboEditor(combo: binding.key)
                            Toggle("Repeat while held", isOn: binding.repeats).font(.callout)
                        }
                        Image(systemName: "arrow.right").foregroundStyle(.secondary).padding(.top, 4)
                        ActionEditor(action: binding.action, modeNames: modeNames, targetBundleIDs: targetBundleIDs)
                        Spacer(minLength: 0)
                        Button {
                            mode.keys.removeAll { $0.id == item.id }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
    }
}
