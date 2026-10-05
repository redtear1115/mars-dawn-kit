#if os(macOS)
import AppKit
import PDFKit
import Testing
import WebKit
@testable import MarsDawnExport
@testable import MarsDawnKit

/// #129: `DocumentExporter` passes `softBreaksAsLineBreaks` down to `MarkdownRenderer.Options`,
/// the way the preview and Quick Look do, so an export reads like the preview. Checked in the
/// exported page's DOM, which is what gets printed.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SoftBreakExportTests {
    static let markdown = "第一行中文\n第二行中文\n\nfirst\nsecond\n"

    private func paragraphs(_ exporter: DocumentExporter) async throws -> [String] {
        try await exporter.webView.evaluateJavaScript(
            #"[...document.querySelectorAll(".markdown-body > p")].map((p) => p.innerHTML)"#
        ) as? [String] ?? []
    }

    @Test func byDefaultCJKLinesJoinAndLatinLinesKeepTheirNewline() async throws {
        let exporter = DocumentExporter(baseDirectory: nil, allowRemoteImages: false)
        try await exporter.prepare(markdown: Self.markdown, theme: .dawn)
        #expect(try await paragraphs(exporter) == ["第一行中文第二行中文", "first\nsecond"])
    }

    @Test func theOptionMakesEveryNewlineABreakInTheExportedPage() async throws {
        let exporter = DocumentExporter(baseDirectory: nil, allowRemoteImages: false)
        try await exporter.prepare(markdown: Self.markdown, theme: .dawn, softBreaksAsLineBreaks: true)
        #expect(try await paragraphs(exporter) == ["第一行中文<br>\n第二行中文", "first<br>\nsecond"])
    }

    /// `exportPDF` forwards the option through `runReportingDiagramDetails` to `prepare`: the
    /// whole pipeline, and the text layer of the PDF carries the joined CJK without a space.
    @Test func exportPDFThreadsTheOptionThrough() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("marsdawn-breaks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let joined = directory.appendingPathComponent("joined.pdf")
        let broken = directory.appendingPathComponent("broken.pdf")
        let markdown = "alpha\nbeta\n"
        _ = try await DocumentExporter.exportPDF(
            markdown: markdown, to: joined, theme: .dawn, baseDirectory: nil, allowRemoteImages: false
        )
        _ = try await DocumentExporter.exportPDF(
            markdown: markdown, to: broken, theme: .dawn, baseDirectory: nil, allowRemoteImages: false,
            softBreaksAsLineBreaks: true
        )
        let joinedText = PDFDocument(url: joined)?.string ?? ""
        let brokenText = PDFDocument(url: broken)?.string ?? ""
        #expect(joinedText.contains("alpha beta"), "\(joinedText.debugDescription)")
        #expect(!brokenText.contains("alpha beta") && brokenText.contains("alpha") && brokenText.contains("beta"), "\(brokenText.debugDescription)")
    }
}
#endif
