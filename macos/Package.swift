// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SonyTrayMac",
    platforms: [.macOS(.v13)], // SMAppService (launch at login) is 13.0+
    products: [
        .library(name: "SonyProtocolKit", targets: ["SonyProtocolKit"]),
        .executable(name: "SonyTrayMac", targets: ["SonyTrayMac"]),
    ],
    targets: [
        // Pure-Swift port of src/SonyProtocol — no platform dependencies, so it stays testable
        // on its own and mirrors the C# core one-for-one.
        .target(name: "SonyProtocolKit"),
        .executableTarget(
            name: "SonyTrayMac",
            dependencies: ["SonyProtocolKit"],
            linkerSettings: [
                .linkedFramework("IOBluetooth"),
                .linkedFramework("AppKit"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        // A plain executable rather than a .testTarget: XCTest.framework ships only with full
        // Xcode, and this port stays buildable with just the Command Line Tools. Run it with
        // `make test` (or `swift run SonyProtocolTests`).
        .executableTarget(name: "SonyProtocolTests", dependencies: ["SonyProtocolKit"]),
    ]
)
