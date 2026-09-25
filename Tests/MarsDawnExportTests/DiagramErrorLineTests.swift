#if os(macOS)
import AppKit
import Foundation
import Testing
@testable import MarsDawnExport
@testable import MarsDawnKit

/// `DocumentExporter.diagramErrorDetails` reports two different document lines for a failed
/// Mermaid diagram (mars-dawn-kit#114) — not a fallback pair, each has its own condition for
/// being present:
/// - `fenceLine`: the document line the diagram's fence (` ```mermaid `) starts on, present
///   whenever the block's own `data-line` is known.
/// - `line`: the document line **of the error itself** — `fenceLine` plus Mermaid's own line
///   number from inside its message, mapped the same way `preview.js`'s
///   `mapMermaidLineToDocument` does — present only when Mermaid's message actually names a line
///   (some errors, like an undetected diagram type, don't) *and* `fenceLine` is known.
///
/// Additive, not a replacement: `diagramErrors` (`[String]`) and `runReportingDiagrams`'s 2-tuple
/// are both unchanged, since they're public API (the app's own `ReviewPrompterTests.swift`
/// returns `runReportingDiagrams(...)` directly as `-> (completed: Bool, diagramErrors:
/// [String])`) and part of a published, `additionalProperties: false` JSON schema (marsdawn-mcp,
/// mars-dawn-website) that existing readers may already validate against.
/// `diagramErrorDetails`/`runReportingDiagramDetails` carry the same failures, in the same order,
/// each with its two lines.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(5)))
struct DiagramErrorLineTests {
    /// A diagram whose error names a line: both `fenceLine` (the fence's own line) and `line`
    /// (the error's line, `fenceLine` + Mermaid's own line number) are present and distinct.
    @Test func fenceLineAndLineAreBothPresentAndDistinctWhenTheFenceHasOneAndTheErrorNamesALine() async throws {
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

        #expect(exporter.diagramErrorDetails.count == 1)
        let detail = try #require(exporter.diagramErrorDetails.first)
        #expect(detail.fenceLine == fenceLine, "diagramErrorDetails: \(exporter.diagramErrorDetails)")
        // The invalid syntax is the diagram's second line ("line 2" in Mermaid's own message,
        // right after the `flowchart` type line), so the error's own document line is the
        // fence's own line plus two — a different number from fenceLine itself.
        #expect(detail.line == fenceLine + 2, "diagramErrorDetails: \(exporter.diagramErrorDetails)")
        #expect(detail.message == exporter.diagramErrors[0])
    }

    /// A diagram whose error names no line at all (an undetected diagram type): `fenceLine` is
    /// still present — it comes from the block's own `data-line`, not from the message — but
    /// `line` is absent, since there's no Mermaid line number to map.
    @Test func fenceLineIsPresentButLineIsAbsentWhenTheErrorNamesNoLine() async throws {
        let markdown = """
        # Title

        ```mermaid
        this is not a recognised diagram type at all
        ```
        """
        let fenceLine = try #require(markdown.components(separatedBy: "\n").firstIndex(of: "```mermaid")) + 1

        let exporter = DocumentExporter(baseDirectory: nil, allowRemoteImages: false)
        try await exporter.prepare(markdown: markdown, theme: .dawn)

        #expect(exporter.diagramErrors.count == 1, "diagramErrors: \(exporter.diagramErrors)")
        let detail = try #require(exporter.diagramErrorDetails.first)
        // Positive control: the message really doesn't name a line — if it did, this fixture
        // wouldn't be testing what its name says.
        #expect(!detail.message.lowercased().contains("line"), "fixture no longer names no line: \(detail.message)")
        #expect(detail.fenceLine == fenceLine, "diagramErrorDetails: \(exporter.diagramErrorDetails)")
        #expect(detail.line == nil, "diagramErrorDetails: \(exporter.diagramErrorDetails)")
    }

    /// A mermaid fence inside a footnote's own text never gets a `data-line` (#44 — footnote
    /// text is rendered with no line attributes at all), so neither `fenceLine` nor `line` (which
    /// needs `fenceLine`) can be known.
    @Test func bothAreAbsentWhenTheFenceHasNoDataLine() async throws {
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
        #expect(detail.fenceLine == nil, "diagramErrorDetails: \(exporter.diagramErrorDetails)")
        #expect(detail.line == nil, "diagramErrorDetails: \(exporter.diagramErrorDetails)")
        #expect(!detail.message.isEmpty)
    }

    /// The CLI's export path (`DocumentExporter.exportPDF`, via `runReportingDiagramDetails`)
    /// carries both the unchanged `diagramErrors` and the additive `diagramErrorDetails` through,
    /// in the same order, with both lines intact.
    @Test func exportPDFCarriesBothLinesThrough() async throws {
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
        #expect(result.diagramErrorDetails.first?.fenceLine == fenceLine)
        #expect(result.diagramErrorDetails.first?.line == fenceLine + 2)
        #expect(result.diagramErrorDetails.first?.message == result.diagramErrors.first)
    }

    /// `runReportingDiagrams` itself — the exact function the app's `ReviewPrompterTests.swift`
    /// returns directly as `-> (completed: Bool, diagramErrors: [String])` — still returns
    /// exactly that 2-tuple shape (this call wouldn't type-check otherwise), unaffected by the
    /// new details.
    @Test func runReportingDiagramsIsStillTheOriginalTwoTupleShape() async throws {
        let markdown = "```mermaid\nflowchart LR\n  this is not valid (((\n```\n"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("review-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let result: (completed: Bool, diagramErrors: [String]) = try await DocumentExporter.runReportingDiagrams(
            markdown: markdown, theme: .dawn, baseDirectory: nil, allowRemoteImages: false,
            printInfo: NSPrintInfo.shared, window: nil
        ) { info, operation in
            info.jobDisposition = .save
            info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
            operation.showsPrintPanel = false
            operation.showsProgressPanel = false
        }
        #expect(result.completed)
        #expect(!result.diagramErrors.isEmpty)
    }
}
#endif
