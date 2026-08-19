// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacTLM",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "MacTLMCore"),
        .executableTarget(name: "MacTLM", dependencies: ["MacTLMCore"]),
        .testTarget(name: "MacTLMCoreTests", dependencies: ["MacTLMCore"]),
    ]
)
