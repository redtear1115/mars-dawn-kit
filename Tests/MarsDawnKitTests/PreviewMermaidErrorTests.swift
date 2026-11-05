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

    /// verifier round 1, defect 1: editing above a broken diagram moves its `data-line` (via
    /// `copyLineNumbers`, when `update()` reuses the block because `blockKey` ignores line
    /// numbers), but the diagram itself is unchanged, so `renderMermaid` never reruns. The
    /// mapped line has to move with the block's `data-line` anyway, without re-rendering.
    @Test func theMappedLineFollowsAnEditAboveTheDiagramWithoutRerendering() async throws {
        let webView = try await loadedPreview()
        try await render(document(invalid, valid), in: webView)
        let before = try await blockState(0, in: webView)
        #expect(before["fenceLine"] as? String == "3")
        #expect(before["docLine"] as? String == "5")

        // The same update() path the app uses for every keystroke: two new lines above the
        // fixture push its fence from document line 3 to 5, and the invalid line from 5 to 7.
        try await render("New line.\n\n" + document(invalid, valid), in: webView)
        let after = try await blockState(0, in: webView)
        #expect(after["fenceLine"] as? String == "5", "the block was reused, and its own data-line moved")
        #expect(after["docLine"] as? String == "7", "the note's mapped line moves with it")
        let note = try #require(after["note"] as? String)
        #expect(note.hasPrefix("Parse error on line 7:"))
        #expect(!note.contains("line 5"), "the stale mapped line isn't left behind")
        #expect(after["dataError"] as? String == note)
    }

    /// verifier round 1, defect 2: a fence with no `data-line` at all (MarkdownRenderer gives
    /// none inside a footnote's own text) must not be mapped to line 0. `Number(null)` and
    /// `Number("")` are both `0`, which `Number.isFinite` accepts, so the bug showed up as a
    /// wrong but present `data-doc-line`, not as a crash — this checks for its absence.
    @Test func aFenceWithNoKnownLineGetsNoMappedLine() async throws {
        let webView = try await loadedPreview()
        // Every continuation line, including the diagram's own, needs the footnote's 4-space
        // indent, or it falls out of the footnote and back onto the document's own lines.
        let indentedFence = "    ```mermaid\n"
            + invalid.split(separator: "\n", omittingEmptySubsequences: false).dropLast()
                .map { "    \($0)\n" }.joined()
            + "    ```\n"
        let markdown = "Used[^m].\n\n[^m]: See below.\n\n\(indentedFence)"
        try await render(markdown, in: webView)

        let bad = try await blockState(0, in: webView)
        #expect(bad["error"] as? Bool == true)
        #expect(bad["fenceLine"] == nil || bad["fenceLine"] is NSNull, "the fence in a footnote carries no data-line")
        #expect(bad["docLine"] == nil || bad["docLine"] is NSNull, "so there's nothing to map it to")
        let note = try #require(bad["note"] as? String)
        #expect(note.hasPrefix("Parse error on line 2:"), "shown exactly as Mermaid sent it, unmapped")
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
        // The script element reports an error instead of loading, as a bundle that won't load does.
        _ = try await value("""
        (() => {
          document.head.appendChild = (node) => { setTimeout(() => node.onerror(new Event("error"))); return node; };
          return 0;
        })()
        """, in: webView)
        _ = try await value("(() => { MarsDawn.setTheme('elegant'); return 0; })()", in: webView)
        try await render(document(valid, valid), in: webView)

        let block = try await blockState(0, in: webView)
        #expect(block["error"] as? Bool == true)
        #expect(block["sourceShown"] as? Bool == true)
        let text = try await value("document.getElementById('content').innerText", in: webView) as? String ?? ""
        #expect(text.contains("AFTERINVALID03"))
        #expect(try await value("document.documentElement.dataset.theme", in: webView) as? String == "elegant")
        #expect(try await value(##"getComputedStyle(document.querySelector("#content .mermaid-source")).visibility"##, in: webView) as? String == "visible")
    }

    // MARK: Loaded only when needed (kit #265)

    private var bundleIsPresent: String {
        #"[typeof mermaid !== "undefined", document.querySelectorAll('script[src$="mermaid.min.js"]').length]"#
    }

    @Test func aDocumentWithNoDiagramNeverLoadsTheBundle() async throws {
        let webView = try await loadedPreview()
        try await render("# Title\n\nJust words.\n", in: webView)
        _ = try await value("(() => { MarsDawn.setTheme('elegant'); return 0; })()", in: webView)

        let state = try await value(bundleIsPresent, in: webView) as? [Any]
        #expect(state?.first as? Bool == false)
        #expect(state?.last as? Int == 0)
        let text = try await value("document.getElementById('content').innerText", in: webView) as? String ?? ""
        #expect(text.contains("Just words."), "positive control: the page rendered")
    }

    @Test func aDiagramLoadsTheBundleOnceAndIdleWaitsForTheDrawing() async throws {
        let webView = try await loadedPreview()
        try await render(document(valid, valid), in: webView)

        #expect(try await blockState(0, in: webView)["svg"] as? Int == 1)
        #expect(try await blockState(1, in: webView)["svg"] as? Int == 1)
        #expect((try await value(bundleIsPresent, in: webView) as? [Any])?.first as? Bool == true)
        #expect(try await value("document.documentElement.classList.contains('mermaid-loading')", in: webView) as? Bool == false)

        try await render(document(valid.replacingOccurrences(of: "VALIDNODE04", with: "SECOND06"), valid), in: webView)
        #expect(try await value(#"document.querySelectorAll('script[src$="mermaid.min.js"]').length"#, in: webView) as? Int == 1)
    }

    /// The first diagram can arrive long after the page did, from an edit.
    @Test func aDiagramAddedByAnEditIsDrawn() async throws {
        let webView = try await loadedPreview()
        try await render("Only words.\n", in: webView)
        #expect(try await blockCount(in: webView) == 0)

        try await render("Only words.\n\n```mermaid\n\(valid)```\n", in: webView)
        #expect(try await blockState(0, in: webView)["svg"] as? Int == 1)
    }

    /// While the bundle is on its way a diagram holds its space and doesn't flash its source.
    @Test func aDiagramKeepsItsSourceOutOfSightWhileTheBundleLoads() async throws {
        let webView = try await loadedPreview()
        _ = try await value("""
        (() => {
          const append = document.head.appendChild.bind(document.head);
          document.head.appendChild = (node) => { window.__hold = () => append(node); return node; };
          return 0;
        })()
        """, in: webView)
        _ = try await webView.evaluateJavaScript(
            PreviewWebView.updateScript(html: MarkdownRenderer.render(document(valid, valid)), lineCount: 40)
        )
        let source = ##"getComputedStyle(document.querySelector("#content .mermaid-source")).visibility"##
        #expect(try await value(source, in: webView) as? String == "hidden")

        _ = try await value("(() => { window.__hold(); return 0; })()", in: webView)
        _ = try? await webView.callAsyncJavaScript("return await MarsDawn.idle();", contentWorld: .page)
        #expect(try await blockState(0, in: webView)["svg"] as? Int == 1)
        #expect(try await value("document.documentElement.classList.contains('mermaid-loading')", in: webView) as? Bool == false)
    }

    /// A theme picked before the bundle arrives is the one the first diagram is drawn in.
    @Test func theFirstDiagramUsesTheThemeChosenBeforeTheBundleLoaded() async throws {
        let webView = try await loadedPreview()
        _ = try await value("(() => { MarsDawn.setTheme('vivid'); return 0; })()", in: webView)
        try await render(document(valid, valid), in: webView)
        #expect(try await blockState(0, in: webView)["svg"] as? Int == 1)
        let configured = try await value("mermaid.mermaidAPI.getConfig().themeVariables.primaryColor", in: webView) as? String
        let palette = try await value(
            #"getComputedStyle(document.documentElement).getPropertyValue("--mm-node").trim()"#, in: webView
        ) as? String
        #expect(palette?.isEmpty == false, "positive control: the theme has this colour")
        #expect(configured?.lowercased() == palette?.lowercased())
    }

    /// A document can name an element `mermaid`, and until the bundle arrives that element is
    /// what the global `mermaid` means. It must not pass for the bundle.
    @Test func anElementNamedMermaidIsNotTheBundle() async throws {
        let webView = try await loadedPreview()
        try await render("<div id=\"mermaid\">Words.</div>\n", in: webView)
        #expect(try await value(#"typeof mermaid"#, in: webView) as? String == "object", "positive control: the name resolves")
        _ = try await value("(() => { MarsDawn.setTheme('elegant'); return 0; })()", in: webView)
        #expect(try await value("document.documentElement.dataset.theme", in: webView) as? String == "elegant")

        try await render("<div id=\"mermaid\">Words.</div>\n\n```mermaid\n\(valid)```\n", in: webView)
        #expect(try await blockState(0, in: webView)["svg"] as? Int == 1)
    }

    /// The common way to get there: a heading's id comes from its text, so `# Mermaid` is enough.
    /// The bundle then arrives to a page that was never misconfigured.
    @Test func aHeadingCalledMermaidIsNotTheBundle() async throws {
        let webView = try await loadedPreview()
        try await render("# Mermaid\n\nJust words.\n", in: webView)
        #expect(try await value("document.querySelector('h1').id", in: webView) as? String == "mermaid", "positive control")
        _ = try await value("(() => { MarsDawn.setTheme('elegant'); return 0; })()", in: webView)

        try await render("# Mermaid\n\nJust words.\n\n```mermaid\n\(valid)```\n", in: webView)
        #expect(try await blockState(0, in: webView)["svg"] as? Int == 1)
        #expect(try await value("mermaid.mermaidAPI.getConfig().theme", in: webView) as? String == "base")
    }

    /// With that heading and a bundle that fails, every diagram still settles, so export doesn't wait.
    @Test func aHeadingCalledMermaidAndAFailedBundleSettleEveryDiagram() async throws {
        let webView = try await loadedPreview()
        _ = try await value("""
        (() => {
          document.head.appendChild = (node) => { setTimeout(() => node.onerror(new Event("error"))); return node; };
          return 0;
        })()
        """, in: webView)
        try await render("# Mermaid\n\n" + document(valid, valid), in: webView)
        for index in 0...1 {
            #expect(try await blockState(index, in: webView)["error"] as? Bool == true, "block \(index)")
        }
    }

    /// A diagram past the 100-diagram cap says its source is shown, so it is, even while the bundle
    /// is on its way for the ones under the cap.
    @Test func aDiagramPastTheCapShowsItsSourceWhileTheBundleLoads() async throws {
        let webView = try await loadedPreview()
        try await holdBundle(in: webView)
        let diagrams = (0...100).map { "```mermaid\ngraph TD\n  A\($0) --> B\($0)\n```\n" }.joined(separator: "\n")
        _ = try await webView.evaluateJavaScript(
            PreviewWebView.updateScript(html: MarkdownRenderer.render(diagrams), lineCount: 500)
        )
        let visibility = { (index: Int) in
            ##"getComputedStyle(document.querySelectorAll("#content .mermaid-source")[\##(index)]).visibility"##
        }
        #expect(try await value("document.documentElement.classList.contains('mermaid-loading')", in: webView) as? Bool == true)
        #expect(try await value(visibility(0), in: webView) as? String == "hidden", "positive control")
        #expect(try await value(visibility(100), in: webView) as? String == "visible")
        try await releaseBundle(in: webView)
    }

    /// A theme change while the bundle is on its way is the one the first diagram is drawn in.
    @Test func aThemeChosenWhileTheBundleLoadsIsTheOneUsed() async throws {
        let webView = try await loadedPreview()
        try await holdBundle(in: webView)
        _ = try await webView.evaluateJavaScript(
            PreviewWebView.updateScript(html: MarkdownRenderer.render(document(valid, valid)), lineCount: 40)
        )
        _ = try await value("(() => { MarsDawn.setTheme('vivid'); return 0; })()", in: webView)
        try await releaseBundle(in: webView)
        #expect(try await blockState(0, in: webView)["svg"] as? Int == 1)
        let configured = try await value("mermaid.mermaidAPI.getConfig().themeVariables.primaryColor", in: webView) as? String
        let palette = try await value(
            #"getComputedStyle(document.documentElement).getPropertyValue("--mm-node").trim()"#, in: webView
        ) as? String
        #expect(try await value("document.documentElement.dataset.theme", in: webView) as? String == "vivid")
        #expect(palette?.isEmpty == false, "positive control: the theme has this colour")
        #expect(configured?.lowercased() == palette?.lowercased())
    }

    /// An update that replaces the diagrams while the bundle loads: the bundle loads once, and the
    /// page ends on the new diagram.
    @Test func anUpdateWhileTheBundleLoadsIsTheOneDrawn() async throws {
        let webView = try await loadedPreview()
        try await holdBundle(in: webView)
        let second = valid.replacingOccurrences(of: "VALIDNODE04", with: "SECOND06")
        for source in [valid, second] {
            _ = try await webView.evaluateJavaScript(
                PreviewWebView.updateScript(html: MarkdownRenderer.render("```mermaid\n\(source)```\n"), lineCount: 8)
            )
        }
        try await releaseBundle(in: webView)
        #expect(try await blockCount(in: webView) == 1)
        let state = try await blockState(0, in: webView)
        #expect(state["svg"] as? Int == 1)
        #expect((state["source"] as? String)?.contains("SECOND06") == true)
        #expect(try await value(#"document.querySelectorAll('script[src$="mermaid.min.js"]').length"#, in: webView) as? Int == 1)
        #expect(try await value("document.documentElement.classList.contains('mermaid-loading')", in: webView) as? Bool == false)
    }

    /// `mermaid.initialize` throwing must not cost the first diagram its ending.
    @Test func aFailingInitializeStillSettlesEveryDiagram() async throws {
        let webView = try await loadedPreview()
        _ = try await value("""
        (() => {
          document.head.appendChild = (node) => {
            window.mermaid = { render: () => { throw new Error("no"); }, initialize: () => { throw new Error("no"); } };
            setTimeout(() => node.onload(new Event("load")));
            return node;
          };
          return 0;
        })()
        """, in: webView)
        try await render(document(valid, valid), in: webView)
        for index in 0...1 {
            #expect(try await blockState(index, in: webView)["error"] as? Bool == true, "block \(index)")
        }
    }

    /// The bundle has arrived and `mermaid.render` hasn't finished: the source still stays out of sight.
    @Test func aDiagramKeepsItsSourceOutOfSightUntilItIsDrawn() async throws {
        let webView = try await loadedPreview()
        _ = try await value("""
        (() => {
          document.head.appendChild = (node) => {
            window.mermaid = { initialize() {}, render: () => new Promise((_, reject) => { window.__fail = reject; }) };
            setTimeout(() => node.onload(new Event("load")));
            return node;
          };
          return 0;
        })()
        """, in: webView)
        _ = try await webView.evaluateJavaScript(
            PreviewWebView.updateScript(html: MarkdownRenderer.render(document(valid, valid)), lineCount: 40)
        )
        try await Task.sleep(for: .milliseconds(200))
        let source = ##"getComputedStyle(document.querySelector("#content .mermaid-source")).visibility"##
        #expect(try await value(source, in: webView) as? String == "hidden")
        _ = try await value("(() => { window.__fail(new Error('no')); return 0; })()", in: webView)
        try await Task.sleep(for: .milliseconds(100))
        #expect(try await value(source, in: webView) as? String == "visible", "a failed diagram shows its source")
    }

    /// Stops the bundle's script element from reaching the page until `releaseBundle`.
    private func holdBundle(in webView: WKWebView) async throws {
        _ = try await value("""
        (() => {
          const append = document.head.appendChild.bind(document.head);
          document.head.appendChild = (node) => { window.__hold = () => append(node); return node; };
          return 0;
        })()
        """, in: webView)
    }

    private func releaseBundle(in webView: WKWebView) async throws {
        _ = try await value("(() => { window.__hold(); return 0; })()", in: webView)
        _ = try? await webView.callAsyncJavaScript("return await MarsDawn.idle();", contentWorld: .page)
    }

    /// The script arrives and runs but defines nothing usable: as good as not loading.
    @Test func aBundleThatSetsNothingIsAFailure() async throws {
        let webView = try await loadedPreview()
        _ = try await value("""
        (() => {
          document.head.appendChild = (node) => { setTimeout(() => node.onload(new Event("load"))); return node; };
          return 0;
        })()
        """, in: webView)
        try await render(document(valid, valid), in: webView)
        for index in 0...1 {
            let state = try await blockState(index, in: webView)
            #expect(state["svg"] as? Int == 0)
            #expect(state["error"] as? Bool == true, "settled, so export doesn't wait for it: block \(index)")
        }
        #expect(try await value("document.documentElement.classList.contains('mermaid-loading')", in: webView) as? Bool == false)
    }

    private func blockCount(in webView: WKWebView) async throws -> Int {
        try await value(##"document.querySelectorAll("#content .mermaid-block").length"##, in: webView) as? Int ?? -1
    }
}
#endif
