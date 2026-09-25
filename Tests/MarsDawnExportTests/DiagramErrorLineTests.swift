#if os(macOS)
import Foundation
import Testing
@testable import MarsDawnExport
@testable import MarsDawnKit

/// `DocumentExporter.diagramErrorDetails` reports the *document's* line for a failed Mermaid
/// diagram, not Mermaid's own line within the diagram source (mars-dawn-kit#114) — the same
/// mapping `preview.js`'s `mapMermaidLineToDocument` uses (fence `data-line` + Mermaid's own line
/// number), read back from the page's `data-doc-line` attribute.
///
/// Additive, not a replacement: `diagramErrors` (`[String]`) is unchanged, since it's part of a
/// published, `additionalProperties: false` JSON schema (marsdawn-mcp, mars-dawn-website) that
/// existing readers may already validate against. `diagramErrorDetails` carries the same
/// failures, in the same order, each with its document line.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(5)))
struct DiagramErrorLineTests {
    @Test func lineIsMappedToTheDocumentWhenTheFenceHasOne() async throws {
        let markdown = """
        # Title

        Para one.

        ```mermaid
        flowchart LR
          this is not valid (((
        ```

        Para two.
        """
        let fenceLine = try #require(markdown.components(separatedBy: "\n").firstIndex(of: "```mermaid")) + 1

        let exporter = DocumentExporter(baseDirectory: nil, allowRemoteImages: false)
        try await exporter.prepare(markdown: markdown, theme: .dawn)

        // Unchanged shape: still one plain message per failed diagram.
        #expect(exporter.diagramErrors.count == 1)
        #expect(!exporter.diagramErrors[0].isEmpty)

        // Additive: the same failure, with its document line.
        #expect(exporter.diagramErrorDetails.count == 1)
        let detail = try #require(exporter.diagramErrorDetails.first)
        // The invalid syntax is the diagram's second line ("line 2" in Mermaid's own message,
        // right after the `flowchart` type line), so the document line is the fence's own line
        // plus two.
        #expect(detail.line == fenceLine + 2, "diagramErrorDetails: \(exporter.diagramErrorDetails)")
        #expect(detail.message == exporter.diagramErrors[0])
    }

    /// A mermaid fence inside a footnote's own text never gets a `data-line` (#44 — footnote
    /// text is rendered with no line attributes at all), so its document line can't be known.
    @Test func lineIsAbsentWhenTheFenceHasNone() async throws {
        let markdown = """
        Text.[^a]

        [^a]: A note.

            ```mermaid
            this is not valid (((
            ```
        """

        let exporter = DocumentExporter(baseDirectory: nil, allowRemoteImages: false)
        try await exporter.prepare(markdown: markdown, theme: .dawn)

        #expect(exporter.diagramErrors.count == 1, "diagramErrors: \(exporter.diagramErrors)")
        #expect(exporter.diagramErrorDetails.count == 1, "diagramErrorDetails: \(exporter.diagramErrorDetails)")
        let detail = try #require(exporter.diagramErrorDetails.first)
        #expect(detail.line == nil, "diagramErrorDetails: \(exporter.diagramErrorDetails)")
        #expect(!detail.message.isEmpty)
    }

    /// The CLI's export path (`DocumentExporter.exportPDF`) carries both the unchanged
    /// `diagramErrors` and the additive `diagramErrorDetails` through, in the same order.
    @Test func exportPDFCarriesBothThrough() async throws {
        let markdown = """
        # Title

        ```mermaid
        flowchart LR
          this is not valid (((
        ```
        """
        let fenceLine = try #require(markdown.components(separatedBy: "\n").firstIndex(of: "```mermaid")) + 1
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("export.pdf")

        let result = try await DocumentExporter.exportPDF(
            markdown: markdown, to: url, theme: .dawn, baseDirectory: nil, allowRemoteImages: false
        )
        #expect(result.diagramErrors.count == 1)
        #expect(result.diagramErrorDetails.count == 1)
        #expect(result.diagramErrorDetails.first?.line == fenceLine + 2)
        #expect(result.diagramErrorDetails.first?.message == result.diagramErrors.first)
    }
}
#endif
