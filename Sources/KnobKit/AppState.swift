import AppKit
import Combine
import KnobCore
import SwiftUI

struct FrontApp: Equatable {
    var bundleID: String?
    var name: String
    var pid: pid_t
}

struct MonitorEntry: Identifiable {
    let id = UUID()
    var time: Date
    var source: String
    var event: String
    var result: String
    var swallowed: Bool
}

/// Kept apart from AppState so that a spinning knob only redraws the monitor page,
/// not every view that observes the configuration.
final class MonitorLog: ObservableObject {
    @Published var entries: [MonitorEntry] = []

    func append(_ entry: MonitorEntry) {
        entries.append(entry)
        if entries.count > 300 { entries.removeFirst(entries.count - 300) }
    }
}

enum SidebarItem: Hashable {
    case profile(UUID)
    case feel, devices, general, monitor, lights
}

// MARK: - Config file

enum ConfigStore {
    static let directory: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KnobKit", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static let url = directory.appendingPathComponent("config.json")

    static func isInstalled(_ bundleIDs: [String]) -> Bool {
        bundleIDs.contains { id in
            !id.hasSuffix("*") && NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil
        }
    }

    /// Defaults plus profiles for the apps that are actually installed.
    static func firstRunConfig() -> Config {
        let profiles = Templates.all.filter { $0.installByDefault && isInstalled($0.bundleIDs) }.map { $0.build() }
        var config = Config.makeDefault(profiles: profiles)
        // A Universal Audio interface has no macOS volume, so the stock volume bindings
        // would do nothing: point them at its monitor output instead.
        if UAMixer.isReachable() { config.adoptMonitorVolume() }
        return config
    }

    static func load() -> Config {
        guard let data = try? Data(contentsOf: url) else {
            let fresh = firstRunConfig()
            save(fresh)
            Log.write("created default config with \(fresh.profiles.count) app profiles")
            return fresh
        }
        do {
            var config = try Config.decode(data)
            if config.migrate() {
                save(config)
                Log.write("config migrated to version \(config.version)")
            }
            return config
        } catch {
            // Never overwrite a config we could not read: keep it next to the new one.
            let backup = directory.appendingPathComponent("config.unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.copyItem(at: url, to: backup)
            Log.write("config could not be read (\(error)); kept a copy at \(backup.lastPathComponent)")
            return firstRunConfig()
        }
    }

    static func save(_ config: Config) {
        do {
            try config.encoded().write(to: url, options: .atomic)
        } catch {
            Log.write("config save failed: \(error)")
        }
    }
}

// MARK: - App state

final class AppState: ObservableObject {
    @Published var config: Config {
        didSet { if config != oldValue { configChanged() } }
    }
    /// The app the knob is acting on. KnobKit's own windows are transparent: opening the
    /// menu or configurator does not change this.
    @Published private(set) var frontApp = FrontApp(bundleID: nil, name: "", pid: 0)
    @Published private(set) var context: ActiveContext
    @Published private(set) var modeIndex: [UUID: Int] = [:]

    @Published var axTrusted = false
    @Published var hidAccess: HIDWatcher.Access = .unknown
    @Published var hidListening = false
    @Published var tapRunning = false
    @Published var devices: [HIDDeviceInfo] = []
    /// Waiting for the user to turn the knob so its device can be picked.
    @Published var learningKnob = false
    /// Name of the device "Find my knob" just picked.
    @Published var learnedDevice: String?
    private var learnTimeout: DispatchWorkItem?
    let monitor = MonitorLog()
    let lightShow = LightShowPlayer()
    @Published var selection: SidebarItem

    /// While a key recorder is listening, the tap lets every key through.
    var isRecordingKey = false
    var onConfigChanged: (() -> Void)?
    var onModeChanged: (() -> Void)?
    /// A knob keyboard was connected, ticked or found.
    var onKnobConnected: ((HIDDeviceInfo) -> Void)?

    private var saveWork: DispatchWorkItem?
    private var lastContextRefresh: TimeInterval = 0
    private var observers: [NSObjectProtocol] = []

    init() {
        let loaded = ConfigStore.load()
        config = loaded
        selection = .profile(loaded.global.id)
        context = ActiveContext(app: nil, appModeIndex: 0, global: loaded.global, globalModeIndex: 0)
        if let saved = UserDefaults.standard.dictionary(forKey: "modeIndex") as? [String: Int] {
            for (k, v) in saved { if let id = UUID(uuidString: k) { modeIndex[id] = v } }
        }
        if let app = NSWorkspace.shared.frontmostApplication { setFront(app) }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                self?.setFront(app)
            }
        })
        refreshContext()
    }

    private func setFront(_ app: NSRunningApplication) {
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        let next = FrontApp(bundleID: app.bundleIdentifier, name: app.localizedName ?? "App", pid: app.processIdentifier)
        guard next != frontApp else { return }
        frontApp = next
        refreshContext()
    }

    // MARK: Context

    private var frontHasTitleFilters: Bool {
        guard let id = frontApp.bundleID else { return false }
        return config.profiles.contains { $0.enabled && !$0.titleContains.isEmpty && $0.matches(bundleID: id) }
    }

    func refreshContext() {
        lastContextRefresh = ProcessInfo.processInfo.systemUptime
        let pid = frontApp.pid
        context = Resolver.context(config: config, bundleID: frontApp.bundleID,
                                   title: { AX.frontWindowTitle(pid: pid) }, modeIndex: modeIndex)
    }

    /// Window-title filters can change without an app switch, so re-resolve at most a few
    /// times a second when they are in play.
    func refreshContextIfStale() {
        guard frontHasTitleFilters else { return }
        if ProcessInfo.processInfo.systemUptime - lastContextRefresh > 0.3 { refreshContext() }
    }

    private func configChanged() {
        refreshContext()
        onConfigChanged?()
        saveWork?.cancel()
        let snapshot = config
        let work = DispatchWorkItem { ConfigStore.save(snapshot) }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func saveNow() {
        saveWork?.cancel()
        ConfigStore.save(config)
    }

    // MARK: Modes

    private func persistModes() {
        var out: [String: Int] = [:]
        for (k, v) in modeIndex { out[k.uuidString] = v }
        UserDefaults.standard.set(out, forKey: "modeIndex")
    }

    func setMode(profileID: UUID, index: Int) {
        modeIndex[profileID] = index
        persistModes()
        refreshContext()
        onModeChanged?()
    }

    /// Steps the active mode owner's mode. Returns the new mode.
    @discardableResult
    func cycleMode(_ delta: Int) -> Mode? {
        let owner = context.modeOwner
        let n = owner.modes.count
        guard n > 0 else { return nil }
        let next = ((context.modeOwnerIndex + delta) % n + n) % n
        setMode(profileID: owner.id, index: next)
        return owner.modes[next]
    }

    @discardableResult
    func setMode(named name: String) -> Mode? {
        for owner in [context.app, Optional(context.global)].compactMap({ $0 }) {
            if let i = owner.modes.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                setMode(profileID: owner.id, index: i)
                return owner.modes[i]
            }
        }
        return nil
    }

    // MARK: Profiles

    func profileBinding(_ id: UUID) -> Binding<Profile>? {
        if config.global.id == id {
            return Binding(get: { self.config.global }, set: { self.config.global = $0 })
        }
        guard let snapshot = config.profiles.first(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { self.config.profiles.first(where: { $0.id == id }) ?? snapshot },
            set: { value in
                if let i = self.config.profiles.firstIndex(where: { $0.id == id }) { self.config.profiles[i] = value }
            })
    }

    func profile(matching bundleID: String?) -> Profile? {
        guard let bundleID else { return nil }
        return config.profiles.first { $0.matches(bundleID: bundleID) }
    }

    @discardableResult
    func addProfile(name: String, bundleIDs: [String]) -> UUID {
        // Start from a matching template when there is one.
        if let template = Templates.all.first(where: { t in t.bundleIDs.contains { id in bundleIDs.contains(id) } }) {
            var p = template.build()
            p.bundleIDs = Array(Set(p.bundleIDs).union(bundleIDs)).sorted()
            config.profiles.append(p)
            selection = .profile(p.id)
            return p.id
        }
        let p = Profile(name, bundleIDs: bundleIDs)
        config.profiles.append(p)
        selection = .profile(p.id)
        return p.id
    }

    func addTemplate(_ template: ProfileTemplate) {
        let p = template.build()
        config.profiles.append(p)
        selection = .profile(p.id)
    }

    func deleteProfile(_ id: UUID) {
        config.profiles.removeAll { $0.id == id }
        selection = .profile(config.global.id)
    }

    // MARK: Monitor

    func record(source: String, event: String, result: String, swallowed: Bool) {
        Log.write("[\(source)] \(event) -> \(result)\(swallowed ? "" : " (passed to system)")")
        monitor.append(MonitorEntry(time: Date(), source: source, event: event, result: result, swallowed: swallowed))
    }

    // MARK: Devices

    func isSelected(_ device: HIDDeviceInfo) -> Bool {
        config.settings.devices.contains { $0.vendorID == device.vendorID && $0.productID == device.productID }
    }

    func setSelected(_ device: HIDDeviceInfo, _ on: Bool) {
        config.settings.devices.removeAll { $0.vendorID == device.vendorID && $0.productID == device.productID }
        if on {
            config.settings.devices.append(device.ref)
            onKnobConnected?(device)
        }
    }

    /// The connected knob keyboard whose backlight can be driven, if there is one.
    var lightShowDevice: HIDDeviceInfo? {
        devices.first { isSelected($0) && KeyboardHID.hasLightingChannel($0) }
    }

    /// True while a selected knob device is connected.
    var knobConnected: Bool { devices.contains { isSelected($0) } }

    /// "Find my knob": the next device to send a volume or mute signal becomes the knob.
    func startLearningKnob() {
        learnedDevice = nil
        learningKnob = true
        learnTimeout?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.learningKnob = false }
        learnTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: work)
    }

    func stopLearningKnob() {
        learnTimeout?.cancel()
        learningKnob = false
    }

    /// A device sent a volume or mute signal. Main queue.
    func deviceSpoke(_ device: HIDDeviceInfo) {
        guard learningKnob, !device.isBuiltIn else { return }
        stopLearningKnob()
        if config.settings.deviceMode != .selected { config.settings.deviceMode = .selected }
        if isSelected(device) { onKnobConnected?(device) } else { setSelected(device, true) }
        learnedDevice = device.name
        Log.write("learned knob device \(device.name) [\(device.ref.id)] via \(device.transport)")
    }

    /// Called whenever the HID device list changes: tick any Epomaker keyboard we have
    /// not seen yet.
    func updateDevices(_ list: [HIDDeviceInfo]) {
        let before = Set(devices.map(\.registryID))
        devices = list
        // Keyboards already ticked that have just appeared (at launch, or on reconnect).
        for d in list where isSelected(d) && !before.contains(d.registryID) { onKnobConnected?(d) }
        for d in list where d.looksLikeEpomaker && !isSelected(d) {
            let known = UserDefaults.standard.stringArray(forKey: "autoSelectedDevices") ?? []
            guard !known.contains(d.ref.id) else { continue }
            UserDefaults.standard.set(known + [d.ref.id], forKey: "autoSelectedDevices")
            setSelected(d, true)
            Log.write("auto-selected knob device \(d.name) [\(d.ref.id)] via \(d.transport)")
        }
    }
}
