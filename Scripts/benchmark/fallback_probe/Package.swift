// swift-tools-version: 6.0
import PackageDescription

// Standalone helper for the B1 benchmark harness only. Not part of the shipping package graph:
// it depends on the kit checkout by path so it always renders with the exact commit under test,
// and it exists to answer one question the CLI's `--json` output can't: whether a given Markdown
// document rendered normally or hit the dense-Markdown fallback (see Scripts/benchmark/README.md).
let package = Package(
    name: "FallbackProbe",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(name: "MarsDawnKit", path: "../../..")
    ],
    targets: [
        .executableTarget(
            name: "fallback-probe",
            dependencies: [.product(name: "MarsDawnKit", package: "MarsDawnKit")]
        )
    ]
)
