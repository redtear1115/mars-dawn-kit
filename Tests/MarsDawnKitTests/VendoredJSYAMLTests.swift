import CryptoKit
import Foundation
import Testing
@testable import MarsDawnKit

/// The vendored js-yaml is exactly what `LICENSE-js-yaml.txt` says it is (kit #128, F15), and only
/// the JSON and YAML page loads it.
///
/// The browser build has no version banner, so the version lives in the record (taken from the
/// tarball's package.json when it was vendored) and here. A file swapped without the record being
/// redone fails the digest; redoing both is a deliberate act with a commit behind it.
struct VendoredJSYAMLTests {
    static let version = "5.5.0"

    static var previewURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MarsDawnKit/Resources/Preview")
    }

    static var vendorURL: URL { previewURL.appendingPathComponent("vendor") }

    static func record() throws -> String {
        try String(contentsOf: vendorURL.appendingPathComponent("LICENSE-js-yaml.txt"), encoding: .utf8)
    }

    static func recordedDigests() throws -> [(path: String, digest: String)] {
        try record().split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count == 2, parts[0].count == 64, parts[0].allSatisfy(\.isHexDigit), parts[1].hasSuffix(".js") else { return nil }
            return (String(parts[1]), String(parts[0]))
        }
    }

    @Test func theVendoredFileMatchesItsRecordedDigest() throws {
        let recorded = try Self.recordedDigests()
        #expect(recorded.map(\.path) == ["js-yaml.umd.min.js"])
        for (path, digest) in recorded {
            let data = try Data(contentsOf: Self.vendorURL.appendingPathComponent(path))
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            #expect(actual == digest, "\(path) does not match the digest in LICENSE-js-yaml.txt")
        }
    }

    /// The version, from the record (the tarball's package.json) and the NOTICE entry.
    @Test func theRecordAndNoticeNameTheVersion() throws {
        let record = try Self.record()
        #expect(record.hasPrefix("js-yaml \(Self.version)\n"))
        #expect(record.contains("package.json \"version\": \"\(Self.version)\""))
        #expect(record.contains("https://registry.npmjs.org/js-yaml/-/js-yaml-\(Self.version).tgz"))
        #expect(record.contains("sha512-"))
        #expect(record.contains("(The MIT License)"))
        let notice = try String(contentsOf: Self.previewURL.appendingPathComponent("../../../../NOTICE").standardizedFileURL, encoding: .utf8)
        #expect(notice.contains("- js-yaml \(Self.version)\n"))
        #expect(notice.contains("Resources/Preview/vendor/LICENSE-js-yaml.txt"))
    }

    /// Nothing in the build evaluates code or loads modules, which the page's CSP would refuse;
    /// and the two messages data.js tells the limits apart by are there, verbatim.
    @Test func theBuildEvaluatesNothingAndKeepsTheLimitMessages() throws {
        let source = try String(contentsOf: Self.vendorURL.appendingPathComponent("js-yaml.umd.min.js"), encoding: .utf8)
        for forbidden in ["eval(", "Function(", "import(", "importScripts", "require("] {
            #expect(!source.contains(forbidden), "js-yaml.umd.min.js contains \(forbidden)")
        }
        // Positive fixture: the instrument reads the real build.
        #expect(source.contains("e.parseEvents=") && source.contains("e.constructFromEvents="))
        for message in ["nesting exceeded maxDepth", "aliases exceeded maxAliases"] {
            #expect(source.contains(message), "the build no longer says \(message); data.js matches on it")
        }
        let page = try String(contentsOf: Self.previewURL.appendingPathComponent("data.js"), encoding: .utf8)
        #expect(page.contains("\"nesting exceeded maxDepth\"") && page.contains("\"aliases exceeded maxAliases\""))
    }

    /// Only data.html loads it, from the vendor folder; the Markdown page never does.
    @Test func onlyTheDataPageLoadsIt() throws {
        let data = try String(contentsOf: Self.previewURL.appendingPathComponent("data.html"), encoding: .utf8)
        let index = try String(contentsOf: Self.previewURL.appendingPathComponent("index.html"), encoding: .utf8)
        #expect(data.contains(#"<script src="vendor/js-yaml.umd.min.js"></script>"#))
        #expect(!index.contains("js-yaml"))
        #expect(!data.contains("cdn"))
    }
}
