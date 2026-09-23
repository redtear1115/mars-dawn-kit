import Foundation
import Testing
@testable import MarsDawnKit

/// The kit's own logging subsystems, signpost subsystems and dispatch queue labels must never be
/// the app's bundle ID (`dev.southern-light.marsdawn`) — only the CLI's app-bundle-id lookup gets
/// to use that string, and content-rule identifier prefixes (`HTMLContentRules`,
/// `PreviewWebSupport.identifierPrefix`) are a different, deliberately unrenamed namespace. Every
/// `Logger`/`OSSignposter` subsystem and every `DispatchQueue` label in `Sources/` must instead
/// start with the package's own `dev.southern-light.marsdawn-kit` (app #12). This scans the real
/// source files on disk, not a copy, so a regression in any of them is caught here directly.
struct LogSubsystemNamingTests {
    nonisolated private static let sourcesRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources")

    private static func swiftFiles() throws -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: sourcesRoot, includingPropertiesForKeys: nil) else {
            throw CocoaError(.fileReadUnknown)
        }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    /// The forbidden patterns: the app's bundle ID used as a Logger/OSSignposter subsystem, or as
    /// (the start of) a DispatchQueue label. A queue label of the app's bundle ID with more text
    /// after it, e.g. `"dev.southern-light.marsdawn.assets"`, is still forbidden: the dot after
    /// the bare bundle ID is what -kit's own labels always append, so it's still the wrong base.
    nonisolated private static let forbidden = [
        #"Logger(subsystem: "dev.southern-light.marsdawn""#,
        #"OSSignposter(subsystem: "dev.southern-light.marsdawn""#,
        #"label: "dev.southern-light.marsdawn."#,
    ]

    @Test func noKitSourceLogsUnderTheAppsBundleID() throws {
        var offenders: [String] = []
        for file in try Self.swiftFiles() {
            let text = try String(contentsOf: file, encoding: .utf8)
            for pattern in Self.forbidden where text.contains(pattern) {
                // A match under the package's own "-kit" subsystem is fine; only flag a match
                // that isn't immediately followed by "-kit".
                for line in text.components(separatedBy: .newlines) where line.contains(pattern) {
                    if !line.contains("dev.southern-light.marsdawn-kit") {
                        offenders.append("\(file.lastPathComponent): \(line.trimmingCharacters(in: .whitespaces))")
                    }
                }
            }
        }
        #expect(offenders.isEmpty, "kit source logs under the app's bundle ID: \(offenders)")
    }

    /// Positive fixture: the scan actually finds real files and inspects real content, so an
    /// empty `offenders` above isn't just an empty search.
    @Test func theScanCoversTheRealSourceTree() throws {
        let files = try Self.swiftFiles()
        #expect(files.count >= 10, "positive fixture: expected many Sources files, found \(files.count)")
        #expect(files.contains { $0.lastPathComponent == "DocumentExporter.swift" })
        let exporterText = try String(
            contentsOf: files.first { $0.lastPathComponent == "DocumentExporter.swift" }!,
            encoding: .utf8
        )
        #expect(exporterText.contains("dev.southern-light.marsdawn-kit"), "control: the renamed subsystem should be present")
    }
}
