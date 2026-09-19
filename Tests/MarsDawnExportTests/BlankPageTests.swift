#if os(macOS)
import AppKit
import Foundation
import PDFKit
import Testing
@testable import MarsDawnExport
@testable import MarsDawnKit

/// No exported page is blank (#20). Content that ended exactly at the bottom of a page used to
/// get one more, empty page: the last block's bottom margin overflowed the page by less than a
/// line, and WebKit's pagination opened a page for the margin alone.
///
/// The failing layout depends on font metrics, so each test finds its own: a white spacer image
/// at the top pushes the content down a pixel at a time, and a binary search finds the first
/// spacer height at which the export needs one more page. That export is where a blank page
/// appears, if one ever does; the export one pixel shorter is the twin that fits.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(5)))
struct BlankPageTests {
    private static let paragraphs = (1...40).map { String(format: "Paragraph %03d.", $0) }.joined(separator: "\n\n")
    /// A loose list last: its last `<p>` has a bottom margin that collapses out through the `li`
    /// and the `ul`, so a rule on the last top-level block alone would miss it.
    private static let looseListLast = paragraphs + "\n\n- first item\n\n- last item\n"

    @Test func aPageBoundaryOnA4AddsNoBlankPage() async throws {
        try await expectNoBlankPageAtTheBoundary(body: Self.paragraphs, paper: .a4)
    }

    @Test func aPageBoundaryOnLetterAddsNoBlankPage() async throws {
        try await expectNoBlankPageAtTheBoundary(body: Self.paragraphs, paper: .letter)
    }

    @Test func aLooseListEndingAtThePageBoundaryAddsNoBlankPage() async throws {
        try await expectNoBlankPageAtTheBoundary(body: Self.looseListLast, paper: .a4)
    }

    /// A loose list inside a quote: the trailing margin comes from four levels down (#47).
    @Test func aQuotedLooseListEndingAtThePageBoundaryAddsNoBlankPage() async throws {
        try await expectNoBlankPageAtTheBoundary(body: Self.paragraphs + "\n\n> - first item\n>\n> - last item\n", paper: .a4)
    }

    /// Three quotes deep, then a loose list: six levels, past any fixed-depth rule (#47). The
    /// rule has to hold at any depth.
    @Test func aDeeplyNestedLooseListEndingAtThePageBoundaryAddsNoBlankPage() async throws {
        try await expectNoBlankPageAtTheBoundary(body: Self.paragraphs + "\n\n> > > - first item\n> > >\n> > > - last item\n", paper: .a4)
    }

    /// The other half of "no blank page": nothing else moves. The rule that drops the trailing
    /// margin must touch only the last line of the document. A rule that zeroed every last
    /// child's margin (`.markdown-body :last-child`) passed every test above, yet changed every
    /// page (found by the verifier on #49): paragraphs and list items lost their spacing. Here,
    /// mid-document, the gap between two loose-list items must match the gap between two
    /// paragraphs (one line plus the 1em margin each; measured equal, 31.2 pt), and that gap
    /// must stay well over the height of a line (measured 2.2 times; with the over-broad rule
    /// both gaps shrink, to 1.4 times). Ratios, so fonts don't move them.
    @Test func midDocumentSpacingIsUntouched() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("marsdawn-spacing-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let markdown = """
        # Spacing

        Paragraph Alpha.

        Paragraph Bravo.

        - Item Charlie

        - Item Delta

        - Item Echo

        Closing paragraph after the list, so the list is not the end of the document.
        """
        _ = try await DocumentExporter.exportPDF(
            markdown: markdown, to: url, theme: .dawn, baseDirectory: nil, allowRemoteImages: false
        )
        let document = try #require(PDFDocument(url: url))
        let page = try #require(document.page(at: 0))
        func top(_ text: String) throws -> CGFloat {
            let selection = try #require(document.findString(text, withOptions: []).first, "\(text) is on the page")
            return selection.bounds(for: page).maxY
        }
        let paragraphGap = try top("Paragraph Alpha") - top("Paragraph Bravo")
        let itemGap = try top("Item Charlie") - top("Item Delta")
        let lineHeight = try #require(document.findString("Paragraph Alpha", withOptions: []).first).bounds(for: page).height
        #expect(abs(itemGap - paragraphGap) <= paragraphGap * 0.05,
                "loose-list items are spaced like paragraphs: \(itemGap) vs \(paragraphGap)")
        #expect(paragraphGap >= lineHeight * 1.8, "paragraphs keep their margin: \(paragraphGap) for a \(lineHeight) line")
    }

    // MARK: -

    private func expectNoBlankPageAtTheBoundary(body: String, paper: DocumentExporter.Paper) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("marsdawn-blank-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        func export(spacer height: Int) async throws -> PDFDocument {
            let image = "spacer-\(height).png"
            try Self.whitePNG(height: height).write(to: folder.appendingPathComponent(image))
            let url = folder.appendingPathComponent("spacer-\(height).pdf")
            _ = try await DocumentExporter.exportPDF(
                markdown: "# Lines\n\n![](\(image))\n\n" + body, to: url, theme: .dawn,
                baseDirectory: folder, allowRemoteImages: false, paper: paper
            )
            return try #require(PDFDocument(url: url))
        }

        // The spacer range spans several lines, so it crosses a page boundary.
        var low = 1, high = 300
        let lowPages = try await export(spacer: low).pageCount
        let highPages = try await export(spacer: high).pageCount
        try #require(highPages > lowPages, "precondition: the spacer range crosses a page boundary (\(lowPages) → \(highPages) pages)")
        while high - low > 1 {
            let middle = (low + high) / 2
            if try await export(spacer: middle).pageCount > lowPages { high = middle } else { low = middle }
        }

        let fits = try await export(spacer: low)
        let spills = try await export(spacer: high)
        #expect(fits.pageCount == lowPages)
        #expect(spills.pageCount == lowPages + 1)
        for (name, document) in [("fits (\(low) px)", fits), ("spills (\(high) px)", spills)] {
            for index in 0..<document.pageCount {
                #expect(Self.inkedPixels(document.page(at: index)!) > 0, "\(paper) \(name): page \(index + 1) of \(document.pageCount) is blank")
            }
        }
    }

    /// A white PNG, 10 px wide: it takes up height and draws nothing.
    private static func whitePNG(height: Int) throws -> Data {
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 10, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 3,
            hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        for y in 0..<height { for x in 0..<10 { rep.setColor(.white, atX: x, y: y) } }
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    /// Pixels that aren't white when the page is drawn at 1x on white.
    private static func inkedPixels(_ page: PDFPage) -> Int {
        let box = page.bounds(for: .mediaBox)
        let width = Int(box.width), height = Int(box.height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { raw in
            let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            context.setFillColor(.white)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            page.draw(with: .mediaBox, to: context)
        }
        return stride(from: 0, to: pixels.count, by: 4).filter { pixels[$0] < 250 || pixels[$0 + 1] < 250 || pixels[$0 + 2] < 250 }.count
    }
}
#endif
