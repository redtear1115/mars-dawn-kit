#if os(macOS)
import AppKit
import Foundation
import Testing
import WebKit
@testable import MarsDawnKit

/// Math in the real preview page: KaTeX renders it, `trust: false` holds, bad expressions show
/// an error instead of throwing, the limits leave the source visible, and every math element
/// ends up marked done so the exporter's readiness check can't hang on one.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(3)))
struct PreviewMathPageTests {
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
        // The vendored script loaded under the page's CSP, unchanged.
        let hasKatex = try await webView.evaluateJavaScript("typeof katex === 'object' && typeof katex.render === 'function'") as? Bool
        #expect(hasKatex == true)
        return webView
    }

    private func update(_ html: String, in webView: PreviewWKWebView) async throws {
        _ = try await webView.evaluateJavaScript(PreviewWebView.updateScript(html: html, lineCount: 40))
        _ = try? await webView.callAsyncJavaScript("return await MarsDawn.idle();", contentWorld: .page)
    }

    private func render(_ markdown: String, in webView: PreviewWKWebView) async throws {
        try await update(MarkdownRenderer.render(markdown), in: webView)
    }

    private func value(_ script: String, in webView: WKWebView) async throws -> Any? {
        try await webView.callAsyncJavaScript("return \(script);", contentWorld: .page)
    }

    private func count(of selector: String, in webView: WKWebView) async throws -> Int {
        try await value("document.getElementById('content').querySelectorAll(\(jsString(selector))).length",
                        in: webView) as? Int ?? -1
    }

    private func jsString(_ string: String) -> String {
        PreviewWebView.jsonStringLiteral(string)
    }

    // MARK: Rendering

    @Test func inlineAndDisplayMathRenderToKatexOutput() async throws {
        let webView = try await loadedPreview()
        try await render("Text $a^2 + b^2 = c^2$ text.\n\n$$\n\\frac{1}{2}\n$$\n", in: webView)

        #expect(try await count(of: ".math-inline .katex", in: webView) == 1)
        #expect(try await count(of: ".math-block .katex", in: webView) == 1)
        // Display mode only for the block; `output: "htmlAndMathml"` gives both trees.
        #expect(try await count(of: ".math-block .katex-display", in: webView) == 1)
        #expect(try await count(of: ".math-inline .katex-display", in: webView) == 0)
        #expect(try await count(of: ".math-block .katex-mathml math", in: webView) == 1)
        #expect(try await count(of: ".math-block .katex-html", in: webView) == 1)
        // Everything is marked done, whatever happened to it.
        #expect(try await count(of: ".math-inline:not(.math-done), .math-block:not(.math-done)", in: webView) == 0)
    }

    /// The TeX arrives as text, not as markup: KaTeX echoes it into the MathML annotation, so
    /// comparing that with the source shows the escaping round-tripped exactly.
    @Test func theTeXReachesKatexExactlyAsWritten() async throws {
        let webView = try await loadedPreview()
        let tex = #"a \& b < c > d"#
        try await render("Text $\(tex)$ text.", in: webView)

        let annotation = try await value(
            #"document.querySelector('.math-inline annotation[encoding="application/x-tex"]').textContent"#,
            in: webView
        ) as? String
        #expect(annotation == tex)
    }

    /// TeX that closes the span and opens a script tag. If any of it were markup, the page
    /// would hold a `script` element and the counter would be set.
    @Test func hostileTeXNeverBecomesMarkup() async throws {
        let webView = try await loadedPreview()
        try await render("Before $</span><script>window.mathRan = 1</script>$ after", in: webView)

        #expect(try await count(of: "script", in: webView) == 0)
        #expect(try await value("window.mathRan ?? null", in: webView) as? Int == nil)
        #expect(try await count(of: ".math-inline", in: webView) == 1)
    }

    // MARK: Errors

    /// `throwOnError: false`: KaTeX puts its own message on a `.katex-error` span and carries
    /// on, so one bad expression neither throws out of `update` nor stops the next one.
    @Test func aBadExpressionShowsAnErrorInsteadOfThrowing() async throws {
        let webView = try await loadedPreview()
        try await render("Bad ${x$ and good $y$.", in: webView)

        #expect(try await count(of: ".math-inline > .katex-error", in: webView) == 1)
        #expect(try await count(of: ".math-inline > .katex", in: webView) == 1)
        #expect(try await count(of: ".math-inline:not(.math-done)", in: webView) == 0)
        let message = try await value(
            "document.querySelector('.math-inline > .katex-error').getAttribute('title')", in: webView
        ) as? String
        #expect(message?.contains("KaTeX parse error") == true)
        // The source is what the error span shows, as text.
        let shown = try await value(
            "document.querySelector('.math-inline > .katex-error').textContent", in: webView
        ) as? String
        #expect(shown == "{x")
    }

    /// `strict: "ignore"`: an unknown command is not a parse error. KaTeX renders it in its
    /// error colour and keeps the rest of the expression, which is what the preview wants.
    @Test func anUnknownCommandRendersInTheErrorColourRatherThanFailing() async throws {
        let webView = try await loadedPreview()
        try await render("Bad $\\thisIsNotACommand{x}$.", in: webView)

        #expect(try await count(of: ".math-inline > .katex", in: webView) == 1)
        let annotation = try await value(
            #"document.querySelector('.math-inline annotation[encoding="application/x-tex"]').textContent"#,
            in: webView
        ) as? String
        #expect(annotation == #"\thisIsNotACommand{x}"#)
        #expect(try await count(of: ".math-inline:not(.math-done)", in: webView) == 0)
    }

    // MARK: trust: false

    @Test func trustFalseProducesNoLinkAndNoImage() async throws {
        let webView = try await loadedPreview()
        try await render("""
        A $\\href{javascript:alert(1)}{x}$ link.

        A $\\url{javascript:alert(1)}$ url.

        An $\\includegraphics[width=1cm]{https://example.com/x.png}$ image.

        $$
        \\htmlClass{evil}{\\href{https://example.com}{y}}
        $$
        """, in: webView)

        #expect(try await count(of: "a", in: webView) == 0)
        #expect(try await count(of: "img", in: webView) == 0)
        #expect(try await count(of: "[href], [src]", in: webView) == 0)
        // All four were dealt with, none left pending.
        #expect(try await count(of: ".math-inline, .math-block", in: webView) == 4)
        #expect(try await count(of: ".math-inline:not(.math-done), .math-block:not(.math-done)", in: webView) == 0)
    }

    // MARK: Limits (S5-4)

    /// The renderer can't produce an expression this long — `MathExtractor.maxExpressionLength`
    /// is the same 10,000 and it leaves a longer one as source — so the fragment goes straight
    /// to the page, the way `PreviewDOMFilterTests` pushes one. This is the page's own guard.
    @Test func anExpressionOverTheLengthLimitStaysAsSource() async throws {
        let webView = try await loadedPreview()
        let long = String(repeating: "x", count: MathExtractor.maxExpressionLength + 1)
        try await update(#"<p data-line="1"><span class="math-inline">\#(long)</span>"#
            + #"<span class="math-inline">y</span></p>"#, in: webView)

        let state = try await value("""
        (() => {
          const els = [...document.querySelectorAll('.math-inline')];
          return JSON.stringify(els.map((e) => ({
            skipped: e.classList.contains('math-skipped'),
            done: e.classList.contains('math-done'),
            katex: e.querySelectorAll('.katex').length,
            length: e.textContent.length,
          })));
        })()
        """, in: webView) as? String
        let elements = try JSONDecoder().decode([MathElement].self, from: Data(#require(state).utf8))
        #expect(elements.count == 2)
        // The long one kept its source, unrendered but marked done.
        #expect(elements[0].skipped)
        #expect(elements[0].done)
        #expect(elements[0].katex == 0)
        #expect(elements[0].length == long.count)
        // The short one still rendered.
        #expect(!elements[1].skipped)
        #expect(elements[1].done)
        #expect(elements[1].katex == 1)
    }

    /// The per-update cap. The renderer can't emit this many (the extractor stops at the same
    /// number), so the fragment is pushed straight to the page, as `PreviewDOMFilterTests` does.
    @Test func onlyTheFirstTwoThousandExpressionsPerUpdateAreRendered() async throws {
        let webView = try await loadedPreview()
        let spans = (0..<2100).map { #"<span class="math-inline">x_{\#($0)}</span>"# }.joined()
        try await update("<p data-line=\"1\">\(spans)</p>", in: webView)

        #expect(try await count(of: ".math-inline", in: webView) == 2100)
        #expect(try await count(of: ".math-inline .katex", in: webView) == 2000)
        #expect(try await count(of: ".math-inline.math-skipped", in: webView) == 100)
        // Rendered, skipped — every one of them is done.
        #expect(try await count(of: ".math-inline:not(.math-done)", in: webView) == 0)
    }

    // MARK: Layout

    /// An expression wider than the column scrolls inside its own block; the page itself never
    /// grows sideways. In print the block clips instead, so it can't widen the paper either.
    @Test func wideDisplayMathStaysInsideTheColumn() async throws {
        let webView = try await loadedPreview()
        let wide = (0..<120).map { "x_{\($0)} + " }.joined() + "y"
        try await render("$$\n\(wide)\n$$\n\nAnd $$\(wide)$$ in a paragraph.\n", in: webView)

        let state = try #require(try await value("""
        (() => {
          const block = document.querySelector('.math-block');
          const inline = document.querySelector('.math-inline.math-display');
          return JSON.stringify({
            overflows: block.scrollWidth > block.clientWidth,
            insideColumn: block.getBoundingClientRect().width <= document.documentElement.clientWidth,
            pageScrolls: document.documentElement.scrollWidth > document.documentElement.clientWidth,
            inlineDisplay: getComputedStyle(inline).display,
          });
        })()
        """, in: webView) as? String)
        let layout = try JSONDecoder().decode(Layout.self, from: Data(state.utf8))
        #expect(layout.overflows)
        #expect(layout.insideColumn)
        #expect(!layout.pageScrolls)
        #expect(layout.inlineDisplay == "block")

        webView.mediaType = "print"
        let printed = try #require(try await value("""
        (() => {
          const block = document.querySelector('.math-block');
          return JSON.stringify({
            overflow: getComputedStyle(block).overflowX,
            insideColumn: block.getBoundingClientRect().width <= document.documentElement.clientWidth,
            pageScrolls: document.documentElement.scrollWidth > document.documentElement.clientWidth,
          });
        })()
        """, in: webView) as? String)
        let paper = try JSONDecoder().decode(PrintLayout.self, from: Data(printed.utf8))
        #expect(paper.overflow == "hidden")
        #expect(paper.insideColumn)
        #expect(!paper.pageScrolls)
    }

    // MARK: Incremental update

    @Test func unchangedMathIsNotRenderedAgain() async throws {
        let webView = try await loadedPreview()
        try await render("Keep $a^2$ here.\n\nChange me.\n", in: webView)
        _ = try await webView.evaluateJavaScript(
            "document.querySelector('.math-inline .katex').dataset.probe = 'first'"
        )
        try await render("Keep $a^2$ here.\n\nChanged.\n", in: webView)

        // Same element, same KaTeX output: the pool reused the paragraph and `math-done` kept
        // `renderMath` off it.
        let probe = try await value(
            "document.querySelector('.math-inline .katex')?.dataset.probe ?? null", in: webView
        ) as? String
        #expect(probe == "first")
        // A second render would have fed KaTeX's own output back in, so the annotation is the
        // sharpest check that it didn't happen.
        let annotation = try await value(
            #"document.querySelector('.math-inline annotation[encoding="application/x-tex"]').textContent"#,
            in: webView
        ) as? String
        #expect(annotation == "a^2")

        // Editing the expression does re-render it.
        try await render("Keep $b^2$ here.\n\nChanged.\n", in: webView)
        let after = try await value(
            "document.querySelector('.math-inline .katex')?.dataset.probe ?? null", in: webView
        ) as? String
        #expect(after == nil)
        #expect(try await count(of: ".math-inline .katex", in: webView) == 1)
        let edited = try await value(
            #"document.querySelector('.math-inline annotation[encoding="application/x-tex"]').textContent"#,
            in: webView
        ) as? String
        #expect(edited == "b^2")
    }

    // MARK: Serving

    /// KaTeX's stylesheet applied (so it was served as CSS, not refused under `nosniff`) and
    /// its fonts loaded from the app scheme under the page's unchanged `font-src`.
    @Test func theKatexStylesheetAppliesAndItsFontsLoad() async throws {
        let webView = try await loadedPreview()
        try await render("$$\n\\sum_{i=1}^{n} i = \\frac{n(n+1)}{2}\n$$\n", in: webView)

        // A rule from katex.min.css: `.katex` sets its own font stack. If the stylesheet had
        // been refused, this would be the page's body font.
        let font = try await value(
            "getComputedStyle(document.querySelector('.katex')).fontFamily", in: webView
        ) as? String
        #expect(font?.contains("KaTeX_Main") == true)
        // The colour is the page's, not KaTeX's: math inherits --fg.
        let colours = try await value("""
        (() => {
          const math = getComputedStyle(document.querySelector('.katex')).color;
          const body = getComputedStyle(document.body).color;
          return JSON.stringify([math, body]);
        })()
        """, in: webView) as? String
        let pair = try JSONDecoder().decode([String].self, from: Data(#require(colours).utf8))
        #expect(pair[0] == pair[1])

        // The fonts the expression needs report loaded, from marsdawn-app: URLs.
        let deadline = ContinuousClock.now + .seconds(10)
        var loaded: [String] = []
        while ContinuousClock.now < deadline {
            let faces = try await value("""
            (() => {
              const used = [...document.fonts].filter((f) => f.status === 'loaded').map((f) => f.family);
              return JSON.stringify(used);
            })()
            """, in: webView) as? String
            loaded = try JSONDecoder().decode([String].self, from: Data(#require(faces).utf8))
            if loaded.contains(where: { $0.hasPrefix("KaTeX_") }) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(loaded.contains(where: { $0.hasPrefix("KaTeX_") }), "no KaTeX font reported loaded: \(loaded)")
    }

    private struct MathElement: Decodable {
        let skipped: Bool
        let done: Bool
        let katex: Int
        let length: Int
    }

    private struct Layout: Decodable {
        let overflows: Bool
        let insideColumn: Bool
        let pageScrolls: Bool
        let inlineDisplay: String
    }

    private struct PrintLayout: Decodable {
        let overflow: String
        let insideColumn: Bool
        let pageScrolls: Bool
    }
}
#endif
