import Foundation
import Markdown
import Testing
@testable import MarsDawnKit

/// Deeply nested input must never crash, whichever thread renders it.
struct MarkdownNestingTests {
    static let maxDepth = ParseLimits.default.maxDepth

    private static func expectFallback(
        _ result: MarkdownRenderer.RenderResult?, source: String, depth: Int,
        sourceLocation: Testing.SourceLocation = #_sourceLocation
    ) {
        #expect(result?.fallback == .tooDeep(depth: depth), sourceLocation: sourceLocation)
        #expect(result?.html == MarkdownRenderer.sourceFallbackHTML(source), sourceLocation: sourceLocation)
    }

    /// The blocking entry point (an `async` caller would otherwise pick the async overload).
    private static func renderBlocking(_ source: String) -> MarkdownRenderer.RenderResult {
        MarkdownRenderer.renderResult(source)
    }

    @Test(arguments: NestingShape.allCases)
    func tooDeepInputFallsBackOnEveryCallingThread(_ shape: NestingShape) async {
        let source = shape.source(shape.deepCount)
        let depth = CMarkDepthScan.maximumDepth(of: source)
        #expect(depth > Self.maxDepth, "\(shape) must really nest past the limit")

        // (a) the Swift Testing worker thread this test runs on
        Self.expectFallback(Self.renderBlocking(source), source: source, depth: depth)
        #expect(MarkdownRenderer.render(source) == MarkdownRenderer.sourceFallbackHTML(source))

        // (b) a thread with a cooperative-pool-sized stack
        let fromSmallThread = onSmallStackThread { MarkdownRenderer.renderResult(source) }
        Self.expectFallback(fromSmallThread, source: source, depth: depth)

        // (c) a detached task, both through the blocking and the async entry points
        let fromDetached = await Task.detached { MarkdownRenderer.render(source) }.value
        #expect(fromDetached == MarkdownRenderer.sourceFallbackHTML(source))
        let fromAsync = await Task.detached { await MarkdownRenderer.renderResult(source) }.value
        Self.expectFallback(fromAsync, source: source, depth: depth)
    }

    @Test(arguments: NestingShape.allCases)
    func deepestAcceptedInputRendersFromASmallStack(_ shape: NestingShape) async throws {
        let (source, depth) = shape.source(depthAtMost: Self.maxDepth - 2)
        // Shapes that nest two or three levels per step can't hit the limit exactly.
        #expect(depth >= Self.maxDepth - 4)
        #expect(depth <= Self.maxDepth - 2)

        let result = onSmallStackThread { MarkdownRenderer.renderResult(source) }
        #expect(result.fallback == nil)
        #expect(!result.html.contains("source-fallback"))

        let asyncResult = try #require(await Task.detached { await MarkdownRenderer.renderResult(source) }.value)
        #expect(asyncResult == result)

        // One level deeper is rejected.
        let deeper = (1...).lazy.map { shape.source($0) }.first { CMarkDepthScan.maximumDepth(of: $0) > depth }!
        let deeperDepth = CMarkDepthScan.maximumDepth(of: deeper)
        if deeperDepth > Self.maxDepth - 2 {
            #expect(onSmallStackThread { MarkdownRenderer.renderResult(deeper) }.fallback == .tooDeep(depth: deeperDepth))
        }
    }

    @Test func limitBoundaryIsDepthPlusTwo() {
        let accepted = NestingShape.blockQuotes.source(depthAtMost: Self.maxDepth - 2)
        #expect(accepted.depth == Self.maxDepth - 2)
        #expect(MarkdownRenderer.renderResult(accepted.source).fallback == nil)

        let rejected = ">" + accepted.source
        #expect(CMarkDepthScan.maximumDepth(of: rejected) == Self.maxDepth - 1)
        #expect(MarkdownRenderer.renderResult(rejected).fallback == .tooDeep(depth: Self.maxDepth - 1))
    }

    @Test func smallerLimitsAreHonouredAndLargerOnesClamped() {
        let source = NestingShape.blockQuotes.source(10)   // depth 13
        #expect(MarkdownParsing.withDocument(source, options: ParseLimits(maxDepth: 15)) { outcome in
            if case .document = outcome { return true } else { return false }
        })
        #expect(MarkdownParsing.withDocument(source, options: ParseLimits(maxDepth: 14)) { outcome in
            if case .tooDeep(depth: 13) = outcome { return true } else { return false }
        })
        #expect(ParseLimits(maxDepth: 100_000).maxDepth == ParseLimits.depthCeiling)
        #expect(ParseLimits(maxDepth: -3).maxDepth == 1)
    }

    @Test func fallbackIsTheEscapedSourceInAPreBlock() {
        let source = String(repeating: ">", count: 300) + " <script>alert('x')</script> & \"q\"\n"
        let html = MarkdownRenderer.render(source)
        #expect(html == #"<pre class="source-fallback" data-line="1">"#
            + String(repeating: "&gt;", count: 300)
            + " &lt;script&gt;alert('x')&lt;/script&gt; &amp; \"q\"\n</pre>")
        #expect(!html.contains("<code"))
        #expect(!html.contains("style="))
    }

    @Test func oversizedInputFallsBackOnlyWithAByteLimit() {
        let source = "# Title\n\nSome *text*.\n"
        let limited = MarkdownRenderer.Options(maxBytes: source.utf8.count - 1)
        let result = MarkdownRenderer.renderResult(source, options: limited)
        #expect(result.fallback == .tooLarge)
        #expect(result.html == MarkdownRenderer.sourceFallbackHTML(source))

        let exact = MarkdownRenderer.Options(maxBytes: source.utf8.count)
        #expect(MarkdownRenderer.renderResult(source, options: exact).fallback == nil)
        #expect(MarkdownRenderer.renderResult(source).fallback == nil)
        #expect(MarkdownRenderer.renderResult(source, options: exact).html == MarkdownRenderer.render(source))
    }

    @Test func previewStylesWrapTheFallback() throws {
        let url = try #require(Bundle.module.url(forResource: "Preview/preview", withExtension: "css"))
        let css = try String(contentsOf: url, encoding: .utf8)
        #expect(css.contains(".source-fallback { white-space: pre-wrap; overflow-wrap: anywhere; }"))
    }

    // MARK: Differential depth (F1)

    /// Documents of every kind, deep and shallow, including tables (which swift-markdown
    /// nests one level deeper than cmark).
    static let corpus: [String] = [
        "# Heading\n\nText with *em*, **strong**, ~~del~~, `code` and [a link](https://x).\n",
        "| a | b |\n|:-|-:|\n| *1* | **2** |\n| ~~3~~ | [4](u) |\n",
        "> | a |\n> |---|\n> | > b |\n",
        "- [ ] task\n- [x] done\n  1. nested\n     > quote\n     > | t |\n     > |---|\n     > | *c* |\n",
        "```swift\nlet a = 1\n```\n\n<div>\n*html*\n</div>\n\n---\n\nSetext\n======\n",
        "![alt *em* ![inner](i)](o) ^[attr **x**](k: v) <span>inline</span>\\\nbreak\n",
        "1. a\n\n   b\n\n2. c\n   - d\n     - e\n       - f\n",
        "Term[^1]\n\n[^1]: footnote text\n\n[ref]: https://x\n\n[ref] and [ref][]\n",
        "> > > quoted\n> > > - list\n> > >   ```\n> > >   code\n> > >   ```\n",
        "",
        "\n\n\n",
        "\u{0}nul byte\u{0} and **bold\u{0}**\n",
    ]

    @Test func preScanDepthBoundsSwiftMarkdownDepth() {
        var inputs = Self.corpus
        for shape in NestingShape.allCases {
            inputs += [1, 2, 7, 40].map { shape.source($0) }
            inputs.append(shape.source(depthAtMost: Self.maxDepth - 2).source)
        }
        var random = SeededGenerator(seed: 0x4B31)
        let pieces = [">", "> ", "- ", "  ", "1. ", "*", "_", "~~", "![", "](u)", "^[", "[", "]", "(", ")",
                      "|", "|-|", "`", "```", "a", " ", "\n", "\n\n", "    ", "<b>", "- [ ] ", "\\", "#"]
        for _ in 0..<1_500 {
            let length = Int.random(in: 1...120, using: &random)
            inputs.append((0..<length).map { _ in pieces.randomElement(using: &random)! }.joined())
        }
        // A repo document too, when the checkout is at hand.
        let readme = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../README.md")
        if let text = try? String(contentsOf: readme, encoding: .utf8) { inputs.append(text) }

        let allInputs = inputs
        let failures = MarkdownParsing.withDocument("") { _ in
            allInputs.compactMap { input -> String? in
                let cmarkDepth = CMarkDepthScan.maximumDepth(of: input)
                guard cmarkDepth <= Self.maxDepth - 2 else { return nil }
                return MarkdownParsing.withDocument(input) { outcome -> String? in
                    guard case .document(let document) = outcome else { return "not parsed: \(input.debugDescription)" }
                    let depth = swiftMarkdownDepth(document)
                    if cmarkDepth + 1 < depth {
                        return "cmark \(cmarkDepth) vs swift-markdown \(depth): \(input.debugDescription)"
                    }
                    return nil
                }
            }
        }
        #expect(failures.isEmpty, "\(failures.prefix(5))")
        #expect(allInputs.count > 1_500)
    }

    @Test func tablesAreTheOneLevelSwiftMarkdownAdds() {
        let (cmarkDepth, swiftDepth) = MarkdownParsing.withDocument("| a |\n|---|\n| b |\n") { outcome in
            guard case .document(let document) = outcome else { return (0, 0) }
            return (CMarkDepthScan.maximumDepth(of: "| a |\n|---|\n| b |\n"), swiftMarkdownDepth(document))
        }
        // Document > Table > Row > Cell > Text in cmark; Table > Body > Row > Cell > Text here.
        #expect(cmarkDepth == 5)
        #expect(swiftDepth == 6)
    }
}

/// A small deterministic generator (SplitMix64), so the random inputs are reproducible.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
