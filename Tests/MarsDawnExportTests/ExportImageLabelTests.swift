#if os(macOS)
import Foundation
import PDFKit
import Testing
@testable import MarsDawnExport
@testable import MarsDawnKit

/// The exporter has no window to inject the app's image-placeholder labels, unlike the preview
/// (`PreviewViewController.pushRemoteImageState`/`pushAssetState`), so it must supply its own
/// (`DocumentExporter.prepare`), or an exported PDF shows a bare ": example.com" for a blocked
/// remote image, or wrongly claims a local image is "not found" when it just couldn't be read.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ExportImageLabelTests {
    @Test func blockedRemoteImageGetsTheWebImageLabelAndHost() async throws {
        let markdown = "# Doc\n\n![A cat](https://example.com/cat.png)\n"
        let text = try await exportedText(markdown: markdown, baseDirectory: nil, allowRemoteImages: false)
        #expect(text.contains("Web image: example.com"))
        // The defect: an empty placeholderLabel left a bare ": example.com" with nothing before
        // the colon. Whatever precedes the colon here must be the label, not nothing.
        let colonRange = try #require(text.range(of: ": example.com"))
        #expect(text[..<colonRange.lowerBound].hasSuffix("Web image"))
    }

    @Test func unreadableLocalImageGetsTheNeutralLabelNeverNotFound() async throws {
        let folder = try makeTemporaryDirectory()
        let markdown = "# Doc\n\n![Missing](missing.png)\n"
        let text = try await exportedText(markdown: markdown, baseDirectory: folder, allowRemoteImages: false)
        #expect(text.contains("Image not available: missing.png"))
        #expect(!text.contains("not found"))
        #expect(!text.contains("Not Found"))
    }

    @Test func labelsAreLocalizedIntoTraditionalChinese() {
        #expect(PreviewWebView.moduleLocalizedString("Web image", localization: "zh-Hant") == "網路圖片")
        #expect(PreviewWebView.moduleLocalizedString("Image not available", localization: "zh-Hant") == "無法顯示圖片")
    }

    /// AppKit's PDF producer embeds a couple of things that vary run to run even for identical
    /// content — a random `/ID` trailer entry, and (intermittently, under load) a differently
    /// tagged embedded font subset — so raw file bytes aren't a stable equality check. The page
    /// count and extracted text are: they are exactly what a reader of the PDF sees, and they
    /// must stay identical, proving the new label scripts in `prepare` don't perturb a page that
    /// has no images to label.
    @Test func exportOfADocumentWithNoImagesIsUnchangedAcrossRuns() async throws {
        let markdown = "# Doc\n\nJust text, no images at all.\n"
        let first = try await exportedPDF(markdown: markdown)
        let second = try await exportedPDF(markdown: markdown)
        #expect(first.pageCount == second.pageCount)
        #expect(first.text == second.text)
    }

    private func exportedPDF(markdown: String) async throws -> (pageCount: Int, text: String) {
        let data = try await exportedPDFData(markdown: markdown)
        let document = try #require(PDFDocument(data: data))
        let text = (0..<document.pageCount).compactMap { document.page(at: $0)?.string }.joined(separator: "\n")
        return (document.pageCount, text)
    }

    // MARK: Helpers

    private func exportedText(markdown: String, baseDirectory: URL?, allowRemoteImages: Bool) async throws -> String {
        let data = try await exportedPDFData(markdown: markdown, baseDirectory: baseDirectory, allowRemoteImages: allowRemoteImages)
        let document = try #require(PDFDocument(data: data))
        return (0..<document.pageCount).compactMap { document.page(at: $0)?.string }.joined(separator: "\n")
    }

    private func exportedPDFData(
        markdown: String,
        baseDirectory: URL? = nil,
        allowRemoteImages: Bool = false
    ) async throws -> Data {
        let outputURL = try makeTemporaryDirectory().appendingPathComponent("export-\(UUID().uuidString).pdf")
        _ = try await DocumentExporter.exportPDF(
            markdown: markdown,
            to: outputURL,
            theme: .dawn,
            baseDirectory: baseDirectory,
            allowRemoteImages: allowRemoteImages
        )
        return try Data(contentsOf: outputURL)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
#endif
