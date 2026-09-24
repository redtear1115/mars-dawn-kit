import CryptoKit
import Foundation
import Testing

/// The vendored highlight.js is exactly what `LICENSE-highlightjs.txt` says it is (kit #90).
///
/// The record names the version, the package the file came from and the SHA-256 of the file,
/// the same way `LICENSE-katex.txt` and `LICENSE-mermaid.txt` do. Swapping the file without
/// redoing the record fails here.
struct VendoredHighlightJSTests {
    static var vendorURL: URL { VendoredKatexTests.vendorURL }

    static func record() throws -> String {
        try String(contentsOf: vendorURL.appendingPathComponent("LICENSE-highlightjs.txt"), encoding: .utf8)
    }

    @Test func theBundleMatchesItsRecordedDigest() throws {
        let record = try Self.record()
        let digests = record.split(separator: "\n").compactMap { line -> (String, String)? in
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count == 2, parts[0].count == 64, parts[0].allSatisfy(\.isHexDigit) else { return nil }
            return (String(parts[1]), String(parts[0]))
        }
        #expect(digests.map(\.0) == ["highlight.min.js"], "the record lists exactly the one vendored file")
        for (path, digest) in digests {
            let data = try Data(contentsOf: Self.vendorURL.appendingPathComponent(path))
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            #expect(actual == digest, "\(path) does not match the digest in LICENSE-highlightjs.txt")
        }
    }

    /// The version the record names is the one the bundle reports about itself, in its banner
    /// and in `hljs.versionString`.
    @Test func theBundleReportsTheRecordedVersion() throws {
        let record = try Self.record()
        let recorded = try #require(record.split(separator: "\n").first.flatMap { line in
            line.hasPrefix("highlight.js ") ? String(line.dropFirst("highlight.js ".count)) : nil
        })
        let bundle = try String(contentsOf: Self.vendorURL.appendingPathComponent("highlight.min.js"), encoding: .utf8)
        let banners = bundle.matches(of: /Highlight\.js v(\d+\.\d+\.\d+)/).map { String($0.output.1) }
        let versions = bundle.matches(of: /\.versionString="(\d+\.\d+\.\d+)"/).map { String($0.output.1) }
        #expect(banners == [recorded], "banner reports \(banners), record says \(recorded)")
        #expect(versions == [recorded], "versionString reports \(versions), record says \(recorded)")
    }
}
