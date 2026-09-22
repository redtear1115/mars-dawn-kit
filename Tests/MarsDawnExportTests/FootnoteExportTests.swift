#if os(macOS)
import AppKit
import Foundation
import PDFKit
import Testing
@testable import MarsDawnExport
@testable import MarsDawnKit

/// Footnotes in the PDF (#44): endnotes after the body, and the links both ways kept as
/// in-document links, across pages too.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(5)))
struct FootnoteExportTests {
    static let markdown = """
    # Notes

    First claim.[^a] Second claim.[^b]

    \((1...70).map { "Filler paragraph \($0)." }.joined(separator: "\n\n"))

    A late reference.[^a]

    [^a]: Alpha note text.

    [^b]: https://example.com
    """

    private func export() async throws -> PDFDocument {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("marsdawn-footnotes-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try await DocumentExporter.exportPDF(
            markdown: Self.markdown, to: url, theme: .dawn, baseDirectory: nil, allowRemoteImages: false
        )
        return try #require(PDFDocument(url: url))
    }

    @Test func notesComeLastAndLinkBothWays() async throws {
        let document = try await export()
        #expect(document.pageCount >= 2, "positive fixture: the notes are pages away from the first reference")
        let text = (0..<document.pageCount).compactMap { document.page(at: $0)?.string }.joined(separator: "\n")
        #expect(!text.contains("[^"), "no footnote syntax is left as text")
        let alpha = try #require(text.range(of: "Alpha note text."))
        let late = try #require(text.range(of: "A late reference."))
        #expect(late.upperBound <= alpha.lowerBound, "the notes follow the body")
        #expect(text.contains("https://example.com"))

        var internalLinks: [(from: Int, to: Int)] = []
        var externalURLs: [String] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            for annotation in page.annotations where annotation.type == "Link" {
                if let url = annotation.url {
                    externalURLs.append(url.absoluteString)
                } else if let destination = annotation.destination, let target = destination.page {
                    internalLinks.append((index, document.index(for: target)))
                }
            }
        }
        let last = document.pageCount - 1
        // Three references into the notes, three backlinks out of them.
        #expect(internalLinks.filter { $0.to == last }.count >= 2, "\(internalLinks)")
        #expect(internalLinks.contains { $0.from == last && $0.to == 0 }, "a backlink to the first page: \(internalLinks)")
        #expect(externalURLs.isEmpty, "a URL-only note is text, not a link: \(externalURLs)")
    }
}
#endif
