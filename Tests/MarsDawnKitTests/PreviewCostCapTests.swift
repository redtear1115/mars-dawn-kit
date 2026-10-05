#if os(macOS)
import AppKit
import Foundation
import Testing
import WebKit
@testable import MarsDawnKit

/// The page's cost caps (mars-dawn-kit#95): highlighting skips a block over the per-block limit
/// and everything past the page's total, and Mermaid renders a bounded number of diagrams per
/// update. What is skipped stays visible: plain escaped code, or a diagram's source and a note.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(5)))
struct PreviewCostCapTests {
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

    private func render(_ markdown: String, in webView: PreviewWKWebView) async throws {
        _ = try await webView.evaluateJavaScript(
            PreviewWebView.updateScript(html: MarkdownRenderer.render(markdown), lineCount: 40)
        )
        _ = try? await webView.callAsyncJavaScript("return await MarsDawn.idle();", contentWorld: .page)
    }

    private func value(_ script: String, in webView: WKWebView) async throws -> Any? {
        try await webView.callAsyncJavaScript("return \(script);", contentWorld: .page)
    }

    private func count(_ selector: String, in webView: WKWebView) async throws -> Int {
        try await value("document.querySelectorAll(\(PreviewWebView.jsonStringLiteral(selector))).length", in: webView) as? Int ?? -1
    }

    /// A JavaScript fence of about `kilobytes` KB whose every line contains a keyword.
    private func code(_ kilobytes: Int, marker: String) -> String {
        let line = "const \(marker) = function () { return 1; };\n"
        let text = String(repeating: line, count: kilobytes * 1024 / line.utf8.count)
        return "```javascript\n\(text)```\n"
    }

    // MARK: Highlighting

    @Test func aSmallBlockIsHighlighted() async throws {
        let webView = try await loadedPreview()
        try await render(code(4, marker: "SMALLBLOCK"), in: webView)
        #expect(try await count("pre > code.hljs", in: webView) == 1)
        #expect(try await count("pre > code .hljs-keyword", in: webView) > 0)
    }

    @Test func aBlockOverTheLimitStaysPlainButVisible() async throws {
        let webView = try await loadedPreview()
        try await render("Before.\n\n" + code(140, marker: "HUGEBLOCK") + "\nAfter.\n\n" + code(4, marker: "SMALLBLOCK"), in: webView)
        #expect(try await count("pre > code", in: webView) == 2)
        // Only the small one was highlighted; the page around the big one is intact.
        #expect(try await count("pre > code.hljs", in: webView) == 1)
        let big = try await value("""
        (() => {
          const code = document.querySelector("#content pre > code:not(.hljs)");
          return { spans: code.querySelectorAll("span").length, text: code.textContent.length,
                   shown: getComputedStyle(code).display !== "none", height: code.getBoundingClientRect().height,
                   hasMarker: code.textContent.includes("HUGEBLOCK") };
        })()
        """, in: webView) as? [String: Any] ?? [:]
        #expect(big["spans"] as? Int == 0)
        #expect((big["text"] as? Int ?? 0) > 128 * 1024)
        #expect(big["shown"] as? Bool == true)
        #expect((big["height"] as? Double ?? 0) > 100)
        #expect(big["hasMarker"] as? Bool == true)
        #expect(try await value("document.getElementById('content').textContent.includes('After.')", in: webView) as? Bool == true)
    }

    @Test func onceTheTotalIsSpentTheRestStayPlain() async throws {
        let webView = try await loadedPreview()
        // 100 KB each: two fit in 256 KB, the third doesn't, nor does anything after it.
        let blocks = (0..<4).map { code(100, marker: "BLOCK\($0)") }.joined(separator: "\nBetween.\n\n")
        try await render(blocks, in: webView)
        #expect(try await count("pre > code", in: webView) == 4)
        #expect(try await count("pre > code.hljs", in: webView) == 2)
        let order = try await value("[...document.querySelectorAll('#content pre > code')].map((c) => c.classList.contains('hljs'))", in: webView) as? [Bool]
        #expect(order == [true, true, false, false])
    }

    @Test func anEditKeepsWhatWasHighlightedAndCountsItAgainstTheTotal() async throws {
        let webView = try await loadedPreview()
        let first = code(100, marker: "FIRST") + "\n" + code(100, marker: "SECOND")
        try await render(first, in: webView)
        #expect(try await count("pre > code.hljs", in: webView) == 2)
        // A new block arrives with the two still on the page: 200 KB used, 100 KB more doesn't fit.
        try await render(first + "\n" + code(100, marker: "THIRD"), in: webView)
        #expect(try await count("pre > code", in: webView) == 3)
        #expect(try await count("pre > code.hljs", in: webView) == 2)
        // A small one still does.
        try await render(first + "\n" + code(40, marker: "FOURTH"), in: webView)
        #expect(try await count("pre > code.hljs", in: webView) == 3)
    }

    // MARK: Mermaid

    private func diagrams(_ n: Int) -> String {
        (0..<n).map { "```mermaid\nflowchart LR\n  A\($0)[NODE\($0)] --> B\n```\n" }.joined(separator: "\n")
    }

    @Test func theDiagramsPastTheLimitShowTheirSourceAndANote() async throws {
        let webView = try await loadedPreview()
        try await render(diagrams(103), in: webView)

        #expect(try await count(".mermaid-block", in: webView) == 103)
        #expect(try await count(".mermaid-block.rendered svg", in: webView) == 100)
        #expect(try await count(".mermaid-block.skipped", in: webView) == 3)
        #expect(try await count(".mermaid-block.rendered.skipped", in: webView) == 0)
        #expect(try await count(".mermaid-block.error", in: webView) == 0)

        let last = try await value("""
        (() => {
          const block = document.querySelectorAll("#content .mermaid-block")[102];
          const source = block.querySelector(".mermaid-source");
          const note = block.querySelector(".mermaid-skipped-note");
          return { source: source.textContent, sourceShown: getComputedStyle(source).display !== "none",
                   note: note ? note.textContent : null, role: note ? note.getAttribute("role") : null,
                   svg: block.querySelectorAll("svg").length };
        })()
        """, in: webView) as? [String: Any] ?? [:]
        #expect((last["source"] as? String)?.contains("NODE102") == true)
        #expect(last["sourceShown"] as? Bool == true)
        #expect(last["note"] as? String == PreviewWebView.diagramLimitNoteLabel)
        #expect(last["role"] as? String == "note")
        #expect(last["svg"] as? Int == 0)
    }

    @Test func aDocumentAtTheLimitIsUntouched() async throws {
        let webView = try await loadedPreview()
        try await render(diagrams(100), in: webView)
        #expect(try await count(".mermaid-block.rendered svg", in: webView) == 100)
        #expect(try await count(".mermaid-block.skipped, .mermaid-skipped-note", in: webView) == 0)
    }

    @Test func theNoteUsesTheLabelTheHostSends() async throws {
        let webView = try await loadedPreview()
        _ = try await webView.evaluateJavaScript(
            "MarsDawn.setLabels({ diagramLimitNote: \"CUSTOMNOTE\" }); MarsDawn.update(\(PreviewWebView.jsonStringLiteral(MarkdownRenderer.render(diagrams(101)))), 40);"
        )
        _ = try? await webView.callAsyncJavaScript("return await MarsDawn.idle();", contentWorld: .page)
        #expect(try await value("document.querySelector('.mermaid-skipped-note').textContent", in: webView) as? String == "CUSTOMNOTE")
    }

    @Test func aThemeChangeRedrawsUnderTheSameLimit() async throws {
        let webView = try await loadedPreview()
        try await render(diagrams(102), in: webView)
        _ = try await webView.evaluateJavaScript(PreviewWebView.themeScript(.classic))
        _ = try? await webView.callAsyncJavaScript("return await MarsDawn.idle();", contentWorld: .page)
        try await Task.sleep(for: .seconds(3))
        #expect(try await count(".mermaid-skipped-note", in: webView) == 2)
        #expect(try await count(".mermaid-block.skipped", in: webView) == 2)
    }

    /// Diagrams added over several edits can all be drawn, each update under the limit. A theme
    /// change then redraws them all at once, and the ones past the limit must show their source
    /// rather than nothing at all.
    @Test func aThemeChangeShowsTheSourceOfDiagramsThatWereDrawnBefore() async throws {
        let webView = try await loadedPreview()
        try await render(diagrams(100), in: webView)
        try await render(diagrams(130), in: webView)
        #expect(try await count(".mermaid-block.skipped", in: webView) == 0)
        _ = try await webView.evaluateJavaScript(PreviewWebView.themeScript(.classic))
        _ = try? await webView.callAsyncJavaScript("return await MarsDawn.idle();", contentWorld: .page)
        try await Task.sleep(for: .seconds(3))
        #expect(try await count(".mermaid-block.skipped", in: webView) == 30)
        #expect(try await count(".mermaid-block.skipped.rendered", in: webView) == 0)
        let shown = try await value("""
            [...document.querySelectorAll(".mermaid-block.skipped .mermaid-source")]
              .filter((el) => getComputedStyle(el).display !== "none" && el.getBoundingClientRect().height > 0).length
            """, in: webView) as? Int
        #expect(shown == 30)
    }
}
#endif
