import AppKit
import KnobCore
import SwiftUI

/// The menu bar popover: what the knob does right now, mode switching, and shortcuts
/// into the configurator.
struct PopoverView: View {
    @EnvironmentObject private var state: AppState
    var openConfigurator: (SidebarItem?) -> Void
    var quit: () -> Void

    private var needsPermissions: Bool {
        !state.axTrusted || (state.config.settings.deviceMode == .selected && !state.hidListening)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if needsPermissions {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Finish setup").font(.subheadline.weight(.semibold))
                    PermissionsCard(compact: true)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
            }
            contextRow
            modeChips
            Divider()
            cheatSheet
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 340)
    }

    private var header: some View {
        HStack {
            Image(nsImage: KnobIcon.image(modeIndex: state.context.modeOwnerIndex,
                                          modeCount: state.context.modeOwner.modes.count, pointSize: 22))
                .renderingMode(.template)
                .foregroundStyle(.tint)
            Text("KnobKit").font(.headline)
            Spacer()
            Toggle("", isOn: $state.config.settings.enabled)
                .toggleStyle(.switch).controlSize(.small).labelsHidden()
                .help("Turn knob remapping on or off")
        }
    }

    private var contextRow: some View {
        HStack(spacing: 8) {
            AppIcon(bundleID: state.frontApp.bundleID, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(state.frontApp.name.isEmpty ? "No app" : state.frontApp.name).fontWeight(.medium).lineLimit(1)
                Text(state.context.app.map { "Profile: \($0.name)" } ?? "Global profile")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let profile = state.context.app {
                Button("Edit") { openConfigurator(.profile(profile.id)) }.controlSize(.small)
            } else if let id = state.frontApp.bundleID {
                Button("Add profile") {
                    let new = state.addProfile(name: state.frontApp.name, bundleIDs: [id])
                    openConfigurator(.profile(new))
                }
                .controlSize(.small)
            }
        }
    }

    private var modeChips: some View {
        let owner = state.context.modeOwner
        let live = state.context.modeOwnerIndex
        return FlowLayout(spacing: 5) {
            ForEach(Array(owner.modes.enumerated()), id: \.element.id) { index, mode in
                Button {
                    state.setMode(profileID: owner.id, index: index)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: mode.symbol).font(.system(size: 11))
                        Text(mode.name).font(.callout)
                    }
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(Capsule().fill(index == live ? Color.accentColor : Color.primary.opacity(0.08)))
                    .foregroundStyle(index == live ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private struct CheatRow: Identifiable {
        var id: String
        var modifiers: ModifierSet
        var gesture: String
        var text: String
        var fromApp: Bool
    }

    /// One line per control: a left/right pair collapses into a single "Turn" row.
    private var cheatRows: [CheatRow] {
        let all = state.context.cheatSheet().filter { $0.binding.speed != .fast }
        var rows: [CheatRow] = []
        var layers: [ModifierSet] = []
        for r in all where !layers.contains(r.binding.modifiers) { layers.append(r.binding.modifiers) }
        for mods in layers {
            let inLayer = all.filter { $0.binding.modifiers == mods }
            func find(_ g: KnobGesture) -> ResolvedBinding? { inLayer.first { $0.binding.gesture == g } }
            func pair(_ ccw: KnobGesture, _ cw: KnobGesture, _ name: String) {
                let left = find(ccw), right = find(cw)
                guard left != nil || right != nil else { return }
                let l = left?.binding.displayName, r = right?.binding.displayName
                let text = l == r ? (l ?? "") : [l, r].compactMap { $0 }.joined(separator: "  ↔  ")
                rows.append(CheatRow(id: "\(mods.rawValue)-\(name)", modifiers: mods, gesture: name, text: text,
                                     fromApp: (left ?? right)!.source.isApp))
            }
            func single(_ g: KnobGesture, _ name: String) {
                guard let r = find(g) else { return }
                rows.append(CheatRow(id: "\(mods.rawValue)-\(name)", modifiers: mods, gesture: name,
                                     text: r.binding.displayName, fromApp: r.source.isApp))
            }
            pair(.rotateCCW, .rotateCW, "Turn")
            single(.press, "Press")
            single(.doublePress, "Double press")
            single(.triplePress, "Triple press")
            single(.longPress, "Long press")
            pair(.pressRotateCCW, .pressRotateCW, "Hold + turn")
        }
        return rows
    }

    private var cheatSheet: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(cheatRows) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(row.modifiers.symbols)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .frame(width: 30, alignment: .trailing)
                        Text(row.gesture)
                            .foregroundStyle(.secondary)
                            .frame(width: 82, alignment: .leading)
                        Text(row.text).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 0)
                        if row.fromApp {
                            Circle().fill(Color.accentColor).frame(width: 5, height: 5)
                                .help("Set by this app's profile")
                        }
                    }
                    .font(.callout)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 250)
    }

    private var footer: some View {
        HStack {
            Button("Configure…") { openConfigurator(nil) }
            Button("Monitor") { openConfigurator(.monitor) }
            Spacer()
            Button("Quit", action: quit)
        }
        .controlSize(.small)
    }
}
