// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "CodMate",
  defaultLocalization: "en",
  platforms: [.macOS(.v13)],
  products: [
    .executable(
      name: "CodMate",
      targets: ["CodMate"]
    ),
    .executable(
      name: "notify",
      targets: ["notify"]
    ),
  ],
  dependencies: [
    // Ghostty GPU-accelerated terminal
    .package(path: "ghostty"),
    // MCP Swift SDK for real MCP client connections
    .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.10.2"),
  ],
  targets: [
    .executableTarget(
      name: "CodMate",
      dependencies: [
        .product(name: "GhosttyKit", package: "ghostty"),
        .product(name: "MCP", package: "swift-sdk"),
      ],
      path: ".",
      exclude: [
        "ghostty",
        "notify",
        "build",
        ".build",
        "scripts",
        "docs",
        "payload",
        "Tests",
        "AGENTS.md",
        "LICENSE",
        "NOTICE",
        "README.md",
        "THIRD-PARTY-NOTICES.md",
        "Makefile",
        "screenshot.png",
        "PrivacyInfo.xcprivacy",
        "assets/Assets.xcassets",
        "assets/Info.plist",
        "assets/CodMate.entitlements",
        "assets/CodMate-Notify.entitlements",
        "Ghostty-header.h",
      ],
      sources: [
        "CodMateApp.swift",
        "models",
        "services",
        "utils",
        "views",
      ]
    ),
    .executableTarget(
      name: "notify",
      path: "notify",
      sources: ["NotifyMain.swift"]
    ),
    .testTarget(
      name: "CodMateTests",
      dependencies: ["CodMate"]
    ),
  ],
  swiftLanguageModes: [.v5]
)
