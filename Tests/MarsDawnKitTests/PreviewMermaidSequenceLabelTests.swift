#if os(macOS)
import AppKit
import Foundation
import Testing
import WebKit
@testable import MarsDawnKit

/// redtear1115/mars-dawn-kit#112: a sequence diagram message between non-adjacent participants
/// centres its label over the arrow, and Mermaid draws the crossed lifelines through the text
/// because `.messageText` has no background of its own. The preview stylesheet gives it a halo
/// (a stroke painted behind the fill, in the page's own background colour) so the lifeline is
/// knocked out under the label instead of crossing it.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct PreviewMermaidSequenceLabelTests {
    private let sequence = """
    sequenceDiagram
      participant A
      participant B
      participant C
      A->>C: CROSSINGMESSAGE07
    """

    private let flowchart = "flowchart LR\n  A[NODELABEL08] --> B\n"

    private func loadedPreview(theme: PreviewTheme = .dawn, dark: Bool = false) async throws -> PreviewWKWebView {
        let webView = PreviewWKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 800),
                                       configuration: PreviewWebView.makeConfiguration())
        // The web view's own appearance drives `prefers-color-scheme`, exactly as
        // PreviewThemeSwitchTests does; no system setting is touched.
        webView.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        webView.applyContentRuleList(try await PreviewContentRules.ruleList(allowRemoteImages: false))
        #expect(webView.load(URLRequest(url: PreviewSchemeHandler.pageURL(theme: theme))) != nil)
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

    private func messageTextStyle(in webView: WKWebView) async throws -> [String: Any] {
        try await value("""
        (() => {
          const text = document.querySelector('.mermaid-output svg .messageText');
          if (!text) return null;
          const cs = getComputedStyle(text);
          return {
            paintOrder: cs.paintOrder,
            stroke: cs.stroke,
            strokeWidth: cs.strokeWidth,
            strokeLinejoin: cs.strokeLinejoin,
            content: text.textContent,
          };
        })()
        """, in: webView) as? [String: Any] ?? [:]
    }

    @Test func messageTextHasAStrokeHaloInThePageBackground() async throws {
        let webView = try await loadedPreview()
        try await render("```mermaid\n\(sequence)\n```\n", in: webView)

        let style = try await messageTextStyle(in: webView)
        #expect(style["content"] as? String == "CROSSINGMESSAGE07", "found the real message label, not some other text")
        #expect(style["paintOrder"] as? String == "stroke", "the stroke is painted first, under the fill")
        #expect(style["strokeLinejoin"] as? String == "round")
        // 4px, in a canvas whose default unit is px.
        #expect(style["strokeWidth"] as? String == "4px")

        let bg = try await value("getComputedStyle(document.documentElement).getPropertyValue('--bg').trim()", in: webView) as? String
        let expectedStroke = try #require(try await value(
            "(() => { const d = document.createElement('div'); d.style.color = '\(bg ?? "")'; document.body.appendChild(d); const rgb = getComputedStyle(d).color; d.remove(); return rgb; })()",
            in: webView
        ) as? String)
        #expect(style["stroke"] as? String == expectedStroke, "the halo is the theme's own page background, not a fixed colour")
    }

    @Test func theHaloFollowsTheThemeAndDarkMode() async throws {
        for theme in PreviewTheme.all {
            for dark in [false, true] {
                let webView = try await loadedPreview(theme: theme, dark: dark)
                try await render("```mermaid\n\(sequence)\n```\n", in: webView)
                let style = try await messageTextStyle(in: webView)
                #expect(style["paintOrder"] as? String == "stroke", "\(theme.id) dark=\(dark)")

                let bg = try await value("getComputedStyle(document.documentElement).getPropertyValue('--bg').trim()", in: webView) as? String
                let expectedStroke = try #require(try await value(
                    "(() => { const d = document.createElement('div'); d.style.color = '\(bg ?? "")'; document.body.appendChild(d); const rgb = getComputedStyle(d).color; d.remove(); return rgb; })()",
                    in: webView
                ) as? String)
                #expect(style["stroke"] as? String == expectedStroke, "\(theme.id) dark=\(dark): halo tracks --bg")
            }
        }
    }

    /// Only sequence diagram message labels get the halo; a flowchart node label is untouched.
    @Test func otherDiagramTextIsNotGivenTheHalo() async throws {
        let webView = try await loadedPreview()
        try await render("```mermaid\n\(flowchart)\n```\n", in: webView)

        let style = try await value("""
        (() => {
          const label = [...document.querySelectorAll('.mermaid-output svg text, .mermaid-output svg .nodeLabel')]
            .find((el) => el.textContent.includes('NODELABEL08'));
          if (!label) return null;
          const cs = getComputedStyle(label);
          return { paintOrder: cs.paintOrder, stroke: cs.stroke };
        })()
        """, in: webView) as? [String: Any]
        let s = try #require(style)
        #expect(s["paintOrder"] as? String != "stroke", "flowchart labels keep their normal paint order")
    }
}
#endif
