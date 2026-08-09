// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Mux",
    platforms: [.macOS(.v14)],
    targets: [
        // Prebuilt by scripts/fetch-ghosttykit.sh or zig build -Demit-xcframework
        // in a ghostty checkout (see app/README.md).
        .binaryTarget(
            name: "GhosttyKit",
            path: "GhosttyKit/GhosttyKit.xcframework"
        ),
        .executableTarget(
            name: "Mux",
            dependencies: ["GhosttyKit"],
            path: "Sources",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("CoreText"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("IOSurface"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedFramework("Carbon"),
                .linkedLibrary("c++"),
                .linkedLibrary("z"),
            ]
        ),
    ]
)
