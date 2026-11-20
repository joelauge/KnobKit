import Foundation
import IOKit
import IOKit.hid
import KnobCore

struct HIDDeviceInfo: Identifiable, Hashable {
    var registryID: UInt64
    var vendorID: Int
    var productID: Int
    var name: String
    var transport: String
    var isKeyboard: Bool

    var id: UInt64 { registryID }
    var ref: DeviceRef { DeviceRef(vendorID: vendorID, productID: productID, name: name, transport: transport) }

    /// Heuristic for auto-selecting the F75 on any of its three connections.
    var looksLikeF75: Bool {
        let n = name.lowercased()
        return n.contains("f75") || n.contains("aula") || n.contains("epomaker") || vendorID == 0x3554
    }
}

private let hidValueCallback: IOHIDValueCallback = { context, _, _, value in
    guard let context else { return }
    Unmanaged<HIDWatcher>.fromOpaque(context).takeUnretainedValue().handle(value: value)
}

private let hidDeviceCallback: IOHIDDeviceCallback = { context, _, _, _ in
    guard let context else { return }
    Unmanaged<HIDWatcher>.fromOpaque(context).takeUnretainedValue().devicesChanged()
}

/// Listens to consumer-control usages (volume up / down / mute) on every HID device and
/// records which device produced each press. The event tap asks this who sent an event,
/// which is how the F75's knob is told apart from the MacBook's own volume keys.
///
/// Only the consumer page is observed; ordinary keystrokes are never read here.
final class HIDWatcher {
    enum Access { case granted, denied, unknown }

    static let usageVolumeUp = 0xE9, usageVolumeDown = 0xEA, usageMute = 0xE2

    private struct Stamp {
        var device: HIDDeviceInfo
        var at: UInt64
    }

    private var manager: IOHIDManager?
    private let queue = DispatchQueue(label: "knobkit.hid", qos: .userInteractive)
    private let cond = NSCondition()
    private var pending: [Int: [Stamp]] = [:]
    private var infoCache: [UInt: HIDDeviceInfo] = [:]
    private(set) var isListening = false
    private var publishWork: DispatchWorkItem?

    /// Called on the main queue.
    var onDevicesChanged: (([HIDDeviceInfo]) -> Void)?
    /// Called on the HID queue: device, usage, value.
    var onRaw: ((HIDDeviceInfo, Int, Int) -> Void)?

    static var access: Access {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: return .granted
        case kIOHIDAccessTypeDenied: return .denied
        default: return .unknown
        }
    }

    /// Shows the system Input Monitoring prompt the first time it is called.
    @discardableResult
    static func requestAccess() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    /// (Re)creates the manager. Devices are always enumerated; input is only opened once
    /// Input Monitoring has been granted.
    func start() {
        stop()
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [[String: Any]] = [[
            kIOHIDDeviceUsagePageKey: kHIDPage_Consumer,
            kIOHIDDeviceUsageKey: kHIDUsage_Csmr_ConsumerControl,
        ]]
        IOHIDManagerSetDeviceMatchingMultiple(m, matching as CFArray)
        IOHIDManagerSetInputValueMatching(m, [kIOHIDElementUsagePageKey: kHIDPage_Consumer] as CFDictionary)

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(m, hidDeviceCallback, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(m, hidDeviceCallback, ctx)
        IOHIDManagerRegisterInputValueCallback(m, hidValueCallback, ctx)
        IOHIDManagerSetDispatchQueue(m, queue)
        IOHIDManagerSetCancelHandler(m) {}

        if Self.access == .granted {
            let result = IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
            isListening = true
            Log.write("HID manager opened (result 0x\(String(result, radix: 16)))")
        } else {
            isListening = false
            Log.write("HID manager enumerating only: Input Monitoring not granted")
        }
        // Assign before activating: matching callbacks can fire on the HID queue at once.
        manager = m
        IOHIDManagerActivate(m)
        devicesChanged()
    }

    func stop() {
        guard let m = manager else { return }
        IOHIDManagerCancel(m)
        manager = nil
        isListening = false
        cond.lock()
        pending.removeAll()
        infoCache.removeAll()
        cond.unlock()
    }

    private func info(for device: IOHIDDevice) -> HIDDeviceInfo {
        let key = UInt(bitPattern: Unmanaged.passUnretained(device).toOpaque())
        cond.lock()
        if let cached = infoCache[key] { cond.unlock(); return cached }
        cond.unlock()

        func prop<T>(_ name: String) -> T? { IOHIDDeviceGetProperty(device, name as CFString) as? T }
        var registryID: UInt64 = 0
        let service = IOHIDDeviceGetService(device)
        if service != MACH_PORT_NULL { IORegistryEntryGetRegistryEntryID(service, &registryID) }
        let info = HIDDeviceInfo(
            registryID: registryID,
            vendorID: prop(kIOHIDVendorIDKey) ?? 0,
            productID: prop(kIOHIDProductIDKey) ?? 0,
            name: ((prop(kIOHIDProductKey) as String?) ?? "Unknown device").trimmingCharacters(in: .whitespaces),
            transport: prop(kIOHIDTransportKey) ?? "",
            isKeyboard: Self.hasUsage(device, page: kHIDPage_GenericDesktop, usage: kHIDUsage_GD_Keyboard)
        )
        cond.lock()
        infoCache[key] = info
        cond.unlock()
        return info
    }

    /// Reads the declared usage pairs, which works without opening the device (and so
    /// without Input Monitoring), unlike IOHIDDeviceConformsTo.
    private static func hasUsage(_ device: IOHIDDevice, page: Int, usage: Int) -> Bool {
        if let pairs = IOHIDDeviceGetProperty(device, kIOHIDDeviceUsagePairsKey as CFString) as? [[String: Any]] {
            return pairs.contains {
                ($0[kIOHIDDeviceUsagePageKey] as? Int) == page && ($0[kIOHIDDeviceUsageKey] as? Int) == usage
            }
        }
        return (IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? Int) == page
            && (IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString) as? Int) == usage
    }

    /// Devices arrive one callback at a time; publish the list once things settle.
    fileprivate func devicesChanged() {
        queue.async { [weak self] in
            guard let self else { return }
            self.publishWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.publishDevices() }
            self.publishWork = work
            self.queue.asyncAfter(deadline: .now() + 0.15, execute: work)
        }
    }

    private func publishDevices() {
        guard let m = manager else { return }
        cond.lock()
        infoCache.removeAll()
        cond.unlock()
        let set = (IOHIDManagerCopyDevices(m) as? Set<IOHIDDevice>) ?? []
        var seen = Set<String>()
        let list = set.map { info(for: $0) }
            .filter { seen.insert("\($0.vendorID):\($0.productID):\($0.name)").inserted }
            .sorted { ($0.isKeyboard ? 0 : 1, $0.name) < ($1.isKeyboard ? 0 : 1, $1.name) }
        Log.write("HID devices with volume controls: " + (list.isEmpty ? "none" : list.map { "\($0.name) [\(String(format: "%04x:%04x", $0.vendorID, $0.productID)) \($0.transport)\($0.isKeyboard ? " keyboard" : "")]" }.joined(separator: ", ")))
        DispatchQueue.main.async { [weak self] in self?.onDevicesChanged?(list) }
    }

    fileprivate func handle(value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        guard IOHIDElementGetUsagePage(element) == UInt32(kHIDPage_Consumer) else { return }
        let usage = Int(IOHIDElementGetUsage(element))
        guard usage == Self.usageVolumeUp || usage == Self.usageVolumeDown || usage == Self.usageMute else { return }
        let v = IOHIDValueGetIntegerValue(value)
        let device = info(for: IOHIDElementGetDevice(element))
        if v != 0 {
            let now = DispatchTime.now().uptimeNanoseconds
            cond.lock()
            var q = pending[usage] ?? []
            q.removeAll { now - $0.at > 400_000_000 }
            q.append(Stamp(device: device, at: now))
            pending[usage] = q
            cond.broadcast()
            cond.unlock()
        }
        onRaw?(device, usage, v)
    }

    /// Which device pressed `usage` just now? Waits briefly because the HID report and the
    /// window-server event travel different paths and may arrive in either order.
    func attribute(usage: Int, waitMs: Double) -> HIDDeviceInfo? {
        guard isListening else { return nil }
        let deadline = Date().addingTimeInterval(waitMs / 1000)
        cond.lock()
        defer { cond.unlock() }
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            if var q = pending[usage] {
                q.removeAll { now - $0.at > 400_000_000 }
                if !q.isEmpty {
                    let stamp = q.removeFirst()
                    pending[usage] = q
                    return stamp.device
                }
                pending[usage] = q
            }
            if !cond.wait(until: deadline) { return nil }
        }
    }
}
