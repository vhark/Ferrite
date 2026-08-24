// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Ferrite",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "3.0.1"),
    ],
    targets: [
        .target(name: "FerriteCore"),
        .executableTarget(
            name: "Ferrite",
            dependencies: [
                "FerriteCore",
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
            ]),
        .testTarget(name: "FerriteCoreTests", dependencies: ["FerriteCore"]),
    ]
)
