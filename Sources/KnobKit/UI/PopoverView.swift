import AppKit
import KnobCore
import SwiftUI

/// The menu bar panel: what the knob does right now, mode switching, and shortcuts
/// into the configurator.
struct PopoverView: View {
    @EnvironmentObject private var state: AppState
    var openConfigurator: (SidebarItem?) -> Void
    var quit: () -> Void

    private var needsPermissions: Bool {
        !state.axTrusted || (state.config.settings.deviceMode == .selected && !state.hidListening)
    }

    private var enabled: Bool { state.config.settings.enabled }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 12)
            Rule()
            if needsPermissions {
                VStack(alignment: .leading, spacing: 10) {
                    Eyebrow("Finish setup", color: Theme.warn)
                    PermissionsCard(compact: true)
                }
                .padding(16)
                Rule()
            }
            Group {
                dial
                    .padding(.horizontal, 16).padding(.vertical, 14)
                Rule()
                modeChips
                    .padding(.horizontal, 16).padding(.vertical, 12)
                Rule()
                cheatSheet
            }
            .opacity(enabled ? 1 : 0.35)
            Rule()
            footer
                .padding(.horizontal, 12).padding(.vertical, 10)
        }
        .frame(width: 340)
        .background(Theme.bg)
        .kkRoot()
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("KNOBKIT").font(.kkDisplay(13)).tracking(1.6)
            Eyebrow("F75", color: Theme.ink3)
            Spacer()
            Toggle(isOn: $state.config.settings.enabled) {
                Eyebrow(enabled ? "On" : "Off")
            }
            .toggleStyle(KKSwitchStyle())
            .help("Turn knob remapping on or off")
        }
    }

    // MARK: Dial and context

    private var dial: some View {
        let owner = state.context.modeOwner
        let index = state.context.modeOwnerIndex
        let count = owner.modes.count
        let mode = state.context.displayMode
        return HStack(alignment: .center, spacing: 14) {
            DialView(position: DialView.position(index: index, count: count),
                     majorTicks: count, activeTick: index, size: 86)
                .contentShape(Circle())
                .onTapGesture {
                    guard count > 1 else { return }
                    state.setMode(profileID: owner.id, index: (index + 1) % count)
                }
                .help("Click for the next mode")
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Eyebrow("Mode")
                    Leader()
                    Text(String(format: "%02d / %02d", min(index + 1, max(count, 1)), max(count, 1)))
                        .font(.kkMono).foregroundStyle(Theme.ink2)
                }
                Text((mode?.name ?? "No mode").uppercased())
                    .font(.kkDisplay(21))
                    .tracking(0.4)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Rule()
                contextRow
            }
        }
    }

    private var contextRow: some View {
        HStack(spacing: 8) {
            AppIcon(bundleID: state.frontApp.bundleID, size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(state.frontApp.name.isEmpty ? "No app" : state.frontApp.name)
                    .font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                Text(state.context.app.map { "Profile: \($0.name)" } ?? "Global profile")
                    .font(.system(size: 11)).foregroundStyle(Theme.ink2).lineLimit(1)
            }
            Spacer(minLength: 4)
            if let profile = state.context.app {
                Button("Edit") { openConfigurator(.profile(profile.id)) }.buttonStyle(.kkSmall).fixedSize()
            } else if let id = state.frontApp.bundleID {
                Button("Add profile") {
                    let new = state.addProfile(name: state.frontApp.name, bundleIDs: [id])
                    openConfigurator(.profile(new))
                }
                .buttonStyle(.kkSmall)
                .fixedSize()
            }
        }
    }

    private var modeChips: some View {
        let owner = state.context.modeOwner
        let live = state.context.modeOwnerIndex
        return FlowLayout(spacing: 6) {
            ForEach(Array(owner.modes.enumerated()), id: \.element.id) { index, mode in
                Chip(selected: index == live) {
                    state.setMode(profileID: owner.id, index: index)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: mode.symbol).font(.system(size: 10.5, weight: .light))
                        Text(mode.name)
                    }
                }
            }
        }
    }

    // MARK: What the knob does

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
            single(.doublePress, "Double")
            single(.triplePress, "Triple")
            single(.longPress, "Long press")
            pair(.pressRotateCCW, .pressRotateCW, "Hold + turn")
        }
        return rows
    }

    private var cheatSheet: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(cheatRows) { row in
                    HStack(alignment: .center, spacing: 8) {
                        HStack(spacing: 5) {
                            if !row.modifiers.isEmpty {
                                Text(row.modifiers.symbols).font(.system(size: 11.5, weight: .semibold))
                            }
                            Eyebrow(row.gesture, color: row.modifiers.isEmpty ? Theme.ink : Theme.ink2)
                        }
                        .fixedSize()
                        Leader()
                        Text(row.text)
                            .font(.system(size: 12))
                            .lineLimit(1).truncationMode(.middle)
                            .layoutPriority(1)
                        if row.fromApp {
                            Rectangle().fill(Theme.ink).frame(width: 5, height: 5)
                                .help("Set by this app's profile")
                        }
                    }
                    .frame(height: 23)
                }
                if cheatRows.isEmpty {
                    Note("Nothing is bound here. The knob changes the volume.")
                        .frame(height: 23)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.vertical, 9)
        }
        .frame(maxHeight: 250)
    }

    private var footer: some View {
        HStack(spacing: 4) {
            Button("Configure") { openConfigurator(nil) }
            Button("Monitor") { openConfigurator(.monitor) }
            Spacer()
            Button("Quit", action: quit)
        }
        .buttonStyle(.kkGhost)
    }
}
