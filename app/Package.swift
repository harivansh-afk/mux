// swift-tools-version: 5.10
import PackageDescription

// `Tiling` is the split-tree model (Foundation only) and `Agents` reads
// coding agents' terminal titles (stdlib only). Neither touches AppKit or
// GhosttyKit, so they and their tests build on any platform; the app
// target links a prebuilt xcframework and is declared only on macOS.
var targets: [Target] = [
    .target(name: "Tiling"),
    .target(name: "Agents"),
    .testTarget(name: "AgentsTests", dependencies: ["Agents"]),
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
            dependencies: ["GhosttyKit", "Tiling", "Agents"],
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
        // SplitTreeTests need only Tiling; SnapshotTests need the app, so the
        // one test target lives on the macOS side.
        .testTarget(name: "MuxTests", dependencies: ["Mux", "Tiling"]),
    ]
#endif

let package = Package(
    name: "Mux",
    platforms: [.macOS(.v14)],
    targets: targets
)
