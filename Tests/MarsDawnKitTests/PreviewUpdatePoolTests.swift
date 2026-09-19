#if os(macOS)
import AppKit
import Foundation
import Testing
import WebKit
@testable import MarsDawnKit

/// `preview.js`'s `update()` reuses unchanged blocks between updates, so diagrams and highlighted
/// code don't redraw on every keystroke (redtear1115/mars-dawn#4). Reuse must never leave a stale
/// fragment behind: after any sequence of updates, the page is exactly what one update with the
/// last HTML produces on a fresh page, source line numbers included.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(5)))
struct PreviewUpdatePoolTests {
    private func loadedPreview() async throws -> PreviewWKWebView {
        let webView = PreviewWKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 800),
                                       configuration: PreviewWebView.makeConfiguration())
        webView.applyContentRuleList(try await PreviewContentRules.ruleList(allowRemoteImages: false))
        #expect(webView.load(URLRequest(url: PreviewSchemeHandler.pageURL(theme: .dawn))) != nil)
        let deadline = ContinuousClock.now + .seconds(20)
        while webView.isLoading, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!webView.isLoading)
        return webView
    }

    /// Pushes one update the way the app does: no waiting for the page to settle in between.
    private func push(_ markdown: String, to webView: PreviewWKWebView) async throws {
        _ = try await webView.evaluateJavaScript(
            PreviewWebView.updateScript(html: MarkdownRenderer.render(markdown), lineCount: LineIndex(markdown).lineCount)
        )
    }

    private func settle(_ webView: PreviewWKWebView) async throws {
        _ = try? await webView.callAsyncJavaScript("return await MarsDawn.idle();", contentWorld: .page)
    }

    /// The page's content, and every source line number in document order.
    private func state(of webView: PreviewWKWebView) async throws -> (html: String, lines: [String]) {
        let html = try await webView.callAsyncJavaScript(
            "return document.getElementById('content').innerHTML;", contentWorld: .page
        ) as? String ?? "<unreadable>"
        let lines = try await webView.callAsyncJavaScript(
            "return [...document.querySelectorAll('#content [data-line]')].map((e) => e.tagName + ':' + e.getAttribute('data-line'));",
            contentWorld: .page
        ) as? [String] ?? []
        return (html, lines)
    }

    /// What a fresh page shows for `markdown` after a single update.
    private func fresh(_ markdown: String) async throws -> (html: String, lines: [String]) {
        let webView = try await loadedPreview()
        try await push(markdown, to: webView)
        try await settle(webView)
        return try await state(of: webView)
    }

    private func expectMatchesFresh(_ webView: PreviewWKWebView, _ markdown: String,
                                    _ comment: String, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let actual = try await state(of: webView)
        let expected = try await fresh(markdown)
        #expect(!expected.lines.isEmpty, "positive fixture: the page has line-numbered blocks", sourceLocation: sourceLocation)
        #expect(actual.lines == expected.lines, "\(comment): source line numbers", sourceLocation: sourceLocation)
        #expect(actual.html == expected.html, "\(comment): content", sourceLocation: sourceLocation)
    }

    // MARK: Targeted cases

    /// Identical blocks share a key; deleting the middle one must leave exactly two, numbered
    /// for their new lines.
    @Test func deletingOneOfSeveralIdenticalBlocks() async throws {
        let webView = try await loadedPreview()
        try await push("same\n\nsame\n\nsame\n\nend\n", to: webView)
        try await settle(webView)
        let final = "same\n\nsame\n\nend\n"
        try await push(final, to: webView)
        try await settle(webView)
        try await expectMatchesFresh(webView, final, "identical blocks")
    }

    /// A line inserted above shifts every reused block's line number, nested ones included.
    @Test func aReusedBlockTakesItsNewLineNumbers() async throws {
        let webView = try await loadedPreview()
        let body = "# Title\n\n- one\n- two\n  - nested\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n```swift\nlet x = 1\n```\n"
        try await push(body, to: webView)
        try await settle(webView)
        let final = "inserted\n\nand another\n\n" + body
        try await push(final, to: webView)
        try await settle(webView)
        try await expectMatchesFresh(webView, final, "shifted blocks")
    }

    /// Blocks swapping places, and a block that changes by one character, end up right.
    @Test func reorderedAndEditedBlocks() async throws {
        let webView = try await loadedPreview()
        try await push("A para\n\nB para\n\nC para\n", to: webView)
        try await settle(webView)
        let final = "C para\n\nA para\n\nB parA\n"
        try await push(final, to: webView)
        try await settle(webView)
        try await expectMatchesFresh(webView, final, "reordered")
    }

    // MARK: Bursts

    /// Blocks the edits draw from: prose, headings, lists, a table, code, math, a quote.
    private static let blocks = [
        "# Heading one", "## Heading two", "Plain paragraph with *emphasis*.",
        "Another paragraph, `code span`.", "- item a\n- item b\n  - nested", "1. first\n2. second",
        "| h1 | h2 |\n|----|----|\n| c1 | c2 |", "```swift\nlet value = 42\n```", "```\nplain block\n```",
        "$$\n\\frac{1}{2}\n$$", "> quoted text", "---", "Same line", "Same line",
    ]

    /// A seeded sequence of edits: insert, delete, duplicate, move and retype blocks.
    private static func burst(seed: UInt64, steps: Int) -> [String] {
        var state = seed
        func next(_ bound: Int) -> Int {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return Int((z ^ (z >> 31)) % UInt64(bound))
        }
        var doc = Array(blocks.prefix(6))
        var versions: [String] = []
        for _ in 0..<steps {
            switch next(5) {
            case 0: doc.insert(blocks[next(blocks.count)], at: next(doc.count + 1))
            case 1 where doc.count > 1: doc.remove(at: next(doc.count))
            case 2 where !doc.isEmpty: doc.insert(doc[next(doc.count)], at: next(doc.count + 1))
            case 3 where doc.count > 1: doc.insert(doc.remove(at: next(doc.count)), at: next(doc.count))
            default:
                if !doc.isEmpty { let i = next(doc.count); doc[i] += " x\(next(9))" }
            }
            versions.append(doc.joined(separator: "\n\n") + "\n")
        }
        return versions
    }

    @Test(arguments: [1, 2, 3, 4, 5] as [UInt64])
    func aBurstOfEditsEndsExactlyOnTheLastOne(seed: UInt64) async throws {
        let webView = try await loadedPreview()
        let versions = Self.burst(seed: seed, steps: 60)
        for version in versions {
            try await push(version, to: webView)
        }
        try await settle(webView)
        try await expectMatchesFresh(webView, versions.last!, "seed \(seed)")
    }
}
#endif
