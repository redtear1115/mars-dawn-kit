import CryptoKit
import Foundation

/// Documents without front matter whose rendered HTML must not change when front-matter
/// support is added. Several of them start with or contain `---` lines that are NOT front
/// matter (setext underlines, thematic breaks, near-miss delimiters).
enum RenderGoldenCorpus {
    static let documents: [String] = MarkdownNestingTests.corpus + [
        "---\n",
        "---\ntitle: x\n",
        "--- \ntitle: x\n---\n",
        " ---\ntitle: x\n---\n",
        "----\ntitle: x\n----\n",
        "\n---\ntitle: x\n---\n",
        "\u{FEFF}---\ntitle: x\n---\nBody\n",
        "Title\n---\n\nText\n---\nMore\n",
        "# Doc\n\n---\n\ntitle: x\n---\n",
        "...\ntitle: x\n...\n",
        "--- # comment\na: b\n---\n",
        "***\n\n- a\n- b\n\n___\n",
        "Line one\r\nLine two\r\n\r\n---\r\n\r\n# H\r\n",
        "Line one\rLine two\r\r---\r\r# H\r",
        "[x](javascript:alert(1)) <script>alert(1)</script> & \"q\" 'a'\n",
        "| k | v |\n|---|---|\n| title | x |\n\n```yaml\n---\na: b\n---\n```\n",
    ]

    static func digest(_ html: String) -> String {
        SHA256.hash(data: Data(html.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
