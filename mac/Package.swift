// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Satsuma",
    platforms: [.macOS(.v13)],
    targets: [
        // Everything that doesn't need a window: file kinds, wheel contents, converters and tools.
        .target(name: "SatsumaCore", path: "Sources/SatsumaCore"),
        // The menu bar app, the wheel and bubble, settings and dialogs, and the command line test modes.
        .executableTarget(name: "Satsuma", dependencies: ["SatsumaCore"], path: "Sources/Satsuma"),
        .testTarget(name: "SatsumaCoreTests", dependencies: ["SatsumaCore"], path: "Tests/SatsumaCoreTests"),
    ]
)
