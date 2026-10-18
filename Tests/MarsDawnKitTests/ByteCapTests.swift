import Foundation
import Testing
@testable import MarsDawnKit

/// The default byte cap (kit #150, owner decision BC-1): `ParseLimits.defaultMaxBytes`, 16 MiB,
/// is the default of `ParseLimits.init` and `MarkdownRenderer.Options.init`; an explicit value
/// wins, and an explicit `nil` still means no cap.
@Suite(.serialized)
struct ByteCapTests {
    static let cap = ParseLimits.defaultMaxBytes

    /// A document of exactly `bytes` UTF-8 bytes: a heading, a paragraph with math, and a fenced
    /// code block filling the rest. Few nodes, so only the byte cap can refuse it.
    static func document(bytes: Int, lead: String = "# Title\n\nSome $x$ text, [a link](https://example.com/one/two).\n\n") -> String {
        let open = "```\n", close = "```\n"
        let line = String(repeating: "a", count: 1_023) + "\n"
        var body = lead + open
        let room = bytes - body.utf8.count - close.utf8.count
        precondition(room >= 1)
        body += String(repeating: line, count: (room - 1) / line.utf8.count)
        body += String(repeating: "b", count: bytes - body.utf8.count - close.utf8.count - 1) + "\n" + close
        precondition(body.utf8.count == bytes)
        return body
    }

    static let atCap = document(bytes: cap)
    static let overCap = document(bytes: cap + 1)

    static func outcome(_ source: String, _ limits: ParseLimits = .default) -> String {
        MarkdownParsing.withDocument(source, options: limits) { outcome in
            switch outcome {
            case .document: "document"
            case .tooDeep: "tooDeep"
            case .tooLarge: "tooLarge"
            case .tooComplex: "tooComplex"
            }
        }
    }

    @Test func theDefaultsAreTheCap() {
        #expect(Self.cap == 16_777_216)
        #expect(ParseLimits().maxBytes == Self.cap)
        #expect(ParseLimits.default.maxBytes == Self.cap)
        #expect(MarkdownRenderer.Options().maxBytes == Self.cap)
        #expect(MarkdownRenderer.Options.preview(baseDirectory: nil).maxBytes == Self.cap)
    }

    @Test func anExplicitValueWins() {
        #expect(ParseLimits(maxBytes: nil).maxBytes == nil)
        #expect(ParseLimits(maxBytes: 1 << 20).maxBytes == 1 << 20)
        #expect(MarkdownRenderer.Options(maxBytes: nil).maxBytes == nil)
        #expect(MarkdownRenderer.Options(maxBytes: 1 << 20).maxBytes == 1 << 20)
        #expect(MarkdownRenderer.Options(maxBytes: 1 << 20).parseLimits.maxBytes == 1 << 20)

        let mebibyte = Self.document(bytes: 1 << 20), overMebibyte = Self.document(bytes: (1 << 20) + 1)
        let oneMiB = MarkdownRenderer.Options(maxBytes: 1 << 20)
        #expect(MarkdownRenderer.renderResult(mebibyte, options: oneMiB).fallback == nil)
        #expect(MarkdownRenderer.renderResult(overMebibyte, options: oneMiB).fallback == .tooLarge)
        #expect(Self.outcome(overMebibyte, ParseLimits(maxBytes: 1 << 20)) == "tooLarge")
    }

    /// One byte over the cap: refused by every default parse, with each caller's stated result.
    @Test func oneByteOverTheCapIsRefusedByDefault() {
        let source = Self.overCap
        #expect(Self.outcome(source) == "tooLarge")
        #expect(MarkdownParsing.decide(source, limits: .default) == .tooLarge)

        let result = MarkdownRenderer.renderResult(source)
        #expect(result.fallback == .tooLarge)
        #expect(result.html == MarkdownRenderer.sourceFallbackHTML(source))

        // TextStatistics counts a refused body as plain text, URL and markers included: more words
        // than the parsed count of the same text one byte shorter.
        let plain = TextStatistics(markdownBody: source).words
        let parsed = TextStatistics(markdownBody: Self.atCap).words
        print("B4b TextStatistics: over the cap \(plain) words (plain text), at the cap \(parsed) (parsed)")
        #expect(plain > parsed)
        // DocumentOutline has no headings for a refused body.
        #expect(DocumentOutline(markdownBody: source).headings.isEmpty)
        // MathExtractor has its own, smaller cap (256,000 bytes) and leaves the body alone.
        var generator = SystemRandomNumberGenerator()
        let math = MathExtractor.extract(from: source, using: &generator)
        #expect(math.expressions.isEmpty && math.markdown == source)
    }

    /// Exactly at the cap: parsed as before.
    @Test func exactlyAtTheCapIsAccepted() {
        let source = Self.atCap
        #expect(Self.outcome(source) == "document")
        #expect(DocumentOutline(markdownBody: source).headings.map(\.title) == ["Title"])
        let result = MarkdownRenderer.renderResult(source)
        #expect(result.fallback == nil)
        #expect(result.html.contains("<h1"))
    }

    /// Explicit `nil` is no cap: one byte over still parses and renders.
    @Test func explicitNilIsNoCap() {
        let source = Self.overCap
        #expect(Self.outcome(source, ParseLimits(maxBytes: nil)) == "document")
        #expect(MarkdownRenderer.renderResult(source, options: MarkdownRenderer.Options(maxBytes: nil)).fallback == nil)
    }

    /// EscapeMap's second parse lifts the byte cap (InlineMarks.swift): at the cap, a `\=` grows
    /// the stand-in source past it, and the escape must still be read.
    @Test func escapesAtTheCapAreStillRead() {
        let source = Self.document(bytes: Self.cap, lead: "x ==a== \\=\n\ny ==b==\n\n")
        #expect(source.utf8.count == Self.cap)
        let html = MarkdownRenderer.render(source)
        #expect(html.contains("x <mark>a</mark> =") && html.contains("y <mark>b</mark>"), "\(html.prefix(300))")
    }
}
