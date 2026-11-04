#if os(macOS)
import AppKit
import Foundation
import Testing
import WebKit
@testable import MarsDawnKit

/// Printing the preview page itself (⌘P in the app, not the exporter), redtear1115/mars-dawn#300:
/// a `<details>` the reader left collapsed still prints its content, its summary prints as a bold
/// block with no triangle, and front matter stays hidden. With the exporter's as-written class on
/// `<html>`, a collapsed one prints its summary alone.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct DetailsPrintPageTests {
    static let markdown = """
        ---
        title: FM-SECRET
        ---

        <details>
        <summary>CLOSED-SUMMARY</summary>

        CLOSED-BODY

        </details>

        <details open>
        <summary>OPEN-SUMMARY</summary>

        OPEN-BODY

        </details>
        """

    static func page() async throws -> PreviewWKWebView {
        let webView = PreviewWKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 800), configuration: PreviewWebView.makeConfiguration())
        webView.applyContentRuleList(try await PreviewContentRules.ruleList(allowRemoteImages: false))
        #expect(webView.load(URLRequest(url: PreviewSchemeHandler.pageURL(theme: .dawn))) != nil)
        let deadline = ContinuousClock.now + .seconds(20)
        while webView.isLoading, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        _ = try await webView.evaluateJavaScript(
            PreviewWebView.updateScript(html: MarkdownRenderer.render(markdown), lineCount: LineIndex(markdown).lineCount)
        )
        return webView
    }

    struct State: Decodable, Equatable {
        let closedBody: Bool
        let openBody: Bool
        let closedSummary: Bool
        let summaryDisplay: String
        let summaryWeight: String
        let frontMatter: String
        let closedIsClosed: Bool
    }

    static func state(_ webView: PreviewWKWebView) async throws -> State {
        let text = try #require(try await webView.evaluateJavaScript("""
            (() => {
              const p = (word) => [...document.querySelectorAll("#content p")].find((e) => e.textContent.trim() === word);
              const closed = [...document.querySelectorAll("details:not(.front-matter)")].find((d) => !d.open);
              const summary = closed.querySelector("summary");
              return JSON.stringify({
                closedBody: p("CLOSED-BODY").checkVisibility() && p("CLOSED-BODY").getBoundingClientRect().height > 0,
                openBody: p("OPEN-BODY").checkVisibility() && p("OPEN-BODY").getBoundingClientRect().height > 0,
                closedSummary: summary.checkVisibility() && summary.getBoundingClientRect().height > 0,
                summaryDisplay: getComputedStyle(summary).display,
                summaryWeight: getComputedStyle(summary).fontWeight,
                frontMatter: getComputedStyle(document.querySelector("details.front-matter")).display,
                closedIsClosed: !closed.open,
              });
            })()
            """) as? String)
        return try JSONDecoder().decode(State.self, from: Data(text.utf8))
    }

    @Test func aCollapsedDetailsPrintsItsContentUnlessMarkedAsWritten() async throws {
        let webView = try await Self.page()

        // Control: on screen, the collapsed one hides its content and keeps its triangle.
        let screen = try await Self.state(webView)
        #expect(screen.closedIsClosed)
        #expect(!screen.closedBody, "positive control: collapsed on screen")
        #expect(screen.openBody)
        #expect(screen.summaryDisplay != "block")

        webView.mediaType = "print"
        let printed = try await Self.state(webView)
        #expect(printed.closedIsClosed, "print CSS opens nothing in the DOM")
        #expect(printed.closedBody, "⌘P prints a collapsed block's content")
        #expect(printed.openBody)
        #expect(printed.closedSummary)
        #expect(printed.summaryDisplay == "block", "a block summary has no disclosure triangle")
        #expect(printed.summaryWeight == "600")
        #expect(printed.frontMatter == "none")

        _ = try await webView.evaluateJavaScript(#"document.documentElement.classList.add("marsdawn-details-as-written"); 0"#)
        let asWritten = try await Self.state(webView)
        #expect(!asWritten.closedBody, "as-written: a collapsed block prints its summary alone")
        #expect(asWritten.openBody)
        #expect(asWritten.closedSummary)
        #expect(asWritten.summaryDisplay == "block")
        #expect(asWritten.frontMatter == "none")
    }
}
#endif
