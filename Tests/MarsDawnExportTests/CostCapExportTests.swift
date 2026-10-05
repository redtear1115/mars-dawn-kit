#if os(macOS)
import AppKit
import Foundation
import PDFKit
import Testing
import WebKit
@testable import MarsDawnExport
@testable import MarsDawnKit

/// A document over the page's Mermaid limit (mars-dawn-kit#95) still exports: the readiness wait
/// accepts a skipped diagram, and the PDF has its source and the note rather than a gap.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(5)))
struct CostCapExportTests {
    private let markdown = (0..<102).map {
        "```mermaid\nflowchart LR\n  A\($0)[CAPNODE\($0)] --> B\n```\n"
    }.joined(separator: "\n")

    @Test func theWaitFinishesWhenADiagramIsSkipped() async throws {
        let exporter = DocumentExporter(baseDirectory: nil, allowRemoteImages: false)
        try await exporter.prepare(markdown: markdown, theme: .dawn)
        let skipped = try await exporter.webView.evaluateJavaScript(
            #"document.querySelectorAll(".mermaid-block.skipped").length"#
        ) as? Int
        #expect(skipped == 2)
        try await exporter.waitForContent(until: .now + .seconds(10))
    }

    @Test func theExportedPDFHasTheSkippedSourceAndNote() async throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("marsdawn-cap-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try await DocumentExporter.exportPDF(
            markdown: markdown, to: url, theme: .dawn, baseDirectory: nil, allowRemoteImages: false
        )
        #expect(result.pageCount >= 1)
        #expect(result.diagramErrors.isEmpty)

        let document = try #require(PDFDocument(url: url))
        let text = (0..<document.pageCount).compactMap { document.page(at: $0)?.string }.joined()
        // The last two diagrams are over the limit: their source is printed, with the note.
        #expect(text.contains("flowchart LR"))
        #expect(text.contains("CAPNODE101"))
        #expect(text.contains("CAPNODE100"))
        #expect(text.contains(PreviewWebView.diagramLimitNoteLabel))
    }
}
#endif
