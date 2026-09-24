#if os(macOS)
import AppKit
import Foundation
import Testing
import WebKit
@testable import MarsDawnKit

/// An invalid Mermaid diagram in the real preview page (redtear1115/mars-dawn#3): it becomes an
/// inline error block that keeps the diagram's source, and it never blanks the page, loses the
/// source or stops the rest of the document from rendering.
///
/// Every "still renders" check sits next to a valid diagram in the same document that does
/// render, so a page where nothing renders at all can't pass.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(3)))
struct PreviewMermaidErrorTests {
    private let invalid = "flowchart LR\n  this is not valid INVALIDSRC02 (((\n"
    private let valid = "flowchart LR\n  A[VALIDNODE04] --> B\n"

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

    private func document(_ first: String, _ second: String) -> String {
        "Before BEFOREINVALID01.\n\n```mermaid\n\(first)```\n\nAfter AFTERINVALID03.\n\n```mermaid\n\(second)```\n"
    }

    /// The error block of the diagram at `index`, as what a reader sees.
    private func blockState(_ index: Int, in webView: WKWebView) async throws -> [String: Any] {
        try await value("""
        (() => {
          const block = document.querySelectorAll("#content .mermaid-block")[\(index)];
          const source = block.querySelector(".mermaid-source");
          const note = block.querySelector(".mermaid-error");
          return {
            error: block.classList.contains("error"),
            svg: block.querySelectorAll(".mermaid-output svg").length,
            source: source ? source.textContent : null,
            sourceShown: source ? getComputedStyle(source).display !== "none" : false,
            note: note ? note.textContent : null,
            noteRole: note ? note.getAttribute("role") : null,
            noteElements: note ? note.children.length : -1,
            prefix: note ? getComputedStyle(note, "::before").content : null,
            docLine: note ? note.getAttribute("data-doc-line") : null,
            dataError: block.getAttribute("data-error"),
            fenceLine: block.getAttribute("data-line"),
          };
        })()
        """, in: webView) as? [String: Any] ?? [:]
    }

    @Test func anInvalidDiagramShowsItsSourceAndAnErrorAndTheRestStillRenders() async throws {
        let webView = try await loadedPreview()
        try await render(document(invalid, valid), in: webView)

        let bad = try await blockState(0, in: webView)
        #expect(bad["error"] as? Bool == true)
        #expect(bad["source"] as? String == invalid, "the source is kept exactly")
        #expect(bad["sourceShown"] as? Bool == true, "and it stays visible")
        #expect((bad["note"] as? String).map { !$0.isEmpty } == true, "the error is a real element with the message")
        #expect(bad["noteRole"] as? String == "note")
        #expect(bad["prefix"] as? String == "\"Mermaid: \"")

        // Positive fixture: the valid diagram after it renders, so this page does render diagrams.
        let good = try await blockState(1, in: webView)
        #expect(good["error"] as? Bool == false)
        #expect(good["svg"] as? Int == 1)
        #expect(good["note"] is NSNull || good["note"] == nil)

        let text = try await value("document.getElementById('content').innerText", in: webView) as? String ?? ""
        #expect(text.contains("BEFOREINVALID01"))
        #expect(text.contains("AFTERINVALID03"))
        #expect(text.contains("INVALIDSRC02"), "the source is readable text on the page")
    }

    /// The message is text, never markup, whatever the diagram's source put into it.
    @Test func theMessageIsInsertedAsText() async throws {
        let webView = try await loadedPreview()
        let hostile = "flowchart LR\n  A[<img src=x onerror=alert(1)>] --> ((( <b>BOLD</b>\n"
        try await render(document(hostile, valid), in: webView)

        let bad = try await blockState(0, in: webView)
        #expect(bad["error"] as? Bool == true)
        #expect(bad["noteElements"] as? Int == 0)
        #expect(try await value("document.querySelectorAll('#content .mermaid-error img, #content .mermaid-error b').length",
                                in: webView) as? Int == 0)
    }

    /// redtear1115/mars-dawn#226: the note shows every line Mermaid gives back, not just the
    /// first, and "line N" (which Mermaid counts from the diagram's own first content line) is
    /// rewritten to the document's line number, which the fixture below fixes at a known value
    /// so the mapping can be checked exactly, not just "some number".
    @Test func theFullMessageIsShownWithTheDocumentLine() async throws {
        let webView = try await loadedPreview()
        // document(): "Before…\n\n```mermaid\n<first>```\n\nAfter…\n\n```mermaid\n<second>```\n"
        // puts the opening fence on line 3, so the diagram's own line 1 ("flowchart LR") is
        // document line 4, and its line 2 (the invalid line) is document line 5.
        try await render(document(invalid, valid), in: webView)

        let bad = try await blockState(0, in: webView)
        #expect(bad["fenceLine"] as? String == "3")
        let note = try #require(bad["note"] as? String)
        // Every line Mermaid sent, not only the first: the offending source line, the `^`
        // column marker, and the "Expecting …" line the old code dropped.
        #expect(note.contains("this is not valid"), "the offending source line is kept")
        #expect(note.contains("^"), "the column marker is kept")
        #expect(note.contains("Expecting"), "the expectation line is kept")
        #expect(note.hasPrefix("Parse error on line 5:"), "line 2 in the diagram is line 5 in the document")
        #expect(!note.contains("line 2"), "the diagram-relative number isn't left in the shown text")
        #expect(bad["docLine"] as? String == "5", "the mapped line is exposed for a future click-to-reveal")

        // The PDF exporter's data-error keeps the same full, mapped message.
        #expect(bad["dataError"] as? String == note)
    }

    /// A message with no "line N" (or a block with no known document line) is shown as Mermaid
    /// sent it, and carries no doc-line attribute for the app to act on.
    @Test func aMessageWithoutALineNumberIsUnmappedButStillShown() async throws {
        let webView = try await loadedPreview()
        // Fewer than the minimum nodes for most Mermaid diagram types raises a message with no
        // "line N" in it (an empty flowchart parses fine but renders nothing useful, so use a
        // diagram type mermaid rejects outright without a line reference).
        let noLineNumber = "this-is-not-a-known-diagram-type\n"
        try await render(document(noLineNumber, valid), in: webView)

        let bad = try await blockState(0, in: webView)
        #expect(bad["error"] as? Bool == true)
        let note = try #require(bad["note"] as? String)
        #expect(!note.isEmpty)
        #expect(bad["docLine"] == nil || bad["docLine"] is NSNull, "no line to map, so no data-doc-line")
    }

    /// Mermaid draws a temporary element for each render; a failed one must not leave it (or
    /// Mermaid's "syntax error" bomb graphic) in the page outside the diagram.
    @Test func aFailedRenderLeavesNothingOutsideTheDocument() async throws {
        let webView = try await loadedPreview()
        try await render(document(invalid, valid), in: webView)
        let stray = try await value("""
        [...document.body.children].filter((el) => el.id !== "content" && el.tagName !== "SCRIPT"
          && (el.querySelector("svg") || el.tagName === "svg" || /^d?mermaid-/.test(el.id))).length
        """, in: webView) as? Int
        #expect(stray == 0)
    }

    /// Fixing the diagram clears the error block; breaking it again brings it back.
    @Test func editingTheDiagramClearsAndRestoresTheError() async throws {
        let webView = try await loadedPreview()
        try await render(document(invalid, valid), in: webView)
        #expect(try await blockState(0, in: webView)["error"] as? Bool == true)

        try await render(document(valid.replacingOccurrences(of: "VALIDNODE04", with: "FIXED05"), valid), in: webView)
        let fixed = try await blockState(0, in: webView)
        #expect(fixed["error"] as? Bool == false)
        #expect(fixed["svg"] as? Int == 1)
        #expect(try await value("document.querySelectorAll('#content .mermaid-error').length", in: webView) as? Int == 0)

        try await render(document(invalid, valid), in: webView)
        #expect(try await blockState(0, in: webView)["note"] is String)
    }

    /// If the Mermaid bundle didn't load, diagrams fall back to their source and everything else
    /// renders, including a theme change.
    @Test func withoutMermaidTheRestOfThePageStillRenders() async throws {
        let webView = try await loadedPreview()
        _ = try await value("(() => { window.mermaid = undefined; return 0; })()", in: webView)
        _ = try await value("(() => { MarsDawn.setTheme('elegant'); return 0; })()", in: webView)
        try await render(document(valid, valid), in: webView)

        let block = try await blockState(0, in: webView)
        #expect(block["error"] as? Bool == true)
        #expect(block["sourceShown"] as? Bool == true)
        let text = try await value("document.getElementById('content').innerText", in: webView) as? String ?? ""
        #expect(text.contains("AFTERINVALID03"))
        #expect(try await value("document.documentElement.dataset.theme", in: webView) as? String == "elegant")
    }
}
#endif
