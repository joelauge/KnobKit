import Foundation

/// Where a resolved binding came from. Shown in the menu and the live monitor.
public enum BindingSource: String, Sendable {
    case appMode, appAlways, globalMode, globalAlways

    public var isApp: Bool { self == .appMode || self == .appAlways }
}

public struct ResolvedBinding: Sendable {
    public var binding: KnobBinding
    public var source: BindingSource
}

/// The bindings in effect right now: the matched app profile (if any) layered over Global.
///
/// Lookup order for any gesture:
///   1. app profile, current mode
///   2. app profile, always-on layer
///   3. Global, current mode      (skipped if the app profile does not inherit)
///   4. Global, always-on layer
public struct ActiveContext: Sendable {
    public var app: Profile?
    public var appModeIndex: Int
    public var global: Profile
    public var globalModeIndex: Int

    public init(app: Profile?, appModeIndex: Int, global: Profile, globalModeIndex: Int) {
        self.app = app
        self.appModeIndex = appModeIndex
        self.global = global
        self.globalModeIndex = globalModeIndex
    }

    public var appMode: Mode? {
        guard let app, !app.modes.isEmpty else { return nil }
        return app.modes[min(max(appModeIndex, 0), app.modes.count - 1)]
    }

    public var globalMode: Mode? {
        guard !global.modes.isEmpty else { return nil }
        return global.modes[min(max(globalModeIndex, 0), global.modes.count - 1)]
    }

    private var inheritsGlobal: Bool { app?.inheritsGlobal ?? true }

    /// Layers in lookup order.
    public var layers: [(Mode, BindingSource)] {
        var out: [(Mode, BindingSource)] = []
        if let m = appMode { out.append((m, .appMode)) }
        if let app { out.append((app.always, .appAlways)) }
        if inheritsGlobal {
            if let m = globalMode { out.append((m, .globalMode)) }
            out.append((global.always, .globalAlways))
        }
        return out
    }

    public func binding(_ gesture: KnobGesture, _ modifiers: ModifierSet, speed: SpeedClass = .any) -> ResolvedBinding? {
        for (mode, source) in layers {
            if let b = mode.binding(gesture, modifiers, speed: speed) {
                return ResolvedBinding(binding: b, source: source)
            }
        }
        return nil
    }

    /// True if any layer binds this gesture with any modifier combination.
    public func hasGesture(_ gesture: KnobGesture) -> Bool {
        layers.contains { $0.0.knob.contains { $0.gesture == gesture } }
    }

    /// True if any press-type gesture is bound anywhere, so the knob press must be tracked.
    public var tracksPress: Bool {
        layers.contains { $0.0.knob.contains { !$0.gesture.isRotation || $0.gesture.isPressRotate } }
    }

    public func keyBinding(_ combo: KeyCombo) -> KeyBinding? {
        for (mode, _) in layers {
            if let k = mode.keys.first(where: { $0.key == combo }) { return k }
        }
        return nil
    }

    public var hasKeyBindings: Bool { layers.contains { !$0.0.keys.isEmpty } }

    /// The profile whose modes the knob cycles through: the app profile when it has
    /// modes of its own to choose between, otherwise Global.
    public var modeOwnerIsApp: Bool { (app?.modes.count ?? 0) >= 2 }

    public var displayMode: Mode? { appMode ?? globalMode }

    public var modeOwner: Profile { modeOwnerIsApp ? app! : global }

    public var modeOwnerIndex: Int { modeOwnerIsApp ? appModeIndex : globalModeIndex }

    /// Every (gesture, modifiers) pair bound in the current context with the winning binding,
    /// for the "what does the knob do right now" cheat sheet.
    public func cheatSheet() -> [ResolvedBinding] {
        var seen = Set<String>()
        var out: [ResolvedBinding] = []
        for (mode, source) in layers {
            for b in mode.knob {
                let key = "\(b.gesture.rawValue)|\(b.modifiers.rawValue)|\(b.speed.rawValue)"
                if seen.insert(key).inserted { out.append(ResolvedBinding(binding: b, source: source)) }
            }
        }
        let order = KnobGesture.allCases
        return out.sorted { a, b in
            if a.binding.modifiers.rawValue != b.binding.modifiers.rawValue {
                return a.binding.modifiers.rawValue < b.binding.modifiers.rawValue
            }
            return order.firstIndex(of: a.binding.gesture)! < order.firstIndex(of: b.binding.gesture)!
        }
    }
}

public enum Resolver {
    /// First enabled app profile matching the frontmost app. `title` is only evaluated
    /// for profiles that carry a window-title filter.
    public static func profile(in config: Config, bundleID: String?, title: () -> String?) -> Profile? {
        guard let bundleID else { return nil }
        var titleLoaded = false
        var cachedTitle: String?
        // Profiles with a title filter are more specific, so they win over plain matches.
        let candidates = config.profiles.filter { $0.enabled && $0.matches(bundleID: bundleID) }
        for p in candidates where !p.titleContains.isEmpty {
            if !titleLoaded { cachedTitle = title(); titleLoaded = true }
            if let t = cachedTitle, t.localizedCaseInsensitiveContains(p.titleContains) { return p }
        }
        return candidates.first { $0.titleContains.isEmpty }
    }

    public static func context(config: Config, bundleID: String?, title: () -> String?, modeIndex: [UUID: Int]) -> ActiveContext {
        let app = profile(in: config, bundleID: bundleID, title: title)
        return ActiveContext(
            app: app,
            appModeIndex: app.flatMap { modeIndex[$0.id] } ?? 0,
            global: config.global,
            globalModeIndex: modeIndex[config.global.id] ?? 0
        )
    }
}
