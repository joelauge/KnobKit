import AppKit
import Foundation
import IOKit
import IOKit.hid
import KnobCore

/// Blinks a keyboard's lights as a "KnobKit has this keyboard" signal.
///
/// Two ways, tried in this order:
///
/// 1. **Backlight**, on keyboards whose lighting channel is known (see `AulaLighting`):
///    the whole board goes white and dark. These are real-time frames, as the vendor's
///    app streams in its music mode. Nothing is stored on the keyboard and its own
///    effect comes back by itself a moment after the last frame.
/// 2. **Indicator lights** on any other keyboard: Caps Lock and whatever else it
///    reports on the standard HID LED page, put back afterwards. A keyboard with no
///    such lights is left alone.
///
/// The keyboard is opened for output only: no key input is read here.
final class LEDFlasher {
    private let queue = DispatchQueue(label: "knobkit.led", qos: .utility)
    private var lastFlash: [String: Date] = [:]
    /// A reconnect can announce several interfaces of one keyboard; flash it once.
    private let minimumGap: TimeInterval = 6

    private static let names: [Int: String] = [
        kHIDUsage_LED_NumLock: "Num Lock", kHIDUsage_LED_CapsLock: "Caps Lock",
        kHIDUsage_LED_ScrollLock: "Scroll Lock", kHIDUsage_LED_Compose: "Compose", kHIDUsage_LED_Kana: "Kana",
    ]

    /// Flashes the lights of the keyboard `device` belongs to.
    func flash(_ device: HIDDeviceInfo, times: Int = 5, force: Bool = false) {
        queue.async { [self] in
            let key = "\(device.vendorID):\(device.productID):\(device.transport):\(device.name)"
            if !force, let last = lastFlash[key], Date().timeIntervalSince(last) < minimumGap { return }
            lastFlash[key] = Date()
            run(device, times: max(times, 1))
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
        if flashBacklight(info, devices, times: times) { return }
        flashIndicators(info, devices, times: times)
    }

    // MARK: Backlight

    /// True when the frames went out. False when this keyboard's lighting channel is
    /// not one we know, so nothing was sent.
    private func flashBacklight(_ info: HIDDeviceInfo, _ devices: Set<IOHIDDevice>, times: Int) -> Bool {
        guard info.vendorID == AulaLighting.vendorID, AulaLighting.productIDs.contains(info.productID) else { return false }
        // The interface that carries the vendor channel: usage page 0xFF02, 20-byte
        // output reports.
        let channel = devices.first { device in
            let pairs = IOHIDDeviceGetProperty(device, kIOHIDDeviceUsagePairsKey as CFString) as? [[String: Any]] ?? []
            let hasPage = pairs.contains { ($0[kIOHIDDeviceUsagePageKey] as? Int) == AulaLighting.usagePage }
            let maxOut = IOHIDDeviceGetProperty(device, kIOHIDMaxOutputReportSizeKey as CFString) as? Int ?? 0
            return hasPage && maxOut >= AulaLighting.packetLength
        }
        guard let channel else { return false }

        func send(_ frame: [UInt8]) -> Bool {
            IOHIDDeviceSetReport(channel, kIOHIDReportTypeOutput, CFIndex(AulaLighting.reportID), frame, frame.count) == kIOReturnSuccess
        }
        let on = AulaLighting.wholeBoard(red: 255, green: 255, blue: 255)
        let off = AulaLighting.wholeBoard(red: 0, green: 0, blue: 0)

        let started = Date()
        var sent = 0, failed = 0
        for _ in 0..<times {
            if send(on) { sent += 1 } else { failed += 1 }
            usleep(160_000)
            if send(off) { sent += 1 } else { failed += 1 }
            usleep(160_000)
        }
        // Nothing to undo: the keyboard returns to its own effect once frames stop.
        let seconds = String(format: "%.1f", Date().timeIntervalSince(started))
        guard sent > 0 else {
            Log.write("lights: \(info.name) refused the backlight frames, trying its indicator lights")
            return false
        }
        Log.write("lights: flashed \(info.name)'s backlight \(times) times in \(seconds) s\(failed == 0 ? "" : ", \(failed) frames failed")")
        return true
    }

    // MARK: Indicator lights

    private func flashIndicators(_ info: HIDDeviceInfo, _ devices: Set<IOHIDDevice>, times: Int) {
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
        // waits for the keyboard. Anything else, or a keyboard that refuses the raw
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
        for _ in 0..<times {
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

        let list = lights.map { Self.names[$0.usage] ?? "light 0x\(String($0.usage, radix: 16))" }.joined(separator: ", ")
        Log.write("lights: flashed \(info.name)'s indicator lights \(times) times in \(seconds) s [\(list)]\(failures == 0 ? "" : ", \(failures) writes failed")")
    }
}
