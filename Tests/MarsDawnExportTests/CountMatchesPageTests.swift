#if os(macOS)
import AppKit
import Foundation
import Testing
@testable import MarsDawnExport
@testable import MarsDawnKit

/// The word count matches what the preview page shows (#57, following #19/#55). The oracle is
/// WebKit itself: each probe is rendered in the real preview page, its `innerText` is counted as
/// plain text, and `TextStatistics(markdownBody:)` must give the same number.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(3)))
struct CountMatchesPageTests {
    /// The preview page, not the export page: export opens every `<details>` before it prints
    /// (#414), where the word count follows what the preview shows.
    private func pageWords(_ markdown: String) async throws -> Int {
        let webView = PreviewWKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 800),
                                       configuration: PreviewWebView.makeConfiguration())
        webView.applyContentRuleList(try await PreviewContentRules.ruleList(allowRemoteImages: false))
        #expect(webView.load(URLRequest(url: PreviewSchemeHandler.pageURL(theme: .dawn))) != nil)
        let deadline = ContinuousClock.now + .seconds(20)
        while webView.isLoading, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        _ = try await webView.evaluateJavaScript(
            PreviewWebView.updateScript(html: MarkdownRenderer.render(markdown), lineCount: LineIndex(markdown).lineCount)
        )
        _ = try? await webView.callAsyncJavaScript("return await MarsDawn.idle();", contentWorld: .page)
        let text = try await webView.evaluateJavaScript(#"document.getElementById("content").innerText"#) as? String ?? ""
        return TextStatistics(plainText: text).words
    }

    /// The oracle again, after the test opens every `<details>` (the page's `open` attribute).
    private func pageWords(_ markdown: String, openingDetails: Bool) async throws -> Int {
        let webView = PreviewWKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 800),
                                       configuration: PreviewWebView.makeConfiguration())
        webView.applyContentRuleList(try await PreviewContentRules.ruleList(allowRemoteImages: false))
        #expect(webView.load(URLRequest(url: PreviewSchemeHandler.pageURL(theme: .dawn))) != nil)
        let deadline = ContinuousClock.now + .seconds(20)
        while webView.isLoading, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        _ = try await webView.evaluateJavaScript(
            PreviewWebView.updateScript(html: MarkdownRenderer.render(markdown), lineCount: LineIndex(markdown).lineCount)
        )
        _ = try? await webView.callAsyncJavaScript("return await MarsDawn.idle();", contentWorld: .page)
        if openingDetails {
            _ = try await webView.evaluateJavaScript(#"document.querySelectorAll("details").forEach((d) => { d.open = true; })"#)
        }
        let text = try await webView.evaluateJavaScript(#"document.getElementById("content").innerText"#) as? String ?? ""
        return TextStatistics(plainText: text).words
    }

    /// Each probe pairs what the page hides with words it shows, so a count of zero can't pass.
    nonisolated static let probes = [
        // The `hidden` attribute, on a block, inline, and with the same element nested inside.
        "<div hidden>secret words here</div>\n\nShown text.\n",
        "<div><span hidden>secret</span> visible words</div>\n",
        "<div hidden><div>inner</div>after inner</div>\n\nShown.\n",
        "A <span hidden>b c</span> d.\n",
        // <noscript>: the preview runs scripts, so its content is never shown.
        "<noscript>no script words</noscript>\n\nShown text.\n",
        // Entities in raw HTML: shown decoded; &nbsp; is a space.
        "<div>Tom &amp; Jerry &copy; 2026&nbsp;words</div>\n",
        "<div>caf&#233; &#x4E2D;&#25991;</div>\n",
        // Named entities beyond the common few (#69): each is one character, letter or not.
        "<div>caf&eacute; words</div>\n",
        "<div>na&iuml;ve &Aring;ngstr&ouml;m &frac12; cup</div>\n",
        "<div>thin&ThinSpace;space and a&notin;b set</div>\n",
        // A collapsed <details> shows its summary only; an open one shows its body too.
        "<details><summary>Title here</summary>Body words hidden</details>\n",
        "<details open><summary>Title</summary>Body shown</details>\n",
        // The GitHub form of <details> (#414): the opening tag, the Markdown and the closing tag
        // are separate blocks, written as one element. Without fenced code in the middle: a
        // fence's words are counted whatever the group hides (`visitCodeBlock` does not know),
        // which is deferred to its own issue.
        "<details>\n<summary>Title here</summary>\n\nBody **words** hidden here\n\n- item one\n- item two\n\n</details>\n\nShown text after.\n",
        "<details open>\n<summary>Title</summary>\n\nBody words shown here\n\n</details>\n\nShown text after.\n",
        "<details open>\n<summary>Outer</summary>\n\nouter body\n\n<details>\n<summary>Inner</summary>\n\ninner body hidden\n\n</details>\n\nafter inner\n\n</details>\n\nShown text after.\n",
        "<details>\n<summary>One</summary>\n\nfirst hidden body\n\n</details>\n<details>\n<summary>Two</summary>\n\nsecond hidden body\n\n</details>\n\nShown text after.\n",
        // Already right, kept right.
        "<div class=note>Html wrapped text</div>\n",
        "A <span class=x>red</span> word.\n",
        "<script>var hidden = 1</script>\n\nShown words.\n",
        // Edges: a value that merely contains "hidden", a hidden void element, an unknown entity,
        // and a collapsed <details> inside an open one.
        "<div class=xhidden data-x='hidden'>shown words here</div>\n",
        "<div><img hidden> words after the image</div>\n",
        "<div>a &bogus; b</div>\n",
        "<details open><summary>Outer</summary>outer body<details><summary>Inner</summary>inner body</details>after</details>\n",
        // Callouts (kit #135): the marker line and the default title are not counted, because the
        // page does not show them as text (the title is generated content); an author title is.
        "> [!NOTE]\n> note body words\n",
        "> [!TIP]\n> tip body words\n",
        "> [!IMPORTANT]\n> important body words\n",
        "> [!WARNING]\n> warning body words\n",
        "> [!CAUTION]\n> caution body words\n",
        "> [!note]\n> lower case marker words\n",
        ":::info\ncontainer body words\n:::\n",
        ":::warning Author title here\n\ncontainer body words\n\n:::\n",
        ":::danger Another title\n- item one\n- item two\n:::\n",
        // An unknown type is text, marker included.
        ":::nope\nunknown type words\n:::\n",
        // A spoiler is a closed `<details>`: its title shows, its body does not.
        ":::spoiler Spoiler title here\nhidden spoiler body words\n:::\n\nShown after.\n",
        ":::info\nbefore\n\n:::spoiler Inner spoiler\nhidden words\n:::\n\nafter\n:::\n",
    ]

    @Test(arguments: probes)
    func theCountMatchesThePage(markdown: String) async throws {
        let page = try await pageWords(markdown)
        #expect(page > 0, "precondition: the page shows words")
        #expect(TextStatistics(markdownBody: markdown).words == page, "counted vs shown")
    }

    /// An opened spoiler adds exactly its body's words to the closed one's count, on the page.
    @Test func anOpenedSpoilerAddsItsBody() async throws {
        let markdown = ":::spoiler Spoiler title here\nhidden spoiler body words\n:::\n\nShown after.\n"
        let closed = try await pageWords(markdown)
        let opened = try await pageWords(markdown, openingDetails: true)
        #expect(closed > 0, "precondition: the page shows words")
        #expect(opened - closed == 4, "the body is four words: \(closed) closed, \(opened) opened")
        #expect(TextStatistics(markdownBody: markdown).words == closed, "counted vs shown, closed")
    }

    /// <select>: measured, whatever the page shows of it.
    @Test func aSelectCountsWhatThePageShows() async throws {
        let markdown = "<div><select><option>alpha</option><option>beta</option></select> chosen words</div>\n"
        let page = try await pageWords(markdown)
        #expect(page > 0)
        #expect(TextStatistics(markdownBody: markdown).words == page, "counted vs shown")
    }

    /// <textarea>: counted, on purpose, although `innerText` leaves form controls out: the reader
    /// sees the text in the box.
    @Test func textInATextareaIsCountedBecauseTheReaderSeesIt() {
        #expect(TextStatistics(markdownBody: "<div><textarea>typed words here</textarea></div>\n").words == 3)
    }
}
#endif
