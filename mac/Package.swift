// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Satsuma",
    platforms: [.macOS(.v13)],
    targets: [
        // libwebp 1.6.0 (BSD) for WebP output, which ImageIO can't write. Swift sees only include/CWebP.h.
        .target(name: "CWebP", path: "Sources/CWebP",
                exclude: ["COPYING", "PATENTS", "AUTHORS", "README.md"],
                cSettings: [
                    .headerSearchPath("."),
                    .define("WEBP_USE_THREAD"),
                    .define("NDEBUG", .when(configuration: .release)),
                ]),
        // Everything that doesn't need a window: file kinds, wheel contents, converters and tools.
        .target(name: "SatsumaCore", dependencies: ["CWebP"], path: "Sources/SatsumaCore"),
        // The menu bar app, the wheel and bubble, settings and dialogs, and the command line test modes.
        .executableTarget(name: "Satsuma", dependencies: ["SatsumaCore"], path: "Sources/Satsuma"),
        .testTarget(name: "SatsumaCoreTests", dependencies: ["SatsumaCore"], path: "Tests/SatsumaCoreTests"),
    ]
)
