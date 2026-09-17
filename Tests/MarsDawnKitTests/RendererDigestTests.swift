import CryptoKit
import Foundation
import Testing
@testable import MarsDawnKit

/// Ordinary output must not have moved: the digest below was taken at 0.2.0 (7f7f18d), before the
/// escapers were rewritten on bytes. The corpus holds no joining scalars, which are the only
/// inputs whose output this hotfix is meant to change.
struct RendererDigestTests {
    struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// Markdown fragments, none of which contains a scalar that joins its neighbour.
    static let pieces = [
        "# ", "## ", "###### ", "\n", "\n\n", " ", "  ", "\t", "text", "Ünïcödé", "日本語", "😀", "🚀",
        "<", ">", "&", "\"", "'", "&lt;", "&amp;", "&quot;", "&#39;", "&#x3C;", "&copy;", "&nbsp;",
        "`", "``", "```", "```swift\n", "```mermaid\n", "```c++ extra\n", "```a\"b\n", "~~~\n",
        "[link](https://example.com \"ti\\\"t<le>\")", "[x](javascript:alert(1))", "[y](JAVA\tSCRIPT:x)",
        "![alt <b>](img/a.png 'ti\"tle')", "![i](data:image/png;base64,AA)", "![s](data:image/svg+xml,x)",
        "![r](marsdawn-asset://doc/a.png)", "[m](mailto:a@b.c)", "[rel](docs/a:b.md)", "[q](?a:b)", "[h](#x:y)",
        "<div>", "</div>", "<link rel=preconnect href=//x>", "<iframe src=x></iframe>", "<LINK/>", "<embed>",
        "<span title=\"a>b\">s</span>", "<!-- c -->", "*", "**", "_", "~~", "- ", "1. ", "> ",
        "| a | b |\n|--|--|\n| 1 | 2 |\n", "- [x] ", "---\n", "\\<", "\\*", "<http://auto.link/?a=<b>>",
        "<a@b.c>", "``` \n", "    code <x>\n", "[ref]", "[ref]: /url \"t&\"\n",
    ]

    /// Strings for the escapers, the URL sanitizer and the raw-HTML rename.
    static let alphabet = [
        "a", "Z", "0", " ", "<", ">", "&", "\"", "'", ":", "/", "?", "#", "é", "日", "😀", "\t", "\n", "\r\n",
        "=", ";", "%", "\\", "`", "data", "image/", "svg", "javascript", "HTTP", "mailto", "marsdawn-asset",
        "+", ".", "-", "x-", "<link", "</LINK ", "<iframe/", "<objective", "embed>",
    ]

    static func digest(documents: Int, strings: Int) -> String {
        var rng = SplitMix64(state: 0x0D15_EA5E)
        var hasher = SHA256()
        func feed(_ value: String) {
            var length = UInt64(value.utf8.count).littleEndian
            withUnsafeBytes(of: &length) { hasher.update(data: Data($0)) }
            hasher.update(data: Data(value.utf8))
        }
        let options = MarkdownRenderer.Options {
            DocumentAssetSchemeHandler.previewURL(forImageSource: $0, hasBaseDirectory: true) ?? $0
        }
        for _ in 0..<documents {
            var document = ""
            for _ in 0..<Int.random(in: 1...40, using: &rng) {
                document += pieces.randomElement(using: &rng)!
            }
            feed(MarkdownRenderer.render(document))
            feed(MarkdownRenderer.render(document, options: options))
        }
        for _ in 0..<strings {
            var string = ""
            for _ in 0..<Int.random(in: 0...24, using: &rng) {
                string += alphabet.randomElement(using: &rng)!
            }
            feed(escapeHTML(string))
            feed(escapeAttribute(string))
            feed(sanitizedURL(string, allowData: false))
            feed(sanitizedURL(string, allowData: true))
            feed(neutralizingLinkTags(string))
            feed(DocumentAssetSchemeHandler.previewURL(forImageSource: string, hasBaseDirectory: true) ?? "<nil>")
            feed(slugify(string))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    @Test func ordinaryOutputMatchesTheDigestFrom0_2_0() {
        #expect(Self.digest(documents: 4000, strings: 20000)
            == "e9ee39be8279bf44fc90ed51505aa423bf10c1ca27adae9f82a68dad3af3b7ef")
    }
}
