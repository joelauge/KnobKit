import AppKit
import AudioToolbox
import CoreAudio
import KnobCore

// MARK: - Modifier conversions

extension ModifierSet {
    var cgFlags: CGEventFlags {
        var f: CGEventFlags = []
        if contains(.control) { f.insert(.maskControl) }
        if contains(.option) { f.insert(.maskAlternate) }
        if contains(.shift) { f.insert(.maskShift) }
        if contains(.command) { f.insert(.maskCommand) }
        return f
    }

    var nsFlags: NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if contains(.control) { f.insert(.control) }
        if contains(.option) { f.insert(.option) }
        if contains(.shift) { f.insert(.shift) }
        if contains(.command) { f.insert(.command) }
        return f
    }

    init(cgFlags f: CGEventFlags) {
        var m: ModifierSet = []
        if f.contains(.maskControl) { m.insert(.control) }
        if f.contains(.maskAlternate) { m.insert(.option) }
        if f.contains(.maskShift) { m.insert(.shift) }
        if f.contains(.maskCommand) { m.insert(.command) }
        self = m
    }

    init(nsFlags f: NSEvent.ModifierFlags) {
        var m: ModifierSet = []
        if f.contains(.control) { m.insert(.control) }
        if f.contains(.option) { m.insert(.option) }
        if f.contains(.shift) { m.insert(.shift) }
        if f.contains(.command) { m.insert(.command) }
        self = m
    }
}

// MARK: - Synthetic event bookkeeping

/// Everything KnobKit posts is tagged so its own event tap lets it straight through.
enum Synthetic {
    static let marker: Int64 = 0x4B6E_6F62 // "Knob"

    /// Backup for aux (media key) events in case the tag does not survive the round trip:
    /// count what we posted and let that many matching events pass.
    private static var pendingAux: [Int: Int] = [:]
    private static var lastAuxPost: TimeInterval = 0

    static func isTagged(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == marker
    }

    static func tag(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: marker)
    }

    static func noteAuxPosted(_ code: Int) {
        pendingAux[code, default: 0] += 1
        lastAuxPost = ProcessInfo.processInfo.systemUptime
    }

    /// True if this aux event is one we posted ourselves.
    static func consumeAux(_ code: Int) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastAuxPost > 0.5 { pendingAux.removeAll() }
        guard let n = pendingAux[code], n > 0 else { return false }
        pendingAux[code] = n - 1
        return true
    }
}

// MARK: - Posting keys, media keys, scroll, text

enum SystemKeys {
    /// Private source: posted events carry exactly the flags we set, regardless of which
    /// modifier keys the user is physically holding as a knob layer.
    private static let source = CGEventSource(stateID: .privateState)

    static let auxVolumeUp = 0, auxVolumeDown = 1, auxMute = 7

    /// Media / system key (NX_KEYTYPE_*), down then up.
    static func postAux(_ code: Int, flags: NSEvent.ModifierFlags = []) {
        for down in [true, false] {
            let state = down ? 0xA : 0xB
            let data1 = (code << 16) | (state << 8)
            guard let ev = NSEvent.otherEvent(
                with: .systemDefined, location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)).union(flags),
                timestamp: 0, windowNumber: 0, context: nil, subtype: 8, data1: data1, data2: -1),
                let cg = ev.cgEvent
            else { continue }
            Synthetic.tag(cg)
            Synthetic.noteAuxPosted(code)
            cg.post(tap: .cghidEventTap)
        }
    }

    /// Flags the system normally attaches to arrow / function / navigation keys.
    private static func intrinsicFlags(_ code: Int) -> CGEventFlags {
        switch code {
        case 123...126: return [.maskSecondaryFn, .maskNumericPad]
        case 96...101, 103, 105...107, 109, 111, 113...122, 64, 79, 80, 90: return .maskSecondaryFn
        default: return []
        }
    }

    static func postKey(_ code: Int, _ modifiers: ModifierSet, count: Int = 1) {
        let flags = modifiers.cgFlags.union(intrinsicFlags(code))
        for _ in 0..<max(1, count) {
            for down in [true, false] {
                guard let ev = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: down) else { continue }
                ev.flags = flags
                Synthetic.tag(ev)
                ev.post(tap: .cghidEventTap)
            }
        }
    }

    private static func modifierKeyCode(_ m: ModifierSet) -> Int {
        switch m {
        case .control: return Key.control
        case .option: return Key.option
        case .shift: return Key.shift
        default: return Key.command
        }
    }

    /// Press or release modifier keys as real flags-changed events (used for held-modifier
    /// switchers such as ⌘⇥). `current` is the full set held after this call.
    static func postModifiers(_ changed: ModifierSet, down: Bool, current: ModifierSet) {
        for m in ModifierSet.ordered where changed.contains(m) {
            guard let ev = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(modifierKeyCode(m)), keyDown: down) else { continue }
            ev.type = .flagsChanged
            ev.flags = current.cgFlags
            Synthetic.tag(ev)
            ev.post(tap: .cghidEventTap)
        }
    }

    /// Positive dy scrolls the content down, positive dx scrolls right.
    static func postScroll(dx: Int32, dy: Int32, unit: ScrollUnit, modifiers: ModifierSet) {
        guard dx != 0 || dy != 0,
              let ev = CGEvent(scrollWheelEvent2Source: source, units: unit == .pixel ? .pixel : .line,
                               wheelCount: 2, wheel1: -dy, wheel2: -dx, wheel3: 0)
        else { return }
        ev.flags = modifiers.cgFlags
        Synthetic.tag(ev)
        ev.post(tap: .cghidEventTap)
    }

    static func typeText(_ text: String) {
        let units = Array(text.utf16)
        var i = 0
        while i < units.count {
            let chunk = Array(units[i..<min(i + 20, units.count)])
            i += chunk.count
            for down in [true, false] {
                guard let ev = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                ev.flags = []
                ev.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                Synthetic.tag(ev)
                ev.post(tap: .cghidEventTap)
            }
        }
    }
}

// MARK: - Smooth scrolling

/// Spreads pixel scrolls over a few frames so a detent feels like a glide, not a jump.
final class Scroller {
    private var remainingX = 0.0
    private var remainingY = 0.0
    private var modifiers: ModifierSet = []
    private var timer: Timer?

    func scroll(dx: Double, dy: Double, unit: ScrollUnit, smooth: Bool, modifiers: ModifierSet) {
        guard unit == .pixel, smooth else {
            SystemKeys.postScroll(dx: Int32(dx.rounded()), dy: Int32(dy.rounded()), unit: unit, modifiers: modifiers)
            return
        }
        // A reversal should take effect at once rather than fight the leftover glide.
        if remainingX * dx < 0 { remainingX = 0 }
        if remainingY * dy < 0 { remainingY = 0 }
        remainingX += dx
        remainingY += dy
        self.modifiers = modifiers
        if timer == nil {
            let t = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in self?.step() }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    private func take(_ remaining: inout Double) -> Int32 {
        guard remaining.magnitude >= 0.5 else { remaining = 0; return 0 }
        var part = remaining * 0.24
        if part.magnitude < 1 { part = remaining < 0 ? -1 : 1 }
        part = part.rounded()
        remaining -= part
        return Int32(part)
    }

    private func step() {
        let x = take(&remainingX)
        let y = take(&remainingY)
        if x == 0 && y == 0 {
            timer?.invalidate()
            timer = nil
            return
        }
        SystemKeys.postScroll(dx: x, dy: y, unit: .pixel, modifiers: modifiers)
    }
}

// MARK: - Held-modifier keystrokes

/// Keeps a modifier down across knob ticks and releases it after a pause, so the knob
/// can drive switchers like ⌘⇥ or ⌃⇥ that commit when the modifier is released.
final class StickyKeys {
    private var held: ModifierSet = []
    private var release: DispatchWorkItem?

    func fire(hold: ModifierSet, key: KeyCombo, releaseAfter: Double) {
        if held != hold {
            releaseNow()
            SystemKeys.postModifiers(hold, down: true, current: hold)
            held = hold
        }
        SystemKeys.postKey(key.keyCode, hold.union(key.modifiers))
        release?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.releaseNow() }
        release = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.1, releaseAfter), execute: work)
    }

    func releaseNow() {
        release?.cancel()
        release = nil
        guard !held.isEmpty else { return }
        SystemKeys.postModifiers(held, down: false, current: [])
        held = []
    }
}

// MARK: - Output volume

/// Reads and writes the default output device's volume directly, which allows any step
/// size. Returns nil / false for devices without a software volume (some HDMI and USB
/// outputs); callers then fall back to the system volume keys.
enum SystemVolume {
    private static func defaultDevice() -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return status == noErr && id != kAudioObjectUnknown ? id : nil
    }

    private static func volumeAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                   mScope: kAudioDevicePropertyScopeOutput,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func muteAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                   mScope: kAudioDevicePropertyScopeOutput,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    static func get() -> Double? {
        guard let dev = defaultDevice() else { return nil }
        var addr = volumeAddress()
        guard AudioObjectHasProperty(dev, &addr) else { return nil }
        var v = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &v) == noErr ? Double(v) : nil
    }

    static func set(_ value: Double) -> Bool {
        guard let dev = defaultDevice() else { return false }
        var addr = volumeAddress()
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(dev, &addr),
              AudioObjectIsPropertySettable(dev, &addr, &settable) == noErr, settable.boolValue
        else { return false }
        var v = Float32(min(max(value, 0), 1))
        return AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v) == noErr
    }

    static func isMuted() -> Bool? {
        guard let dev = defaultDevice() else { return nil }
        var addr = muteAddress()
        guard AudioObjectHasProperty(dev, &addr) else { return nil }
        var m = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &m) == noErr ? m != 0 : nil
    }

    static func setMuted(_ muted: Bool) -> Bool {
        guard let dev = defaultDevice() else { return false }
        var addr = muteAddress()
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(dev, &addr),
              AudioObjectIsPropertySettable(dev, &addr, &settable) == noErr, settable.boolValue
        else { return false }
        var m = UInt32(muted ? 1 : 0)
        return AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &m) == noErr
    }
}
