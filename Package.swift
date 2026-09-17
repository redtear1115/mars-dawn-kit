// swift-tools-version: 6.2
import PackageDescription

// Platform-neutral core shared by the macOS editor and the future iOS viewer (v3),
// plus macOS-only PDF export and the `marsdawn` command-line tool built on it.
let package = Package(
    name: "MarsDawnKit",
    defaultLocalization: "en",
    platforms: [.macOS(.v26), .iOS(.v17)],
    products: [
        .library(name: "MarsDawnKit", targets: ["MarsDawnKit"]),
        .library(name: "MarsDawnExport", targets: ["MarsDawnExport"]),
        .executable(name: "marsdawn", targets: ["marsdawn"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.8.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "MarsDawnKit",
            dependencies: [.product(name: "Markdown", package: "swift-markdown")],
            resources: [.copy("Resources/Preview"), .process("Resources/Localization")]
        ),
        // macOS only: every source is wrapped in `#if os(macOS)`.
        .target(name: "MarsDawnExport", dependencies: ["MarsDawnKit"]),
        .executableTarget(
            name: "marsdawn",
            dependencies: [
                "MarsDawnKit",
                "MarsDawnExport",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "MarsDawnKitTests", dependencies: ["MarsDawnKit"]),
        .testTarget(name: "MarsDawnExportTests", dependencies: ["MarsDawnExport", "MarsDawnKit"]),
        .testTarget(name: "MarsDawnCLITests", dependencies: ["marsdawn"]),
    ]
)
