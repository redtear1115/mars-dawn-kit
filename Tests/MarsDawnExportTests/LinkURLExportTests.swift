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
    /// A link whose text already is its address prints it once, not twice: an autolink, the same
    /// address without the scheme, or with a trailing slash on either side (mars-dawn#667).
    @Test(arguments: [ExportLayout.manual, .handout])
    func aLinkShowingItsOwnAddressPrintsItOnce(_ layout: ExportLayout) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("link-self-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try await DocumentExporter.exportPDF(
            markdown: """
            Auto <https://example.com/auto>

            Bare [example.com/bare](https://example.com/bare/)

            Slash [https://example.com/slash/](https://example.com/slash)

            Named [Named](https://example.com/named)
            """,
            to: url, theme: .dawn, baseDirectory: nil, allowRemoteImages: false,
            layout: layout, calloutTitles: .english
        )
        let document = try #require(PDFDocument(url: url))
        let text = (document.string ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(text.contains("Named (https://example.com/named)"), "positive control: a named link still gets its address")
        for printed in ["(https://example.com/auto)", "(https://example.com/bare/)", "(https://example.com/slash)"] {
            #expect(!text.contains(printed), "\(printed) printed after a link that already shows it")
        }
        #expect(text.components(separatedBy: "https://example.com/auto").count - 1 == 1)
        #expect(text.contains("example.com/bare"))
        #expect(text.contains("https://example.com/slash/"))
    }

    /// Diagnostic for the PR: where the link's clickable area ends relative to the printed address.
    @Test func linkAnnotationAndPrintedAddress() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("link-annot-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try await DocumentExporter.exportPDF(
            markdown: "See [MarsDawn](https://example.com/x) here.\n",
            to: url, theme: .dawn, baseDirectory: nil, allowRemoteImages: false,
            layout: .manual, calloutTitles: .english
        )
        let document = try #require(PDFDocument(url: url))
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            for annotation in page.annotations where annotation.url != nil {
                let name = page.selection(for: annotation.bounds)?.string ?? ""
                print("667-annot page \(index) url=\(annotation.url!) bounds=\(annotation.bounds) text=\(name.debugDescription)")
            }
            if let word = document.findString("MarsDawn", withOptions: []).first(where: { $0.pages.first == page }) {
                print("667-text MarsDawn bounds=\(word.bounds(for: page))")
            }
            if let address = document.findString("(https://example.com/x)", withOptions: []).first(where: { $0.pages.first == page }) {
                print("667-text address bounds=\(address.bounds(for: page))")
            }
        }
        #expect(document.pageCount > 0)
    }
}
#endif
