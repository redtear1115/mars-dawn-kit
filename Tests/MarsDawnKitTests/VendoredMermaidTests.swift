import CryptoKit
import Foundation
import Testing

/// The vendored Mermaid is exactly what `LICENSE-mermaid.txt` says it is (redtear1115/mars-dawn#3).
///
/// A Mermaid upgrade is a breaking change: a newer engine can reject diagrams people already have.
/// So the file is pinned by version and digest, and swapping it without redoing the record fails
/// here. Redoing the record is the moment to run the Mermaid corpus in `MarsDawnExportTests`.
/// The version check follows the one in kit #21's PDF corpus.
struct VendoredMermaidTests {
    static var vendorURL: URL { VendoredKatexTests.vendorURL }

    static func record() throws -> String {
        try String(contentsOf: vendorURL.appendingPathComponent("LICENSE-mermaid.txt"), encoding: .utf8)
    }

    @Test func theBundleMatchesItsRecordedDigest() throws {
        let record = try Self.record()
        let digests = record.split(separator: "\n").compactMap { line -> (String, String)? in
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count == 2, parts[0].count == 64, parts[0].allSatisfy(\.isHexDigit) else { return nil }
            return (String(parts[1]), String(parts[0]))
        }
        #expect(digests.map(\.0) == ["mermaid.min.js"], "the record lists exactly the one vendored file")
        for (path, digest) in digests {
            let data = try Data(contentsOf: Self.vendorURL.appendingPathComponent(path))
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            #expect(actual == digest, "\(path) does not match the digest in LICENSE-mermaid.txt")
        }
    }

    /// The version the record names is the one the bundle reports about itself.
    @Test func theBundleReportsTheRecordedVersion() throws {
        let record = try Self.record()
        let recorded = try #require(record.split(separator: "\n").first.flatMap { line in
            line.hasPrefix("Mermaid ") ? String(line.dropFirst("Mermaid ".count)) : nil
        })
        let bundle = try String(contentsOf: Self.vendorURL.appendingPathComponent("mermaid.min.js"), encoding: .utf8)
        // Mermaid's own version object looks like `RSi={version:"12.0.0"}`. Other bundled
        // packages carry version strings too, so match Mermaid's exact form.
        let versions = bundle.matches(of: /=\{version:"(\d+\.\d+\.\d+)"\}/).map { String($0.output.1) }
        #expect(versions == [recorded], "bundle reports \(versions), record says \(recorded)")
    }
}
