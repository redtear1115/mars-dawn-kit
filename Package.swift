// swift-tools-version: 6.2
import PackageDescription

// Platform-neutral core shared by the macOS editor and the future iOS viewer (v3),
// plus macOS-only PDF export and the `marsdawn` command-line tool built on it.
let package = Package(
    name: "MarsDawnKit",
    defaultLocalization: "en",
    platforms: [.macOS(.v15), .iOS(.v17)],
    products: [
        .library(name: "MarsDawnKit", targets: ["MarsDawnKit"]),
        .library(name: "MarsDawnExport", targets: ["MarsDawnExport"]),
        .executable(name: "marsdawn", targets: ["marsdawn"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.8.0"),
        // The same cmark-gfm that swift-markdown parses with, for the nesting-depth pre-scan.
        .package(url: "https://github.com/swiftlang/swift-cmark.git", from: "0.8.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        // Platform-neutral theme data: schema, style-option vocabulary and the CSS generator.
        // Foundation only -- no WebKit/AppKit -- so it (and a future validator, #125) can build on
        // Linux for the website's simulator/CI.
        .target(
            name: "MarsDawnThemes",
            resources: [.copy("Resources/Themes"), .process("Resources/ThemeStyles.json")]
        ),
        .target(
            name: "MarsDawnKit",
            dependencies: [
                "MarsDawnThemes",
                .product(name: "Markdown", package: "swift-markdown"),
                .product(name: "cmark-gfm", package: "swift-cmark"),
                .product(name: "cmark-gfm-extensions", package: "swift-cmark"),
            ],
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
        .testTarget(
            name: "MarsDawnKitTests",
            dependencies: [
                "MarsDawnKit",
                "MarsDawnThemes",
                .product(name: "cmark-gfm", package: "swift-cmark"),
                .product(name: "cmark-gfm-extensions", package: "swift-cmark"),
            ]
        ),
        .testTarget(
            name: "MarsDawnExportTests",
            dependencies: ["MarsDawnExport", "MarsDawnKit"],
            resources: [.copy("MermaidCorpus"), .copy("Corpus")]
        ),
        .testTarget(name: "MarsDawnCLITests", dependencies: ["marsdawn"]),
        // The validator's own tests (kit #125): Foundation only, like MarsDawnThemes itself, so a
        // runner without WebKit could run them. The fixtures are one valid theme per case and one
        // invalid theme per rule.
        .testTarget(
            name: "MarsDawnThemesTests",
            dependencies: ["MarsDawnThemes"],
            resources: [.copy("ThemeFixtures")]
        ),
    ]
)
