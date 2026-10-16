// swift-tools-version:5.9
import PackageDescription

// Native macOS version of libre-monitor.
//   LibreMonitorKit  - pure logic, no UI (a port of windows/src/LibreMonitor.Core)
//   LibreMonitorMac  - AppKit + SwiftUI app
// Swift 5 language mode is used on purpose: the code is written to the same rules as the C# version and the
// stricter Swift 6 concurrency checking is not worth fighting here.
let package = Package(
    name: "LibreMonitor",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "LibreMonitorKit", targets: ["LibreMonitorKit"]),
        .executable(name: "LibreMonitorMac", targets: ["LibreMonitorMac"]),
    ],
    targets: [
        .target(name: "LibreMonitorKit"),
        .executableTarget(name: "LibreMonitorMac", dependencies: ["LibreMonitorKit"]),
        .testTarget(name: "LibreMonitorKitTests", dependencies: ["LibreMonitorKit"]),
    ]
)
