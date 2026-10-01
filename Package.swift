// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CIStatus",
    platforms: [.macOS(.v13)],
    targets: [
        // All the logic lives here so it can be unit tested without an app bundle.
        .target(name: "CIStatusKit"),
        .executableTarget(
            name: "CIStatus",
            dependencies: ["CIStatusKit"],
            path: "Sources/CIStatus",
            resources: [.copy("Resources/config.example.json")]
        ),
        .testTarget(name: "CIStatusKitTests", dependencies: ["CIStatusKit"], path: "Tests/CIStatusTests"),
        // Verification harnesses, not part of the app: `probe` polls a config
        // with the real providers, `probe3` classifies the menu bar icon.
        .executableTarget(name: "probe", dependencies: ["CIStatusKit"], path: "Sources/probe"),
        .executableTarget(name: "probe3", dependencies: ["CIStatusKit"], path: "Sources/probe3")
    ]
)
