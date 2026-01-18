// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ghostty",
    platforms: [.macOS(.v13)],
    products: [
        .library(
            name: "GhosttyKit",
            targets: ["GhosttyKit"]
        ),
    ],
    targets: [
        // C library target for libghostty
        .systemLibrary(
            name: "CGhostty",
            path: "Sources/CGhostty",
            pkgConfig: nil
        ),

        // Swift wrapper target
        .target(
            name: "GhosttyKit",
            dependencies: ["CGhostty"],
            path: "Sources/GhosttyKit",
            resources: [
                .process("../../Resources/themes"),
            ],
            linkerSettings: [
                .linkedLibrary("ghostty"),
                .unsafeFlags([
                    "-L", "/Volumes/External/GitHub/CodMate/ghostty/Vendor/lib",
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                    // Enable dead code stripping to remove unused symbols from static library
                    "-Xlinker", "-dead_strip",
                ]),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("IOSurface"),
                .linkedFramework("Carbon"),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
