import AppKit
import Foundation
import IOKit
import IOKit.hid

/// Blinks a keyboard's indicator lights (Caps Lock and any others it reports) as a
/// "KnobKit has this keyboard" signal.
///
/// It uses the standard HID LED page, so it works on any keyboard that has such lights
/// and does nothing on one that has none. RGB backlighting is vendor-specific and is
/// not touched. The keyboard is opened for output only: no key input is read here.
final class LEDFlasher {
    private let queue = DispatchQueue(label: "knobkit.led", qos: .utility)
    private var lastFlash: [String: Date] = [:]
    /// A reconnect can announce several interfaces of one keyboard; flash it once.
    private let minimumGap: TimeInterval = 6

    private static let names: [Int: String] = [
        kHIDUsage_LED_NumLock: "Num Lock", kHIDUsage_LED_CapsLock: "Caps Lock",
        kHIDUsage_LED_ScrollLock: "Scroll Lock", kHIDUsage_LED_Compose: "Compose", kHIDUsage_LED_Kana: "Kana",
    ]

    /// Flashes every indicator light on the keyboard `device` belongs to.
    func flash(_ device: HIDDeviceInfo, times: Int = 5, force: Bool = false) {
        queue.async { [self] in
            let key = "\(device.vendorID):\(device.productID):\(device.transport):\(device.name)"
            if !force, let last = lastFlash[key], Date().timeIntervalSince(last) < minimumGap { return }
            lastFlash[key] = Date()
            run(device, times: times)
        }
    }

    private func run(_ info: HIDDeviceInfo, times: Int) {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        // The lights can sit on a different interface of the same keyboard than the knob
        // does (USB keyboards often split them), so match the product, not the interface.
        // Devices that report no ids (0:0) are matched by name instead.
        var match: [String: Any] = [:]
        if info.vendorID != 0 || info.productID != 0 {
            match[kIOHIDVendorIDKey] = info.vendorID
            match[kIOHIDProductIDKey] = info.productID
        } else {
            match[kIOHIDProductKey] = info.name
        }
        IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)
        let opened = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        defer { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }
        guard opened == kIOReturnSuccess, let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            Log.write("lights: could not open \(info.name) (0x\(String(opened, radix: 16)))")
            return
        }

        // Every output element on the LED page, across the keyboard's interfaces.
        var lights: [(device: IOHIDDevice, element: IOHIDElement, usage: Int, before: Int)] = []
        let ledPage = [kIOHIDElementUsagePageKey: kHIDPage_LEDs] as CFDictionary
        for device in devices {
            guard let elements = IOHIDDeviceCopyMatchingElements(device, ledPage, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement] else { continue }
            for element in elements where IOHIDElementGetType(element) == kIOHIDElementTypeOutput {
                var before = 0
                let current = UnsafeMutablePointer<Unmanaged<IOHIDValue>>.allocate(capacity: 1)
                if IOHIDDeviceGetValue(device, element, current) == kIOReturnSuccess {
                    before = IOHIDValueGetIntegerValue(current.pointee.takeUnretainedValue())
                }
                current.deallocate()
                lights.append((device, element, Int(IOHIDElementGetUsage(element)), before))
            }
        }
        guard !lights.isEmpty else {
            Log.write("lights: \(info.name) reports no indicator lights")
            return
        }

        // The standard lights (Num, Caps, Scroll, Compose, Kana) are five consecutive
        // bits of one small output report. Writing that report directly changes them
        // together in one write per step, which matters over Bluetooth where each write
        // takes tens of milliseconds. Anything else, or a keyboard that refuses the raw
        // report, is written light by light.
        let standard = kHIDUsage_LED_NumLock...kHIDUsage_LED_Kana
        let byDevice = Dictionary(grouping: lights, by: { $0.device })
        var useRaw = Dictionary(uniqueKeysWithValues: byDevice.map { ($0.key, $0.value.contains { standard.contains($0.usage) }) })

        func write(_ level: (_ usage: Int, _ before: Int) -> Int) -> Int {
            var failed = 0
            for (device, group) in byDevice {
                var rest = group
                if useRaw[device] == true {
                    let regular = group.filter { standard.contains($0.usage) }
                    var bits: UInt8 = 0
                    for light in regular where level(light.usage, light.before) != 0 { bits |= 1 << UInt8(light.usage - 1) }
                    let reportID = Int(IOHIDElementGetReportID(regular[0].element))
                    let bytes: [UInt8] = reportID == 0 ? [bits] : [UInt8(truncatingIfNeeded: reportID), bits]
                    if IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(reportID), bytes, bytes.count) == kIOReturnSuccess {
                        rest = group.filter { !standard.contains($0.usage) }
                    } else {
                        useRaw[device] = false
                    }
                }
                for light in rest {
                    let value = IOHIDValueCreateWithIntegerValue(kCFAllocatorDefault, light.element, mach_absolute_time(),
                                                                 level(light.usage, light.before))
                    if IOHIDDeviceSetValue(device, light.element, value) != kIOReturnSuccess { failed += 1 }
                }
            }
            return failed
        }

        let started = Date()
        var failures = 0
        for _ in 0..<max(times, 1) {
            failures += write { _, _ in 1 }
            usleep(110_000)
            failures += write { _, _ in 0 }
            usleep(110_000)
        }
        // Put each light back: Caps Lock to what the Mac says it is now, the rest to
        // what they were.
        let capsOn = CGEventSource.flagsState(.combinedSessionState).contains(.maskAlphaShift)
        failures += write { usage, before in usage == kHIDUsage_LED_CapsLock ? (capsOn ? 1 : 0) : before }
        let seconds = String(format: "%.1f", Date().timeIntervalSince(started))
        let how = useRaw.values.contains(true) ? "one report per step" : "light by light"

        let list = lights.map { Self.names[$0.usage] ?? "light 0x\(String($0.usage, radix: 16))" }.joined(separator: ", ")
        Log.write("lights: flashed \(info.name) \(times) times in \(seconds) s, \(how) [\(list)]\(failures == 0 ? "" : ", \(failures) writes failed")")
    }
}
