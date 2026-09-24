#if os(macOS)
import AppKit
import Testing
import WebKit
@testable import MarsDawnExport
@testable import MarsDawnKit

/// #100: `DocumentExporter` lets the caller pass a localised `footnoteBackLabel`, threaded down to
/// `MarkdownRenderer.Options` the way the preview and Quick Look already do. The label isn't
/// visible on the page (it's the footnote back-link's `aria-label`), so these read it out of the
/// exported page's DOM rather than off rendered pixels or extracted PDF text.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct FootnoteBackLabelTests {
    static let markdown = "Text.[^a]\n\n[^a]: The note.\n"

    private func ariaLabels(_ exporter: DocumentExporter) async throws -> [String] {
        try await exporter.webView.evaluateJavaScript(
            #"[...document.querySelectorAll(".footnote-backref")].map((a) => a.getAttribute("aria-label"))"#
        ) as? [String] ?? []
    }

    @Test func defaultLabelIsUnchanged() async throws {
        let exporter = DocumentExporter(baseDirectory: nil, allowRemoteImages: false)
        try await exporter.prepare(markdown: Self.markdown, theme: .dawn)
        #expect(try await ariaLabels(exporter) == ["Back to reference 1"])
    }

    @Test func customLabelAppearsInTheExportedPage() async throws {
        let exporter = DocumentExporter(baseDirectory: nil, allowRemoteImages: false)
        try await exporter.prepare(markdown: Self.markdown, theme: .dawn, footnoteBackLabel: "回到引用處")
        #expect(try await ariaLabels(exporter) == ["回到引用處 1"])
    }

    @Test func customLabelIsEscaped() async throws {
        // Checked two ways: the HTML string MarkdownRenderer produces (what DocumentExporter.
        // prepare pushes into the page), before any WebKit parses or re-serializes it -- macOS
        // 15's WebKit doesn't escape `<`/`>` when it serializes an attribute's value back out
        // through `outerHTML`, even though the value it holds is correctly unescaped, so reading
        // the markup back out of the DOM isn't OS-independent. The HTML this renderer writes is.
        let html = MarkdownRenderer.render(Self.markdown, options: .init(footnoteBackLabel: "<b>&\"</b>"))
        #expect(html.contains(#"aria-label="&lt;b&gt;&amp;&quot;&lt;/b&gt; 1""#), "\(html)")

        // The DOM API hands back the decoded attribute value, confirming the page WebKit built
        // from that HTML carries the right (unescaped, as an attribute value should be) label.
        let exporter = DocumentExporter(baseDirectory: nil, allowRemoteImages: false)
        try await exporter.prepare(markdown: Self.markdown, theme: .dawn, footnoteBackLabel: "<b>&\"</b>")
        #expect(try await ariaLabels(exporter) == ["<b>&\"</b> 1"])
    }

    /// `run`/`runReportingDiagrams`/`exportPDF` all default to the renderer's own default and all
    /// forward a custom value to `prepare`, so a document without footnotes is unaffected either
    /// way and the plumbing compiles for every entry point.
    @Test func defaultMatchesTheRenderersOwnDefault() {
        #expect(MarkdownRenderer.Options().footnoteBackLabel == "Back to reference")
    }

    /// `exportPDF`'s own `footnoteBackLabel` parameter reaches `prepare` through
    /// `runReportingDiagrams`: the whole PDF pipeline, not just `prepare` called directly, and it
    /// still produces a normal, one-page PDF for this short document.
    @Test func exportPDFThreadsTheCustomLabelThrough() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("marsdawn-footnote-label-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try await DocumentExporter.exportPDF(
            markdown: Self.markdown, to: url, theme: .dawn, baseDirectory: nil, allowRemoteImages: false,
            footnoteBackLabel: "回到引用處"
        )
        #expect(result.pageCount == 1)
    }
}
#endif
