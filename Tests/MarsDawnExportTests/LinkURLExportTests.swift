#if os(macOS)
import Foundation
import PDFKit
import Testing
@testable import MarsDawnExport

@MainActor
@Suite(.serialized, .timeLimit(.minutes(5)))
struct LinkURLExportTests {
    @Test(arguments: [ExportLayout.document, .manual, .handout])
    func printsExternalURLsOnlyInPaperLayouts(_ layout: ExportLayout) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("link-urls-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try await DocumentExporter.exportPDF(
            markdown: """
            # Destination

            [MarsDawn](https://example.com/x)

            [Internal](#destination)

            [Email](mailto:reader@example.com)

            [Relative](guide.md)
            """,
            to: url, theme: .dawn, baseDirectory: nil, allowRemoteImages: false,
            layout: layout, calloutTitles: .english
        )
        let document = try #require(PDFDocument(url: url))
        let text = (document.string ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(text.contains("MarsDawn"))
        #expect(text.contains("Internal"))
        #expect(text.contains("Email"))
        #expect(!text.contains("#destination"))
        #expect(!text.contains("mailto:"))
        #expect(!text.contains("reader@example.com"))
        #expect(!text.contains("guide.md"))
        if layout == .document {
            #expect(!text.contains("https://example.com/x"))
        } else {
            #expect(text.contains("MarsDawn (https://example.com/x)"))
            #expect(text.components(separatedBy: "(https://example.com/x)").count - 1 == 1)
        }
    }
}
#endif
