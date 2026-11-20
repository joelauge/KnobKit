import AppKit
import KnobCore
import SwiftUI

struct ConfiguratorView: View {
    @EnvironmentObject private var state: AppState
    var simulate: ([String]) -> Void

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 210, ideal: 235, max: 320)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 900, minHeight: 560)
    }

    @ViewBuilder private var detail: some View {
        switch state.selection {
        case .profile(let id):
            if let binding = state.profileBinding(id) {
                ProfileEditor(profile: binding, isGlobal: id == state.config.global.id)
                    .id(id)
            } else {
                Text("Select a profile").foregroundStyle(.secondary).padding(40)
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

private struct Sidebar: View {
    @EnvironmentObject private var state: AppState

    private var selection: Binding<SidebarItem?> {
        Binding(get: { state.selection }, set: { if let value = $0 { state.selection = value } })
    }

    private var needsAttention: Bool {
        !state.axTrusted || (state.config.settings.deviceMode == .selected && !state.hidListening)
    }

    var body: some View {
        List(selection: selection) {
            Section("Profiles") {
                Label("Global", systemImage: "globe")
                    .tag(SidebarItem.profile(state.config.global.id))
                ForEach(state.config.profiles) { profile in
                    HStack(spacing: 8) {
                        AppIcon(bundleID: profile.bundleIDs.first, size: 18)
                        Text(profile.name).lineLimit(1)
                        Spacer()
                        if state.context.app?.id == profile.id {
                            Circle().fill(Color.green).frame(width: 6, height: 6).help("Active right now")
                        }
                    }
                    .opacity(profile.enabled ? 1 : 0.45)
                    .tag(SidebarItem.profile(profile.id))
                    .contextMenu {
                        Button(profile.enabled ? "Disable" : "Enable") {
                            if let i = state.config.profiles.firstIndex(where: { $0.id == profile.id }) {
                                state.config.profiles[i].enabled.toggle()
                            }
                        }
                        Button("Delete", role: .destructive) { state.deleteProfile(profile.id) }
                    }
                }
                .onMove { from, to in state.config.profiles.move(fromOffsets: from, toOffset: to) }
            }
            Section("Settings") {
                Label("Knob feel", systemImage: "slider.horizontal.3").tag(SidebarItem.feel)
                HStack {
                    Label("Devices", systemImage: "keyboard")
                    Spacer()
                    if needsAttention {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }
                .tag(SidebarItem.devices)
                Label("General", systemImage: "gearshape").tag(SidebarItem.general)
                Label("Live monitor", systemImage: "waveform.path.ecg").tag(SidebarItem.monitor)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            AddProfileMenu()
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct AddProfileMenu: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Menu {
            Section("Running apps") {
                ForEach(AppChooser.running().filter { state.profile(matching: $0.bundleID) == nil }, id: \.bundleID) { app in
                    Button(app.name) { state.addProfile(name: app.name, bundleIDs: [app.bundleID]) }
                }
            }
            Section("Templates") {
                ForEach(Templates.all) { template in
                    Button(template.name) { state.addTemplate(template) }
                }
            }
            Button("Choose application…") {
                if let picked = AppChooser.pick() { state.addProfile(name: picked.name, bundleIDs: [picked.bundleID]) }
            }
        } label: {
            Label("Add app profile", systemImage: "plus")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}
