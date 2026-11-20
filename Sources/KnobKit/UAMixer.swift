import Foundation
import KnobCore
import Network

/// Client for the Universal Audio mixer engine's local control port (TCP 4710, the same
/// channel UA Console uses). Apollo interfaces have no macOS volume control, so this is
/// how the knob reaches the monitor output level, mute, dim and mono.
///
/// Wire format: NUL-terminated text commands (`get <path>`, `subscribe <path>`,
/// `set <path>/value/ <value>`), NUL-terminated JSON replies (`{"path": …, "data": …}`).
/// The protocol is not documented by UA; if a UAD software update changes it, the
/// actions report "UA mixer not reachable" and nothing else is affected.
final class UAMixer {
    static let shared = UAMixer()
    static let port: UInt16 = 4710

    private let queue = DispatchQueue(label: "knobkit.uamixer", qos: .userInteractive)
    private var connection: NWConnection?
    private var buffer = Data()

    /// e.g. "/devices/0/outputs/18", the output that carries CRMonitorLevel.
    private var monitorPath: String?
    private var level: Double?
    private var range: ClosedRange<Double> = -96...0
    private var switches: [String: Bool] = [:]
    /// When we last wrote the level. Echoes of our own writes arrive a moment later and
    /// must not overwrite a newer local value while the knob is still turning.
    private var lastWrite = DispatchTime(uptimeNanoseconds: 0)

    private var discovering = false
    private var waiting: [() -> Void] = []
    private var deadline: DispatchWorkItem?

    private init() {}

    // MARK: Public API (callable from any thread; completions run on the main queue)

    /// Changes the monitor level by `delta` dB. Increases stop at `ceiling`; a level that
    /// is already above the ceiling (set on the hardware) is never pulled down by this.
    /// Completion receives the resulting level and the device's range, or nil if the
    /// mixer could not be reached.
    func adjust(byDB delta: Double, ceiling: Double, completion: @escaping (Double?, ClosedRange<Double>) -> Void) {
        queue.async {
            self.whenReady {
                guard let path = self.monitorPath, let current = self.level else {
                    DispatchQueue.main.async { completion(nil, -96...0) }
                    return
                }
                let next = MonitorLevel.next(current: current, delta: delta, ceiling: ceiling, range: self.range)
                if next != current {
                    self.send("set \(path)/CRMonitorLevel/value/ \(next)")
                    self.level = next
                    self.lastWrite = .now()
                }
                let range = self.range
                DispatchQueue.main.async { completion(next, range) }
            }
        }
    }

    /// Flips Mute, DimOn or MixToMono on the monitor output. Completion receives the new
    /// state, or nil if the mixer could not be reached.
    func toggle(_ property: String, completion: @escaping (Bool?) -> Void) {
        queue.async {
            self.whenReady {
                guard let path = self.monitorPath, let current = self.switches[property] else {
                    DispatchQueue.main.async { completion(nil) }
                    return
                }
                let next = !current
                self.send("set \(path)/\(property)/value/ \(next ? "true" : "false")")
                self.switches[property] = next
                DispatchQueue.main.async { completion(next) }
            }
        }
    }

    /// Quick synchronous check that something is listening on the mixer port.
    static func isReachable(timeout: Double = 0.2) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if result == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&pfd, 1, Int32(timeout * 1000)) > 0 else { return false }
        var error: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length)
        return error == 0
    }

    // MARK: Connection and discovery (everything below runs on `queue`)

    /// Runs `work` once the monitor output is known, connecting first if needed. If the
    /// mixer does not answer within the deadline, `work` still runs and finds no path.
    private func whenReady(_ work: @escaping () -> Void) {
        if monitorPath != nil, connection != nil {
            work()
            return
        }
        waiting.append(work)
        guard !discovering else { return }
        discovering = true
        connect()
        let item = DispatchWorkItem { [weak self] in
            Log.write("UA mixer: no answer on port \(Self.port)")
            self?.finishDiscovery()
        }
        deadline = item
        queue.asyncAfter(deadline: .now() + 1.5, execute: item)
    }

    private func finishDiscovery() {
        deadline?.cancel()
        deadline = nil
        discovering = false
        let work = waiting
        waiting.removeAll()
        work.forEach { $0() }
    }

    private func connect() {
        connection?.cancel()
        reset()
        let c = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.port)!, using: .tcp)
        connection = c
        c.stateUpdateHandler = { [weak self] state in
            guard let self, self.connection === c else { return }
            switch state {
            case .ready:
                self.send("get /devices")
                self.receive(on: c)
            case .failed, .cancelled, .waiting:
                // .waiting means the connection was refused: the mixer engine is not running.
                self.lost(c)
            default:
                break
            }
        }
        c.start(queue: queue)
    }

    private func reset() {
        buffer.removeAll()
        monitorPath = nil
        level = nil
        switches = [:]
    }

    private func lost(_ c: NWConnection) {
        guard connection === c else { return }
        connection = nil
        c.cancel()
        reset()
        if discovering { finishDiscovery() }
    }

    private func send(_ command: String) {
        guard let c = connection else { return }
        var data = Data(command.utf8)
        data.append(0)
        c.send(content: data, completion: .contentProcessed { _ in })
    }

    private func receive(on c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self, self.connection === c else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.drain()
            }
            if isComplete || error != nil {
                self.lost(c)
            } else {
                self.receive(on: c)
            }
        }
    }

    private func drain() {
        while let end = buffer.firstIndex(of: 0) {
            let message = Data(buffer[buffer.startIndex..<end])
            buffer.removeSubrange(buffer.startIndex...end)
            guard !message.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: message) as? [String: Any]
            else { continue }
            handle(object)
        }
    }

    private func children(_ data: Any?) -> [String] {
        let keys = ((data as? [String: Any])?["children"] as? [String: Any])?.keys.map { String($0) } ?? []
        return keys.sorted { (Int($0) ?? 0) < (Int($1) ?? 0) }
    }

    /// A reply's value: either the bare value (paths ending in /value) or a property object.
    private func value(_ data: Any?) -> Any? {
        if let object = data as? [String: Any] { return object["value"] }
        return data
    }

    private func handle(_ message: [String: Any]) {
        guard let path = message["path"] as? String, message["error"] == nil else { return }
        let data = message["data"]
        let parts = path.split(separator: "/").map(String.init)

        // Walk devices -> outputs -> each output until the one with a monitor level turns up.
        if path == "/devices" {
            for id in children(data) { send("get /devices/\(id)/outputs") }
            return
        }
        if parts.count == 3, parts[0] == "devices", parts[2] == "outputs" {
            for id in children(data) { send("get \(path)/\(id)") }
            return
        }
        if parts.count == 4, parts[0] == "devices", parts[2] == "outputs" {
            guard monitorPath == nil,
                  let properties = (data as? [String: Any])?["properties"] as? [String: Any],
                  let monitor = properties["CRMonitorLevel"] as? [String: Any],
                  let current = (monitor["value"] as? NSNumber)?.doubleValue
            else { return }
            monitorPath = path
            level = current
            let low = (monitor["min"] as? NSNumber)?.doubleValue ?? -96
            let high = (monitor["max"] as? NSNumber)?.doubleValue ?? 0
            range = low...max(high, low)
            for key in ["Mute", "DimOn", "MixToMono"] {
                if let on = (properties[key] as? [String: Any])?["value"] as? Bool { switches[key] = on }
            }
            // Stay in sync with changes made on the hardware or in UA Console.
            for key in ["CRMonitorLevel", "Mute", "DimOn", "MixToMono"] { send("subscribe \(path)/\(key)") }
            Log.write("UA mixer: monitor output at \(path), level \(current) dB")
            finishDiscovery()
            return
        }

        // Subscription updates for the monitor output.
        guard let monitorPath, path.hasPrefix(monitorPath + "/"),
              let property = path.dropFirst(monitorPath.count + 1).split(separator: "/").first
        else { return }
        if property == "CRMonitorLevel" {
            let sinceWrite = DispatchTime.now().uptimeNanoseconds &- lastWrite.uptimeNanoseconds
            if sinceWrite > 250_000_000, let v = (value(data) as? NSNumber)?.doubleValue { level = v }
        } else if let on = value(data) as? Bool {
            switches[String(property)] = on
        }
    }
}
