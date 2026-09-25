#if os(macOS)
import Foundation
import Testing
@testable import MarsDawnExport
@testable import MarsDawnKit

/// `DocumentExporter.diagramErrors` reports the *document's* line for a failed Mermaid diagram,
/// not Mermaid's own line within the diagram source (mars-dawn-kit#114) — the same mapping
/// `preview.js`'s `mapMermaidLineToDocument` uses (fence `data-line` + Mermaid's own line
/// number), read back from the page's `data-doc-line` attribute.
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

        #expect(exporter.diagramErrors.count == 1)
        let error = try #require(exporter.diagramErrors.first)
        // The invalid syntax is the diagram's second line ("line 2" in Mermaid's own message,
        // right after the `flowchart` type line), so the document line is the fence's own line
        // plus two.
        #expect(error.line == fenceLine + 2, "diagramErrors: \(exporter.diagramErrors)")
        #expect(!error.message.isEmpty)
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
        let error = try #require(exporter.diagramErrors.first)
        #expect(error.line == nil, "diagramErrors: \(exporter.diagramErrors)")
        #expect(!error.message.isEmpty)
    }

    /// The CLI's `--json` output carries the same `line`, present or absent, as a per-diagram
    /// field (not folded into the message text).
    @Test func exportPDFCarriesTheLineThrough() async throws {
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
        #expect(result.diagramErrors.first?.line == fenceLine + 2)
    }
}
#endif
