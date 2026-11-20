import Foundation

/// Plain-text log at ~/Library/Logs/KnobKit/knobkit.log. Used for diagnosing how the
/// knob's events arrive on a given connection (Bluetooth, 2.4G, USB).
enum Log {
    static let url: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/KnobKit", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("knobkit.log")
    }()

    private static let queue = DispatchQueue(label: "knobkit.log")
    private static var handle: FileHandle?
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func write(_ message: @autoclosure () -> String) {
        let line = message()
        let stamp = Date()
        queue.async {
            if handle == nil {
                let fm = FileManager.default
                if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 2_000_000 {
                    try? fm.removeItem(at: url)
                }
                if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
                handle = try? FileHandle(forWritingTo: url)
                _ = try? handle?.seekToEnd()
            }
            if let data = "\(formatter.string(from: stamp)) \(line)\n".data(using: .utf8) {
                try? handle?.write(contentsOf: data)
            }
        }
    }
}
