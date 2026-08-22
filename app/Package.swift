// swift-tools-version: 5.10
import PackageDescription

// `Tiling` is the split-tree model: Foundation only, no AppKit, no
// GhosttyKit. Keeping it a separate target is what lets `swift test` run on
// any platform - the app target links a prebuilt xcframework and only
// builds on macOS, so it is declared only there.
var targets: [Target] = [
    .target(name: "Tiling"),
    .testTarget(name: "MuxTests", dependencies: ["Tiling"]),
]

#if os(macOS)
    targets += [
        // Prebuilt by scripts/fetch-ghosttykit.sh or zig build -Demit-xcframework
        // in a ghostty checkout (see app/README.md).
        .binaryTarget(
            name: "GhosttyKit",
            path: "GhosttyKit/GhosttyKit.xcframework"
        ),
        .executableTarget(
            name: "Mux",
            dependencies: ["GhosttyKit", "Tiling"],
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
#endif

let package = Package(
    name: "Mux",
    platforms: [.macOS(.v14)],
    targets: targets
)
