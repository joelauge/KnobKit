import AppKit
import KnobCore
import SwiftUI

struct ConfiguratorView: View {
    @EnvironmentObject private var state: AppState
    var simulate: ([String]) -> Void

    var body: some View {
        HStack(spacing: 0) {
            Sidebar()
                .frame(width: 232)
            VRule()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Theme.bg)
        .kkRoot()
        .frame(minWidth: 900, minHeight: 560)
        // The window has no title bar of its own: the black runs to the top edge.
        .ignoresSafeArea()
    }

    @ViewBuilder private var detail: some View {
        switch state.selection {
        case .profile(let id):
            if let binding = state.profileBinding(id) {
                ProfileEditor(profile: binding, isGlobal: id == state.config.global.id)
                    .id(id)
            } else {
                Text("Select a profile").foregroundStyle(Theme.ink2).padding(40)
            }
        case .feel:
            FeelView()
        case .devices:
            DevicesView()
        case .general:
            GeneralView()
        case .monitor:
            MonitorView(log: state.monitor, simulate: simulate)
        }
    }
}

/// Shared frame for a settings page: title, then scrolling content.
struct Page<Content: View>: View {
    let title: String
    var subtitle: String?
    var maxWidth: CGFloat = 780
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageTitle(title: title, subtitle: subtitle)
                content
            }
            .padding(.horizontal, 30)
            .padding(.top, 38)
            .padding(.bottom, 30)
            .frame(maxWidth: maxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct PageTitle: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.kkDisplay(23))
            if let subtitle { Text(subtitle).foregroundStyle(Theme.ink2) }
        }
    }
}

// MARK: - Sidebar

private struct Sidebar: View {
    @EnvironmentObject private var state: AppState

    private var needsAttention: Bool {
        !state.axTrusted || (state.config.settings.deviceMode == .selected && !state.hidListening)
    }

    private func isSelected(_ item: SidebarItem) -> Bool { state.selection == item }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Clear of the window's traffic lights.
            VStack(alignment: .leading, spacing: 3) {
                Text("KNOBKIT").font(.kkDisplay(15)).tracking(1.8)
                Eyebrow("F75 knob configurator", color: Theme.ink3)
            }
            .padding(.horizontal, 18)
            .padding(.top, 50)
            .padding(.bottom, 20)
            Rule()

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    section("Profiles")
                    SideRow(title: "Global", selected: isSelected(.profile(state.config.global.id))) {
                        Image(systemName: "globe").font(.system(size: 14, weight: .light))
                    } action: {
                        state.selection = .profile(state.config.global.id)
                    }
                    ForEach(Array(state.config.profiles.enumerated()), id: \.element.id) { index, profile in
                        SideRow(title: profile.name, selected: isSelected(.profile(profile.id)),
                                live: state.context.app?.id == profile.id) {
                            AppIcon(bundleID: profile.bundleIDs.first, size: 17)
                        } action: {
                            state.selection = .profile(profile.id)
                        }
                        .opacity(profile.enabled ? 1 : 0.45)
                        .contextMenu {
                            Button(profile.enabled ? "Disable" : "Enable") {
                                state.config.profiles[index].enabled.toggle()
                            }
                            Button("Move up") { state.config.profiles.swapAt(index, index - 1) }
                                .disabled(index == 0)
                            Button("Move down") { state.config.profiles.swapAt(index, index + 1) }
                                .disabled(index == state.config.profiles.count - 1)
                            Button("Delete", role: .destructive) { state.deleteProfile(profile.id) }
                        }
                    }

                    section("Settings").padding(.top, 14)
                    SideRow(title: "Knob feel", selected: isSelected(.feel)) {
                        Image(systemName: "slider.horizontal.3").font(.system(size: 13, weight: .light))
                    } action: { state.selection = .feel }
                    SideRow(title: "Devices", selected: isSelected(.devices), warning: needsAttention) {
                        Image(systemName: "keyboard").font(.system(size: 13, weight: .light))
                    } action: { state.selection = .devices }
                    SideRow(title: "General", selected: isSelected(.general)) {
                        Image(systemName: "gearshape").font(.system(size: 13, weight: .light))
                    } action: { state.selection = .general }
                    SideRow(title: "Live monitor", selected: isSelected(.monitor)) {
                        Image(systemName: "waveform.path.ecg").font(.system(size: 13, weight: .light))
                    } action: { state.selection = .monitor }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 14)
            }

            Rule()
            AddProfileMenu()
                .padding(12)
        }
    }

    private func section(_ title: String) -> some View {
        Eyebrow(title, color: Theme.ink3)
            .padding(.horizontal, 8)
            .padding(.bottom, 6)
    }
}

private struct SideRow<Icon: View>: View {
    let title: String
    let selected: Bool
    var live = false
    var warning = false
    @ViewBuilder var icon: Icon
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                icon.frame(width: 18, height: 18)
                Text(title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if warning {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.warn)
                }
                if live {
                    Rectangle().fill(Theme.ink).frame(width: 5, height: 5).help("Active right now")
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .foregroundStyle(selected ? Theme.ink : (hover ? Theme.ink : Theme.ink2))
            .background(RoundedRectangle(cornerRadius: Theme.radius).fill(hover && !selected ? Theme.raised : .clear))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius)
                .strokeBorder(selected ? Theme.ink : .clear, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct AddProfileMenu: View {
    @EnvironmentObject private var state: AppState

    private func items() -> [KKMenuItem] {
        var out: [KKMenuItem] = [.header("Running apps")]
        for app in AppChooser.running() where state.profile(matching: app.bundleID) == nil {
            out.append(.action(app.name) { state.addProfile(name: app.name, bundleIDs: [app.bundleID]) })
        }
        out.append(.header("Templates"))
        for template in Templates.all {
            out.append(.action(template.name) { state.addTemplate(template) })
        }
        out.append(.separator)
        out.append(.action("Choose application…") {
            if let picked = AppChooser.pick() { state.addProfile(name: picked.name, bundleIDs: [picked.bundleID]) }
        })
        return out
    }

    var body: some View {
        KKMenu("Add app profile", systemImage: "plus", items: items)
    }
}
