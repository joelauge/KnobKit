import AppKit
import ServiceManagement

let arguments = CommandLine.arguments

// `KnobKit --login-item on|off|status`: the same switch as General > Open at login,
// usable from a shell. Must be run from inside the installed app bundle.
if let index = arguments.firstIndex(of: "--login-item"), index + 1 < arguments.count {
    let service = SMAppService.mainApp
    var failure: String?
    do {
        switch arguments[index + 1] {
        case "on": try service.register()
        case "off": try service.unregister()
        default: break
        }
    } catch {
        failure = error.localizedDescription
    }
    let status: String
    switch service.status {
    case .enabled: status = "enabled"
    case .notRegistered: status = "not registered"
    case .requiresApproval: status = "requires approval in System Settings > General > Login Items"
    case .notFound: status = "not found"
    @unknown default: status = "unknown"
    }
    print("login item: \(status)" + (failure.map { " (error: \($0))" } ?? ""))
    exit(failure == nil ? 0 : 1)
}

// `KnobKit --send "cw cw opt+cw press"`: forward simulated knob input to the running
// app (which must have been started with --allow-simulation) and exit.
if let index = arguments.firstIndex(of: "--send"), index + 1 < arguments.count {
    DistributedNotificationCenter.default().postNotificationName(
        simulateNotification, object: arguments[index + 1], userInfo: nil, deliverImmediately: true)
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    exit(0)
}

// One instance only: a second launch just brings the first one's window up.
if let bundleID = Bundle.main.bundleIdentifier {
    let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
    if let existing = others.first {
        existing.activate()
        exit(0)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
