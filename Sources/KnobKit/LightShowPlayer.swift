import AppKit
import Foundation
import IOKit.hid
import KnobCore

/// Plays a `LightShow` on the keyboard by streaming real-time lighting frames.
///
/// Frames are not stored on the keyboard. When streaming stops, the keyboard goes back
/// to its own lighting effect after a second or two.
final class LightShowPlayer: ObservableObject {
    @Published private(set) var isPlaying = false
    /// Shown under the preview: frame rate while playing, or why it stopped.
    @Published private(set) var status = ""
    /// When playback began, so the on-screen preview can keep in step.
    @Published private(set) var startedAt: Date?

    /// Shortest time between frames: the vendor app's own pace.
    static let frameFloor = 0.046

    private let queue = DispatchQueue(label: "knobkit.lightshow", qos: .userInitiated)
    private let lock = NSLock()
    private var show: LightShow?
    private var token = 0

    /// Swaps in new settings without restarting, so sliders act while it plays.
    func update(_ show: LightShow) {
        lock.lock()
        if self.show != nil { self.show = show }
        lock.unlock()
    }

    func stop() {
        lock.lock()
        token += 1
        show = nil
        lock.unlock()
        isPlaying = false
        startedAt = nil
    }

    func play(_ show: LightShow, on device: HIDDeviceInfo) {
        lock.lock()
        token += 1
        let mine = token
        self.show = show
        lock.unlock()

        let start = Date()
        isPlaying = true
        startedAt = start
        status = "Starting on \(device.name)…"
        Log.write("light show: playing on \(device.name)")

        queue.async { [weak self] in
            var ending = "Stopped."
            KeyboardHID.withDevices(device) { devices in
                guard let channel = KeyboardHID.lightingChannel(device, devices) else {
                    ending = "This keyboard's backlight can't be driven from the Mac."
                    return
                }
                // Over USB (the 2.4G receiver) packets closer together than a few
                // milliseconds get dropped. Bluetooth already spaces every write by tens
                // of milliseconds, so adding a gap there only costs frames.
                let gap: useconds_t = device.transport.lowercased().contains("bluetooth") ? 0 : 5_000
                var last: [[UInt8]] = []
                var lastSent = Date.distantPast
                var failures = 0
                var windowStart = Date(), windowFrames = 0
                var totalFrames = 0, totalPackets = 0
                while let self {
                    self.lock.lock()
                    let current = self.token == mine ? self.show : nil
                    self.lock.unlock()
                    guard let current else { break }

                    let frameStart = Date()
                    let time = frameStart.timeIntervalSince(start)
                    if !current.loop, time > current.duration {
                        ending = "Finished."
                        break
                    }
                    let packets = AulaLighting.perKey(current.frame(at: time))
                    // An unchanged picture is only re-sent often enough to stop the
                    // keyboard falling back to its own effect.
                    if packets == last, frameStart.timeIntervalSince(lastSent) < 0.5 {
                        usleep(20_000)
                        continue
                    }
                    var sent = true
                    for (index, packet) in packets.enumerated() {
                        if index > 0, gap > 0 { usleep(gap) }
                        sent = KeyboardHID.send(packet, on: channel) && sent
                    }
                    if sent {
                        failures = 0
                        last = packets
                        lastSent = Date()
                        windowFrames += 1
                        totalFrames += 1
                        totalPackets += packets.count
                    } else {
                        failures += 1
                        if failures >= 6 {
                            ending = "The keyboard stopped answering. Is it still connected?"
                            break
                        }
                        usleep(150_000)
                    }

                    // Never faster than the vendor's own app streams (about 21 frames a
                    // second). The keyboard scans its keys and paints its lights on the
                    // same small processor: frames arriving faster are reported to make
                    // it drop or double keystrokes, and eventually stop answering until
                    // it is replugged.
                    let spent = Date().timeIntervalSince(frameStart)
                    if spent < Self.frameFloor { usleep(useconds_t((Self.frameFloor - spent) * 1_000_000)) }

                    let window = Date().timeIntervalSince(windowStart)
                    if window >= 1 {
                        let fps = Double(windowFrames) / window
                        let text = String(format: "Playing on %@ at %.0f frames a second", device.name, fps)
                        windowStart = Date()
                        windowFrames = 0
                        DispatchQueue.main.async { [weak self] in
                            guard let self, self.isPlaying else { return }
                            if self.status != text { self.status = text }
                        }
                    }
                }
                let seconds = Date().timeIntervalSince(start)
                Log.write(String(format: "light show: %d frames (%d packets) in %.1f s, %.1f frames a second",
                                 totalFrames, totalPackets, seconds, Double(totalFrames) / max(seconds, 0.001)))
            }
            Log.write("light show: \(ending)")
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let stillMine = self.token == mine
                if stillMine { self.show = nil }
                self.lock.unlock()
                guard stillMine else { return }
                self.isPlaying = false
                self.startedAt = nil
                self.status = ending
            }
        }
    }
}

/// Turning what the person picked into pixels.
enum LightShowSource {
    /// Image pixels per key width that images are loaded at: enough for smooth edges
    /// without holding a large picture in memory.
    static let pixelsPerKey = 8

    /// Loads an image file, scaled so `lines` bands of six key rows cover its height,
    /// composited on black.
    static func bitmap(imageAt url: URL, lines: Int) -> Bitmap? {
        guard let image = NSImage(contentsOf: url),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              cg.width > 0, cg.height > 0 else { return nil }
        let height = F75Board.rows * max(lines, 1) * pixelsPerKey
        let width = min(max(Int((Double(cg.width) / Double(cg.height) * Double(height)).rounded()), 1), 20_000)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        let bytes = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var pixels = [UInt8](repeating: 0, count: width * height * 3)
        // CGContext rows run top to bottom in memory, as Bitmap wants them.
        for i in 0..<(width * height) {
            pixels[i * 3] = bytes[i * 4]
            pixels[i * 3 + 1] = bytes[i * 4 + 1]
            pixels[i * 3 + 2] = bytes[i * 4 + 2]
        }
        return Bitmap(width: width, height: height, pixels: pixels)
    }

    static func rgb(hex: String) -> (UInt8, UInt8, UInt8) {
        let value = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "# ")), radix: 16) ?? 0xFFFFFF
        return (UInt8((value >> 16) & 0xff), UInt8((value >> 8) & 0xff), UInt8(value & 0xff))
    }

    /// The show for the saved settings, or nil when an image is chosen but can't be read.
    static func show(for settings: LightShowSettings) -> LightShow? {
        let bitmap: Bitmap
        switch settings.source {
        case .text:
            let (r, g, b) = rgb(hex: settings.color)
            bitmap = PixelFont.render(settings.text.isEmpty ? " " : settings.text, red: r, green: g, blue: b)
        case .image:
            guard !settings.imagePath.isEmpty,
                  let loaded = self.bitmap(imageAt: URL(fileURLWithPath: settings.imagePath), lines: settings.lines) else { return nil }
            bitmap = loaded
        }
        var show = LightShow(bitmap: bitmap)
        show.lines = settings.source == .image ? max(settings.lines, 1) : 1
        show.speed = settings.speed
        show.brightness = settings.brightness
        // Text needs only an in-between step for soft edges; pictures get more
        // steps, which the frame budget trims when a frame is busy.
        show.levels = settings.softEdges ? (settings.source == .image ? 5 : 3) : 2
        show.loop = settings.loop
        show.upright = settings.upright
        show.wholeKeySteps = settings.wholeKeySteps
        return show
    }
}
