#if os(macOS)
import AppKit
import Foundation
import PDFKit
import Testing
import WebKit
@testable import MarsDawnExport
@testable import MarsDawnKit

/// Math on the export path: the same offscreen page, so KaTeX renders there too, the readiness
/// wait only passes once every expression has been dealt with, and the PDF's text layer holds
/// typeset math rather than the TeX source.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(5)))
struct MathExportTests {
    static let markdown = """
    # Math

    Inline $a^2 + b^2 = c^2$ in a sentence.

    $$
    \\sum_{i=1}^{n} i = \\frac{n(n+1)}{2}
    $$

    Done.
    """

    @Test func thePreparedExportPageHasRenderedMath() async throws {
        let exporter = DocumentExporter(baseDirectory: nil, allowRemoteImages: false)
        try await exporter.prepare(markdown: Self.markdown, theme: .dawn)
        let webView = exporter.webView

        let state = try #require(try await webView.evaluateJavaScript("""
        (() => {
          const content = document.getElementById("content");
          return JSON.stringify({
            inline: content.querySelectorAll(".math-inline .katex").length,
            block: content.querySelectorAll(".math-block .katex-display").length,
            pending: content.querySelectorAll(".math-inline:not(.math-done), .math-block:not(.math-done)").length,
            dollars: content.textContent.includes("$"),
            fonts: document.fonts.status,
          });
        })()
        """) as? String)
        let page = try JSONDecoder().decode(PageState.self, from: Data(state.utf8))
        #expect(page.inline == 1)
        #expect(page.block == 1)
        // `waitForContent` returned, so nothing was left pending.
        #expect(page.pending == 0)
        // No `$` survives anywhere in the laid-out text: the delimiters went with the math.
        #expect(!page.dollars)
        #expect(page.fonts == "loaded")
    }

    /// The readiness wait is the one gate: a page with an expression that will never render
    /// still has to finish, because preview.js marks it done all the same.
    @Test func theWaitFinishesWhenAnExpressionIsSkipped() async throws {
        let exporter = DocumentExporter(baseDirectory: nil, allowRemoteImages: false)
        try await exporter.prepare(markdown: "Text.", theme: .dawn)
        let webView = exporter.webView

        // Straight to the page, as the renderer can't make one this long: an expression over
        // the length limit, one over the per-update count, and one KaTeX refuses.
        let long = String(repeating: "x", count: MathExtractor.maxExpressionLength + 1)
        let many = (0..<2100).map { #"<span class="math-inline">x_{\#($0)}</span>"# }.joined()
        let html = #"<p data-line="1"><span class="math-inline">\#(long)</span>"#
            + #"<span class="math-inline">{x</span>\#(many)</p>"#
        _ = try await webView.evaluateJavaScript(PreviewWebView.updateScript(html: html, lineCount: 1))

        // The same script `waitForContent` polls. It has to be true already, and stay true.
        let ready = try await webView.callAsyncJavaScript("""
        const mathReady = document.querySelectorAll(".math-inline:not(.math-done), .math-block:not(.math-done)").length === 0;
        return mathReady;
        """, contentWorld: .page) as? Bool
        #expect(ready == true)

        // And the exporter's own wait returns rather than timing out.
        try await exporter.waitForContent(until: .now + .seconds(20))

        let skipped = try await webView.evaluateJavaScript(
            #"document.querySelectorAll(".math-skipped").length"#
        ) as? Int
        // 2102 spans: the over-long one is skipped without counting towards the cap, the next
        // 2000 render (`{x` among them, as an error), and the last 101 are past the cap.
        #expect(skipped == 102)
    }

    /// The whole path, ending in a real PDF: its text layer has the typeset math and no TeX
    /// delimiter left over.
    @Test func exportedPDFTextHasNoRawDollars() async throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("marsdawn-math-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try await DocumentExporter.exportPDF(
            markdown: Self.markdown, to: url, theme: .dawn, baseDirectory: nil, allowRemoteImages: false
        )
        #expect(result.pageCount >= 1)
        #expect(result.diagramErrors.isEmpty)

        let document = try #require(PDFDocument(url: url))
        let text = (0..<document.pageCount).compactMap { document.page(at: $0)?.string }.joined()
        #expect(!text.contains("$"))
        #expect(text.contains("Math"))
        #expect(text.contains("Done."))
        // The TeX itself never reaches the paper either.
        #expect(!text.contains("\\frac"))
        #expect(!text.contains("\\sum"))
    }

    /// Each expression reaches the PDF's text layer once (#16). KaTeX also writes a MathML copy
    /// for screen readers, hidden on screen by clipping; printed, WebKit still drew its text,
    /// invisibly, so the text layer had every expression twice -- the MathML one in Mathematical
    /// Italic letters (𝐸, 𝑥) set in STIXTwoMath. The visible math is the positive fixture: its
    /// text and KaTeX's own fonts must still be there.
    @Test func exportedPDFTextHasEachExpressionOnce() async throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("marsdawn-math-once-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let markdown = "Inline $E=mc^2$ here.\n\n$$\n\\int_0^1 x\\,dx = \\frac{1}{2}\n$$\n"
        _ = try await DocumentExporter.exportPDF(
            markdown: markdown, to: url, theme: .dawn, baseDirectory: nil, allowRemoteImages: false
        )

        let document = try #require(PDFDocument(url: url))
        let text = (0..<document.pageCount).compactMap { document.page(at: $0)?.string }.joined()
        let mathAlphanumerics = text.unicodeScalars.filter { (0x1D400...0x1D7FF).contains($0.value) }
        #expect(mathAlphanumerics.isEmpty, "no MathML copy: \(String(String.UnicodeScalarView(mathAlphanumerics)))")
        #expect(text.filter { $0 == "∫" }.count == 1, "the integral once: \(text)")
        #expect(text.contains("mc2") && text.contains("dx"), "the visible math is in the text layer")

        let bytes = try Data(contentsOf: url)
        #expect(bytes.range(of: Data("STIXTwoMath".utf8)) == nil, "the MathML's font isn't embedded")
        #expect(bytes.range(of: Data("KaTeX_Math".utf8)) != nil && bytes.range(of: Data("KaTeX_Main".utf8)) != nil, "KaTeX's fonts still are")
    }

    /// On screen the MathML stays: it's what a screen reader reads in the live preview. The rule
    /// that drops it from the PDF is print-only.
    @Test func theMathMLStaysOnScreen() async throws {
        let exporter = DocumentExporter(baseDirectory: nil, allowRemoteImages: false)
        try await exporter.prepare(markdown: "Inline $E=mc^2$ here.", theme: .dawn)
        let state = try #require(try await exporter.webView.evaluateJavaScript("""
        (() => {
          const mathml = document.querySelector(".katex-mathml");
          return mathml ? getComputedStyle(mathml).display + "|" + mathml.querySelectorAll("math").length : "absent";
        })()
        """) as? String)
        #expect(state != "absent", "precondition: KaTeX wrote MathML")
        #expect(!state.hasPrefix("none|"), "the MathML is displayed on screen: \(state)")
        #expect(state.hasSuffix("|1"))
    }

    private struct PageState: Decodable {
        let inline: Int
        let block: Int
        let pending: Int
        let dollars: Bool
        let fonts: String
    }
}
#endif
