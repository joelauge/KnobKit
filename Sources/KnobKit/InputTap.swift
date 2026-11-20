import AppKit

/// A decoded event the tap hands to the dispatcher.
enum TapEvent {
    /// Media / system key (volume, mute, …). `code` is NX_KEYTYPE_*.
    case aux(code: Int, down: Bool, isRepeat: Bool, flags: CGEventFlags)
    case key(code: Int, down: Bool, isRepeat: Bool, flags: CGEventFlags)
}

private func tapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                         refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<InputTap>.fromOpaque(refcon).takeUnretainedValue()
    return tap.handle(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
}

/// Session-level event tap. Sees the knob's volume / mute events (and ordinary key
/// presses, for key remaps) before any app does and can swallow them.
/// Requires the Accessibility permission.
final class InputTap {
    private static let systemDefined = CGEventType(rawValue: 14)!

    private var port: CFMachPort?
    private var source: CFRunLoopSource?

    /// Return true to swallow the event.
    var handler: ((TapEvent) -> Bool)?

    var isRunning: Bool { port != nil }

    @discardableResult
    func start() -> Bool {
        guard port == nil else { return true }
        let mask: CGEventMask = (1 << 14) | (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        guard let p = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: tapCallback,
                                        userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }
        let s = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, p, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), s, .commonModes)
        CGEvent.tapEnable(tap: p, enable: true)
        port = p
        source = s
        return true
    }

    func stop() {
        if let p = port { CGEvent.tapEnable(tap: p, enable: false) }
        if let s = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        port = nil
        source = nil
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let p = port { CGEvent.tapEnable(tap: p, enable: true) }
            Log.write("event tap re-enabled after \(type == .tapDisabledByTimeout ? "timeout" : "user input")")
            return false
        }
        guard let handler else { return false }

        if type == Self.systemDefined {
            guard let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else { return false }
            let data1 = ns.data1
            let code = (data1 & 0xFFFF_0000) >> 16
            let keyFlags = data1 & 0x0000_FFFF
            let state = (keyFlags & 0xFF00) >> 8
            guard state == 0xA || state == 0xB else { return false }
            // Our own synthetic media keys: recognised by tag, or by count if the tag was lost.
            let tagged = Synthetic.isTagged(event)
            if Synthetic.consumeAux(code) || tagged {
                if state == 0xA { Log.write("  tap: own media key \(code) passed (\(tagged ? "tagged" : "tag stripped, matched by count"))") }
                return false
            }
            return handler(.aux(code: code, down: state == 0xA, isRepeat: (keyFlags & 0x1) != 0, flags: event.flags))
        }

        if type == .keyDown || type == .keyUp {
            if Synthetic.isTagged(event) { return false }
            let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            return handler(.key(code: code, down: type == .keyDown, isRepeat: isRepeat, flags: event.flags))
        }
        return false
    }
}
