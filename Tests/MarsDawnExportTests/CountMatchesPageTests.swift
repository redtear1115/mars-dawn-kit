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
    private func pageWords(_ markdown: String) async throws -> Int {
        let exporter = DocumentExporter(baseDirectory: nil, allowRemoteImages: false)
        try await exporter.prepare(markdown: markdown, theme: .dawn)
        let text = try await exporter.webView.evaluateJavaScript(#"document.getElementById("content").innerText"#) as? String ?? ""
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
    ]

    @Test(arguments: probes)
    func theCountMatchesThePage(markdown: String) async throws {
        let page = try await pageWords(markdown)
        #expect(page > 0, "precondition: the page shows words")
        #expect(TextStatistics(markdownBody: markdown).words == page, "counted vs shown")
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
