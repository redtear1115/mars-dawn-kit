import CryptoKit
import Foundation
import Testing
@testable import MarsDawnKit

/// The vendored KaTeX is exactly what `LICENSE-katex.txt` says it is.
///
/// The file records the version, where the bytes came from and the SHA-256 of each one, and
/// this checks the recorded digests against the files on disk. A vendored file swapped without
/// the record being redone fails here; redoing both is a deliberate act with a commit behind it.
struct VendoredKatexTests {
    static var vendorURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MarsDawnKit/Resources/Preview/vendor")
    }

    /// The `<hex>  <path>` lines of the licence file's digest list.
    static func recordedDigests() throws -> [(path: String, digest: String)] {
        let text = try String(contentsOf: vendorURL.appendingPathComponent("LICENSE-katex.txt"), encoding: .utf8)
        return text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count == 2, parts[0].count == 64,
                  parts[0].allSatisfy(\.isHexDigit), parts[1].hasSuffix(".js")
                    || parts[1].hasSuffix(".css") || parts[1].hasSuffix(".woff2") else { return nil }
            return (String(parts[1]), String(parts[0]))
        }
    }

    @Test func everyVendoredFileMatchesItsRecordedDigest() throws {
        let recorded = try Self.recordedDigests()
        // katex.min.js, katex.min.css and the twenty woff2 fonts.
        #expect(recorded.count == 22)
        for (path, digest) in recorded {
            let data = try Data(contentsOf: Self.vendorURL.appendingPathComponent(path))
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            #expect(actual == digest, "\(path) does not match the digest in LICENSE-katex.txt")
        }
    }

    /// Only the woff2 fonts are vendored, and every one the stylesheet names is present.
    @Test func theStylesheetNamesOnlyTheVendoredWoff2Fonts() throws {
        let css = try String(contentsOf: Self.vendorURL.appendingPathComponent("katex.min.css"), encoding: .utf8)
        var named: Set<String> = []
        var rest = Substring(css)
        while let start = rest.range(of: "url(") {
            let after = rest[start.upperBound...]
            guard let end = after.firstIndex(of: ")") else { break }
            named.insert(String(after[..<end]))
            rest = after[end...]
        }
        #expect(!named.isEmpty)
        #expect(named.allSatisfy { $0.hasPrefix("fonts/") && $0.hasSuffix(".woff2") })

        let onDisk = try FileManager.default
            .contentsOfDirectory(atPath: Self.vendorURL.appendingPathComponent("fonts").path)
            .filter { !$0.hasPrefix(".") }
        #expect(Set(onDisk.map { "fonts/" + $0 }) == named)
    }

    /// No contrib extension came along: auto-render would scan the page's own text for
    /// delimiters, which is the job `MathExtractor` does on the source instead, and mhchem is
    /// a large parser the preview has no use for.
    @Test func noContribExtensionIsVendored() throws {
        let files = try FileManager.default.contentsOfDirectory(atPath: Self.vendorURL.path)
        #expect(!files.contains("contrib"))
        #expect(files.filter { $0.hasPrefix("katex") }.sorted() == ["katex.min.css", "katex.min.js"])
    }

    /// The page loads the vendored copies, not a CDN.
    @Test func thePageLoadsTheVendoredCopies() throws {
        let page = try String(
            contentsOf: Self.vendorURL.deletingLastPathComponent().appendingPathComponent("index.html"),
            encoding: .utf8
        )
        #expect(page.contains(#"<link rel="stylesheet" href="vendor/katex.min.css">"#))
        #expect(page.contains(#"<script src="vendor/katex.min.js"></script>"#))
        #expect(page.contains("cdn") == false)
        // The CSP is unchanged: everything KaTeX needs already comes from the app scheme.
        #expect(page.contains("font-src marsdawn-app: data:;"))
        #expect(page.contains("script-src marsdawn-app:;"))
    }
}
