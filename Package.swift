// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacTLM",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "3.0.1"),
    ],
    targets: [
        .target(name: "MacTLMCore"),
        .executableTarget(
            name: "MacTLM",
            dependencies: [
                "MacTLMCore",
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
            ]),
        .testTarget(name: "MacTLMCoreTests", dependencies: ["MacTLMCore"]),
    ]
)
