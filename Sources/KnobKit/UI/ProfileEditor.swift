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

// MARK: - What an unset gesture falls back to

/// What a gesture does when the mode being edited leaves it unset.
private struct Inherited {
    var name: String
    var from: String?

    var text: String { from.map { "\(name)  ·  from \($0)" } ?? name }

    static func lookup(_ gesture: KnobGesture, layer: ModifierSet, profile: Profile,
                       isAlways: Bool, isGlobal: Bool, state: AppState) -> Inherited {
        var chain: [(Mode, String)] = []
        if !isAlways { chain.append((profile.always, "Always")) }
        if !isGlobal, profile.inheritsGlobal {
            let global = state.config.global
            let index = min(state.modeIndex[global.id] ?? 0, max(global.modes.count - 1, 0))
            if global.modes.indices.contains(index) { chain.append((global.modes[index], "Global · \(global.modes[index].name)")) }
            chain.append((global.always, "Global · Always"))
        }
        for (mode, name) in chain {
            if let b = mode.binding(gesture, layer, speed: .any) { return Inherited(name: b.displayName, from: name) }
        }
        switch gesture {
        case .rotateCW, .rotateCCW: return Inherited(name: "System volume")
        case .press: return Inherited(name: "System mute")
        case .pressRotateCW, .pressRotateCCW: return Inherited(name: "Same as a plain turn")
        default: return Inherited(name: "Not set")
        }
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

    /// The mode being edited, or the always-on layer.
    private var currentMode: Mode {
        selectedMode.flatMap { id in profile.modes.first { $0.id == id } } ?? profile.always
    }

    private var isAlways: Bool { selectedMode == nil || !profile.modes.contains { $0.id == selectedMode } }

    /// The drawing's labels: what the knob does in this mode and layer, inherited
    /// bindings included.
    private var callouts: [Callout] {
        let mode = currentMode
        let prefix = layer.isEmpty ? "" : layer.symbols + " "
        func resolve(_ gesture: KnobGesture) -> (name: String, own: Bool) {
            if let b = mode.binding(gesture, layer, speed: .any) { return (b.displayName, true) }
            let fallback = Inherited.lookup(gesture, layer: layer, profile: profile, isAlways: isAlways,
                                            isGlobal: isGlobal, state: state)
            return (fallback.name, false)
        }
        let left = resolve(.rotateCCW), right = resolve(.rotateCW)
        var out = [Callout(label: prefix + "Turn",
                           value: left.name == right.name ? left.name : "\(left.name)  ↔  \(right.name)",
                           own: left.own || right.own)]
        for (gesture, name) in [(KnobGesture.press, "Press"), (.doublePress, "Double"), (.triplePress, "Triple")] {
            let r = resolve(gesture)
            out.append(Callout(label: prefix + name, value: r.name, own: r.own))
        }
        return out
    }

    private var remappedKeys: Set<Int> {
        Set((currentMode.keys + profile.always.keys).map { $0.key.keyCode })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                ProfileHeader(profile: $profile, isGlobal: isGlobal)
                KnobHero(callouts: callouts, highlighted: remappedKeys)
                    .padding(.vertical, 4)
                ModeBar(profile: $profile, selected: $selectedMode, isGlobal: isGlobal)
                if let id = selectedMode, let mode = modeBinding(id) {
                    ModeEditor(mode: mode, profile: $profile, isGlobal: isGlobal, isAlways: false, layer: $layer, selected: $selectedMode)
                } else {
                    ModeEditor(mode: $profile.always, profile: $profile, isGlobal: isGlobal, isAlways: true, layer: $layer, selected: $selectedMode)
                }
            }
            .padding(.horizontal, 30)
            .padding(.top, 38)
            .padding(.bottom, 30)
            .frame(maxWidth: 900, alignment: .leading)
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
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                if isGlobal {
                    Image(systemName: "globe").font(.system(size: 30, weight: .ultraLight))
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Global").font(.kkDisplay(23))
                        Text("Applies everywhere. App profiles layer on top of this.")
                            .foregroundStyle(Theme.ink2)
                    }
                } else {
                    AppIcon(bundleID: profile.bundleIDs.first, size: 34)
                    TextField("Profile name", text: $profile.name)
                        .textFieldStyle(.plain)
                        .font(.kkDisplay(23))
                    Spacer()
                    Toggle("Enabled", isOn: $profile.enabled).toggleStyle(KKSwitchStyle())
                    KKMenu(kind: .icon, small: true, items: {
                        [.action("Duplicate") {
                            var copy = profile
                            copy.id = UUID()
                            copy.name += " copy"
                            state.config.profiles.append(copy)
                            state.selection = .profile(copy.id)
                        },
                         .separator,
                         .action("Delete profile…", destructive: true) { confirmDelete = true }]
                    }) {
                        Image(systemName: "ellipsis").font(.system(size: 12, weight: .medium))
                    }
                    .help("More")
                }
            }
            if !isGlobal {
                Card(title: "Applies to") {
                    appsRow
                    Rule()
                    Toggle("Use Global for anything this profile does not set", isOn: $profile.inheritsGlobal)
                    HStack(spacing: 10) {
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
        VStack(alignment: .leading, spacing: 10) {
            FlowLayout(spacing: 6) {
                ForEach(profile.bundleIDs, id: \.self) { id in
                    HStack(spacing: 6) {
                        AppIcon(bundleID: id, size: 15)
                        Text(AppInfo.name(for: id)).font(.system(size: 12)).lineLimit(1)
                        Button {
                            profile.bundleIDs.removeAll { $0 == id }
                        } label: {
                            Image(systemName: "xmark").font(.system(size: 7.5, weight: .bold))
                                .frame(width: 14, height: 14).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.ink2)
                    }
                    .padding(.leading, 8).padding(.trailing, 4)
                    .frame(height: 26)
                    .kkOutline(Theme.lineStrong)
                    .help(id)
                }
                KKMenu("Add app", systemImage: "plus", kind: .ghost, small: true, items: {
                    var out: [KKMenuItem] = [.header("Running now")]
                    for app in AppChooser.running() where !profile.bundleIDs.contains(app.bundleID) {
                        out.append(.action(app.name) { profile.bundleIDs.append(app.bundleID) })
                    }
                    out.append(.separator)
                    out.append(.action("Choose application…") {
                        if let picked = AppChooser.pick(), !profile.bundleIDs.contains(picked.bundleID) {
                            profile.bundleIDs.append(picked.bundleID)
                        }
                    })
                    return out
                })
            }
            HStack(spacing: 8) {
                TextField("or a bundle id, * matches a prefix (com.adobe.PremierePro*)", text: $manualID)
                    .onSubmit(addManual)
                Button("Add", action: addManual).disabled(manualID.trimmingCharacters(in: .whitespaces).isEmpty)
            }
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Eyebrow("Modes", color: Theme.ink)
                Leader()
                Note("The knob cycles through these. “Always” applies in every mode.")
                    .lineLimit(1)
                    .layoutPriority(1)
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
                    Label("Add mode", systemImage: "plus")
                }
                .buttonStyle(KKButtonStyle(kind: .ghost))
            }
        }
    }

    private func chip(title: String, symbol: String, isSelected: Bool, isLive: Bool, action: @escaping () -> Void) -> some View {
        Chip(selected: isSelected, action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 11, weight: .light))
                Text(title)
                if isLive {
                    Rectangle().fill(isSelected ? Theme.bg : Theme.ink).frame(width: 5, height: 5)
                        .help("Active right now")
                }
            }
        }
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

    private func fallback(_ gesture: KnobGesture) -> String {
        Inherited.lookup(gesture, layer: layer, profile: profile, isAlways: isAlways, isGlobal: isGlobal, state: state).text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if isAlways {
                Note("Bindings here work in every mode of this profile. A mode's own binding for the same gesture wins.")
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

            Card(title: "Layer", accessory: usedLayers.count > 1 ? AnyView(layerJumps) : nil) {
                HStack(spacing: 12) {
                    ModifierToggles(modifiers: $layer)
                    Text(layer.isEmpty ? "The knob on its own" : "While holding \(layer.symbols) on the keyboard")
                        .foregroundStyle(Theme.ink2)
                    Spacer()
                }
            }

            section("Turn", gestures: [.rotateCW, .rotateCCW], presetTarget: false)
            section("Press", gestures: [.press, .doublePress, .triplePress], presetTarget: nil)
            section("Hold gestures", gestures: [.longPress, .pressRotateCW, .pressRotateCCW], presetTarget: true,
                    note: "Not available on the F75: it sends a knob press as an instant tap however long it is held, so it cannot signal a long press or a hold-and-turn. These only work with a controller that reports the knob being held down.")

            KeysEditor(mode: $mode, modeNames: modeNames, targetBundleIDs: isGlobal ? [] : profile.bundleIDs)
        }
    }

    /// Shortcuts to the layers that already have bindings.
    private var layerJumps: some View {
        HStack(spacing: 4) {
            ForEach(usedLayers, id: \.rawValue) { used in
                Button(used.isEmpty ? "none" : used.symbols) { layer = used }
                    .buttonStyle(KKButtonStyle(kind: used == layer ? .solid : .outline, small: true))
                    .help("Jump to a layer that has bindings")
            }
        }
    }

    /// `presetTarget`: false = presets apply to plain turns, true = to hold-and-turn, nil = no presets.
    private func section(_ title: String, gestures: [KnobGesture], presetTarget: Bool?, note: String? = nil) -> some View {
        Card(title: title, warning: note != nil, accessory: presetTarget.map { AnyView(presets(pressRotate: $0)) }) {
            if let note { Note(note) }
            ForEach(Array(gestures.enumerated()), id: \.element) { i, gesture in
                if i > 0 || note != nil { Rule() }
                GestureRow(mode: $mode, gesture: gesture, layer: layer, fallback: fallback(gesture),
                           modeNames: modeNames, targetBundleIDs: isGlobal ? [] : profile.bundleIDs)
            }
        }
    }

    private func presets(pressRotate: Bool) -> some View {
        KKMenu("Presets", small: true, items: {
            var out: [KKMenuItem] = []
            for group in Presets.turnGroups {
                out.append(.header(group.0))
                for preset in group.1 {
                    out.append(.action(preset.name) { apply(preset, pressRotate: pressRotate) })
                }
            }
            return out
        })
        .help("Sets both directions at once for this layer")
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
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: gesture.symbol).font(.system(size: 14, weight: .light))
                    .frame(width: 20).foregroundStyle(Theme.ink2)
                Text(layer.symbols.isEmpty ? gesture.title : "\(layer.symbols) \(gesture.title)")
                    .frame(width: 150, alignment: .leading)
                if let current {
                    Text(current.displayName).fontWeight(.semibold).lineLimit(1)
                    if current.label.isEmpty == false, current.label != current.action.summary {
                        Text(current.action.summary).foregroundStyle(Theme.ink2).lineLimit(1)
                    }
                    if fast != nil {
                        Eyebrow("+ fast").padding(.horizontal, 6).frame(height: 18).kkOutline(Theme.lineStrong)
                    }
                    Spacer()
                    Button {
                        expanded.toggle()
                    } label: {
                        Image(systemName: expanded ? "chevron.up" : "slider.horizontal.3")
                            .font(.system(size: 12, weight: .regular))
                    }
                    .buttonStyle(.kkIcon)
                    .help("Edit")
                    Button {
                        mode.knob.removeAll { $0.gesture == gesture && $0.modifiers == layer }
                        expanded = false
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .medium))
                    }
                    .buttonStyle(.kkIcon)
                    .help("Clear this binding")
                } else {
                    Text(fallback).foregroundStyle(Theme.ink3).lineLimit(1)
                    Spacer()
                    Button("Set") {
                        let starter: Action = gesture.isRotation
                            ? .key(gesture.direction > 0 ? Key.right : Key.left)
                            : .media(.playPause)
                        mode.knob.append(KnobBinding(gesture, layer, starter))
                        expanded = true
                    }
                    .buttonStyle(.kkSmall)
                }
            }
            .frame(minHeight: 24)
            if expanded, let current, let binding = $mode.knobBinding(current.id) {
                detail(binding)
                    .padding(.leading, 16)
                    .overlay(alignment: .leading) { VRule(color: Theme.lineStrong) }
                    .padding(.leading, 32)
                    .padding(.bottom, 4)
            }
        }
    }

    @ViewBuilder private func detail(_ binding: Binding<KnobBinding>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ActionEditor(action: binding.action, direction: gesture.direction, modeNames: modeNames, targetBundleIDs: targetBundleIDs)
            HStack(spacing: 10) {
                Text("Label").foregroundStyle(Theme.ink2)
                TextField("optional name for the menu and HUD", text: binding.label).frame(maxWidth: 280)
            }
            if gesture.isRotation {
                HStack(spacing: 20) {
                    Toggle("Speed up when spun fast", isOn: binding.accelerate)
                        .help("Scales volume steps, scroll distance and key repeats with turning speed")
                    KKStepper("Fire every \(binding.wrappedValue.everyNTicks == 1 ? "detent" : "\(binding.wrappedValue.everyNTicks) detents")",
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
                    Card(title: "When spun fast") {
                        ActionEditor(action: fastBinding.action, direction: gesture.direction, modeNames: modeNames, targetBundleIDs: targetBundleIDs)
                        HStack(spacing: 10) {
                            Text("Label").foregroundStyle(Theme.ink2)
                            TextField("optional", text: fastBinding.label).frame(maxWidth: 280)
                        }
                    }
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
        Card(title: "Keys", accessory: AnyView(
            Button {
                mode.keys.append(KeyBinding(KeyCombo(Key.f13), .media(.playPause)))
            } label: {
                Label("Add key", systemImage: "plus")
            }
            .buttonStyle(.kkSmall)
        )) {
            Note(mode.keys.isEmpty
                ? "Remap a key or shortcut to any action while this mode is active. No key remaps yet. They apply to every keyboard, not only the F75."
                : "Remap a key or shortcut to any action while this mode is active. Remapped keys are filled in on the drawing above.")
            ForEach(mode.keys) { item in
                if let binding = $mode.keyBinding(item.id) {
                    Rule()
                    HStack(alignment: .top, spacing: 14) {
                        VStack(alignment: .leading, spacing: 10) {
                            KeyComboEditor(combo: binding.key)
                            Toggle("Repeat while held", isOn: binding.repeats)
                        }
                        Image(systemName: "arrow.right").font(.system(size: 12, weight: .light))
                            .foregroundStyle(Theme.ink2).padding(.top, 6)
                        ActionEditor(action: binding.action, modeNames: modeNames, targetBundleIDs: targetBundleIDs)
                        Spacer(minLength: 0)
                        Button {
                            mode.keys.removeAll { $0.id == item.id }
                        } label: {
                            Image(systemName: "xmark").font(.system(size: 10, weight: .medium))
                        }
                        .buttonStyle(.kkIcon)
                        .help("Remove this key")
                    }
                }
            }
        }
    }
}
