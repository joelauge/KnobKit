// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "KnobKit",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure logic: config model, gesture recognition, binding resolution. No UI, fully testable.
        .target(name: "KnobCore", path: "Sources/KnobCore"),
        // The menu bar app: event capture, actions, HUD, configurator.
        .executableTarget(name: "KnobKit", dependencies: ["KnobCore"], path: "Sources/KnobKit"),
        .testTarget(name: "KnobCoreTests", dependencies: ["KnobCore"], path: "Tests/KnobCoreTests"),
    ]
)
