#if os(macOS)
import AppKit
import Foundation
import PDFKit
import Testing
import WebKit
@testable import MarsDawnExport
@testable import MarsDawnKit

/// The PDF export golden corpus (redtear1115/mars-dawn#2): PDF export must not silently lose
/// content, the page count must be stable, and export must not diverge silently from the
/// preview. See `Tests/MarsDawnExportTests/Corpus/` for the fixtures and their `expect.json`
/// schema, and the README's "Build and test" section for the golden drift policy.
///
/// Every fixture becomes its own parameterised test case, so a failure names the fixture.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(10)))
struct PDFCorpus {
    /// Every committed fixture folder's name (loose files at the corpus root are not
    /// fixtures and are skipped by the loader).
    nonisolated static let folderFixtureNames: [String] = (try? CorpusLoader.fixtureNames()) ?? []

    @Test func fixtureFoldersWereDiscovered() throws {
        // If this is empty, `Package.swift`'s `resources: [.copy("Corpus")]` isn't wiring the
        // fixtures into the test bundle, and every parameterised test below silently runs zero
        // cases instead of failing — this makes that loud instead of silent.
        #expect(!Self.folderFixtureNames.isEmpty)
    }

    // MARK: Committed fixtures

    @Test(arguments: PDFCorpus.folderFixtureNames)
    func fixture(_ name: String) async throws {
        let fixture = try CorpusLoader.load(name)
        defer { fixture.cleanUp() }
        try await Self.assertFixture(fixture, checkStability: true)
    }

    // MARK: Generated: `long`

    @Test func long() async throws {
        let fixture = Self.makeLongFixture()
        defer { fixture.cleanUp() }
        try await Self.assertFixture(fixture, checkStability: true)
    }

    // MARK: Generated: `boundary-under` / `boundary-over`

    /// The emphasis shape, not the table shape: at the node-budget boundary the table shape
    /// takes 61.6s to export versus 18.9s for emphasis (measured in debug), so emphasis keeps
    /// the suite inside its time budget.
    @Test func boundaryUnder() async throws {
        let markdown = Self.emphasisBoundary.under
        #expect(
            MarkdownRenderer.renderResult(markdown).fallback == nil,
            "boundary-under: unexpectedly fell back to escaped source"
        )
        let outcome = try await Self.exportOnce(markdown: markdown, baseDirectory: nil, allowRemoteImages: false)
        let text = corpusNormalize(outcome.pageTexts.joined())
        #expect(!text.contains("*"), "boundary-under: a literal * leaked into the exported text")
        #expect(text.contains(corpusNormalize("ENDEMPH99")), "boundary-under: end marker missing")
        Self.assertInk(pageHasInk: outcome.pageHasInk, fixtureName: "boundary-under")
        let rendered = await MarkdownRenderer.renderResult(markdown, options: .preview(baseDirectory: nil))
        #expect(
            outcome.inspected.renderedHTML == rendered?.html,
            "boundary-under: exported HTML differs from the preview's (redtear1115/mars-dawn#22)"
        )
    }

    @Test func boundaryOver() async throws {
        let markdown = Self.emphasisBoundary.over
        #expect(
            MarkdownRenderer.renderResult(markdown).fallback != nil,
            "boundary-over: expected the renderer to fall back to escaped source"
        )
        let outcome = try await Self.exportOnce(markdown: markdown, baseDirectory: nil, allowRemoteImages: false)
        let text = corpusNormalize(outcome.pageTexts.joined())
        #expect(text.contains(corpusNormalize("*e0x0*")), "boundary-over: escaped source not visible in the PDF")
        #expect(text.contains(corpusNormalize("ENDEMPH99")), "boundary-over: end marker missing")
        Self.assertInk(pageHasInk: outcome.pageHasInk, fixtureName: "boundary-over")
        let rendered = await MarkdownRenderer.renderResult(markdown, options: .preview(baseDirectory: nil))
        #expect(
            outcome.inspected.renderedHTML == rendered?.html,
            "boundary-over: exported HTML differs from the preview's (redtear1115/mars-dawn#22)"
        )
    }

    /// The largest emphasis-shape line count that still renders as Markdown, found by binary
    /// search at test time so `under`/`over` always track `ParseLimits.defaultMaxNodes`
    /// rather than a number pinned by hand. Computed once per test run.
    static let emphasisBoundary: (low: Int, under: String, over: String) = {
        var low = 1, high = 30_000
        while low < high {
            let mid = (low + high + 1) / 2
            if MarkdownRenderer.renderResult(emphasisMarkdown(lines: mid)).fallback == nil { low = mid } else { high = mid - 1 }
        }
        return (low, emphasisMarkdown(lines: low), emphasisMarkdown(lines: low + 1))
    }()

    private static func emphasisMarkdown(lines: Int) -> String {
        var markdown = "# EMPH\n\n"
        for line in 0..<lines {
            markdown += (0..<20).map { "*e\(line)x\($0)*" }.joined(separator: " ") + "\n\n"
        }
        return markdown + "ENDEMPH99\n"
    }

    private static func makeLongFixture() -> CorpusFixture {
        var markdown = ""
        var markers: [String] = []
        for section in 1...200 {
            markdown += "## Section \(section)\n\n"
            for paragraph in 1...10 {
                let number = (section - 1) * 10 + paragraph
                let token = "LONG" + String(format: "%04d", number)
                markers.append(token)
                markdown += "\(token) " + String(repeating: "lorem ipsum dolor sit amet ", count: 6) + "\n\n"
            }
        }
        var expectation = FixtureExpectation()
        expectation.markers = markers
        expectation.markersOnLastPage = ["LONG2000"]
        return CorpusFixture(name: "long", markdown: markdown, baseDirectory: nil, expectation: expectation, workDirectory: nil)
    }

    // MARK: Tier 4: goldens (per OS build)

    nonisolated static var goldenFixtureNames: [String] { folderFixtureNames + ["long"] }

    /// Runs only under `MARSDAWN_PDF_GOLDENS=1` (the `pdf-goldens` CI job); without it Swift Testing
    /// reports each case as skipped, not passed. Recording is a separate opt-in
    /// (`MARSDAWN_UPDATE_GOLDENS=1`); otherwise a mismatch fails the test.
    @Test(
        .enabled(
            if: ProcessInfo.processInfo.environment["MARSDAWN_PDF_GOLDENS"] == "1",
            "the goldens are per OS build: set MARSDAWN_PDF_GOLDENS=1 to compare (the pdf-goldens CI job does)"
        ),
        arguments: PDFCorpus.goldenFixtureNames
    )
    func golden(_ name: String) async throws {
        let fixture = name == "long" ? Self.makeLongFixture() : try CorpusLoader.load(name)
        defer { fixture.cleanUp() }
        try await Self.assertGolden(fixture)
    }

    static func assertGolden(_ fixture: CorpusFixture) async throws {
        let outcome = try await exportOnce(
            markdown: fixture.markdown, baseDirectory: fixture.baseDirectory,
            allowRemoteImages: fixture.expectation.allowRemoteImages, layout: fixture.expectation.layout,
            displayName: fixture.expectation.displayName, measureInk: false
        )
        let document = try #require(PDFDocument(data: outcome.data))
        let current = GoldenStore.pageLines(of: document)
        let currentHeader = GoldenHeader.current(paper: "a4")
        let url = GoldenStore.url(for: fixture.name)

        if ProcessInfo.processInfo.environment["MARSDAWN_UPDATE_GOLDENS"] == "1" {
            let content = GoldenStore.render(header: currentHeader, pages: current)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
            return
        }

        guard FileManager.default.fileExists(atPath: url.path) else {
            Issue.record("\(fixture.name): no golden recorded; run with MARSDAWN_UPDATE_GOLDENS=1 to record one")
            return
        }
        let recorded = try String(contentsOf: url, encoding: .utf8)
        guard let headerLine = recorded.components(separatedBy: "\n").first,
              let recordedHeader = GoldenHeader.parse(headerLine)
        else {
            Issue.record("\(fixture.name): golden file has no readable header")
            return
        }
        guard recordedHeader.osBuild == currentHeader.osBuild else {
            Issue.record(Comment(rawValue:
                "goldens were recorded on build \(recordedHeader.osBuild), this runner is "
                    + "build \(currentHeader.osBuild): re-record with the Record PDF goldens workflow"
            ))
            return
        }

        let diffs = GoldenStore.differences(recorded: GoldenStore.pages(from: recorded), current: current)
        guard !diffs.isEmpty else { return }
        Issue.record("\(fixture.name): golden mismatch: \(diffs.prefix(12).joined(separator: "; "))\(diffs.count > 12 ? "; and \(diffs.count - 12) more" : "")")
    }

    // MARK: Shared assertion pipeline (tiers 1, 2, 3, 5)

    static func assertFixture(_ fixture: CorpusFixture, checkStability: Bool) async throws {
        let outcome = try await exportOnce(
            markdown: fixture.markdown, baseDirectory: fixture.baseDirectory,
            allowRemoteImages: fixture.expectation.allowRemoteImages, layout: fixture.expectation.layout,
            displayName: fixture.expectation.displayName
        )
        let fullText = corpusNormalize(outcome.pageTexts.joined(separator: "\n"))
        let lastPageText = outcome.pageTexts.last.map(corpusNormalize) ?? ""

        // Tier 1: nothing disappears silently.
        for marker in fixture.expectation.markers {
            #expect(fullText.contains(corpusNormalize(marker)), "\(fixture.name): marker \(marker) is missing")
        }
        for marker in fixture.expectation.markersOnLastPage {
            #expect(lastPageText.contains(corpusNormalize(marker)), "\(fixture.name): marker \(marker) is missing from the last page")
        }
        for marker in fixture.expectation.absent {
            #expect(!fullText.contains(corpusNormalize(marker)), "\(fixture.name): \(marker) is unexpectedly present")
        }
        for placeholder in fixture.expectation.placeholders {
            #expect(fullText.contains(corpusNormalize(placeholder)), "\(fixture.name): placeholder \(placeholder) is missing")
        }
        if let diagrams = fixture.expectation.diagrams {
            #expect(outcome.inspected.dom.rendered == diagrams.rendered, "\(fixture.name): rendered diagram count")
            #expect(outcome.inspected.dom.failed == diagrams.failed, "\(fixture.name): failed diagram count")
            #expect(outcome.inspected.diagramErrorCount == diagrams.failed, "\(fixture.name): diagramErrors.count")
        }
        if let images = fixture.expectation.images {
            #expect(outcome.inspected.dom.images == images, "\(fixture.name): loaded image count")
            // A PDF stores an image drawn twice once, so the bound is the distinct loaded files.
            #expect(
                outcome.imageXObjectCount >= outcome.inspected.dom.distinctImages,
                "\(fixture.name): \(outcome.inspected.dom.distinctImages) distinct images loaded, \(outcome.imageXObjectCount) drawn in the PDF"
            )
        }

        // Tier 2: no blank page.
        Self.assertInk(pageHasInk: outcome.pageHasInk, fixtureName: fixture.name)
        Self.assertPageLayout(outcome, fixture: fixture)
        if fixture.expectation.layout == .manual {
            try Self.assertManual(outcome, fixture: fixture)
        } else if fixture.expectation.layout == .handout {
            Self.assertHandout(outcome, fixture: fixture)
        } else {
            #expect(outcome.manual == nil, "\(fixture.name): the document layout ran the manual layout's passes")
        }

        // Tier 5: preview and export can't diverge silently (redtear1115/mars-dawn#22). The
        // known scope gap between preview and export for images outside the document's folder
        // (redtear1115/mars-dawn#8) is not exercised by the fixtures this suite owns.
        let rendered = await MarkdownRenderer.renderResult(fixture.markdown, options: .preview(baseDirectory: fixture.baseDirectory))
        #expect(
            outcome.inspected.renderedHTML == rendered?.html,
            "\(fixture.name): exported HTML differs from the preview's (redtear1115/mars-dawn#22)"
        )
        let lost = Self.wordsMissing(from: fullText, visibleText: outcome.inspected.printText)
        #expect(lost.isEmpty, "\(fixture.name): shown on the printed page but missing from the PDF: \(lost.prefix(20))")

        // Tier 3: stable for a fixed input.
        guard checkStability else { return }
        let second = try await exportOnce(
            markdown: fixture.markdown, baseDirectory: fixture.baseDirectory,
            allowRemoteImages: fixture.expectation.allowRemoteImages, layout: fixture.expectation.layout,
            displayName: fixture.expectation.displayName, measureInk: false
        )
        #expect(second.pageCount == outcome.pageCount, "\(fixture.name): page count changed between two exports")
        #expect(
            second.pageTexts.map(corpusNormalize) == outcome.pageTexts.map(corpusNormalize),
            "\(fixture.name): text changed between two exports"
        )
    }

    /// Layout expectations (S1 of mars-dawn#432): where pages start, what shares a page, that no
    /// page is without text, and, for the manual layout, that text stays inside the margins.
    static func assertPageLayout(_ outcome: ExportOutcome, fixture: CorpusFixture) {
        let expectation = fixture.expectation
        // In the manual layout, where things start is a question about the body: the cover and
        // contents come first (and the contents repeats the headings), and each body page ends
        // with its "n / N" footer (S2).
        let bodyStart = outcome.manual?.bodyStart ?? 0
        let pages = outcome.pageTexts.dropFirst(bodyStart).map {
            corpusNormalize(expectation.layout == .handout ? HandoutProbe.withoutFooter($0) : ManualProbe.withoutFooter($0))
        }
        // The margins reach the layout width as well as the print info (spike M4): with only the
        // print info, keep-with-next measures at the wrong width and page texts move.
        #expect(
            abs(outcome.inspected.layoutWidth - expectation.layout.printableWidth(paperWidth: outcome.paperSize.width)) < 0.01,
            "\(fixture.name): laid out at \(outcome.inspected.layoutWidth) pt, not the \(expectation.layout) layout's printable width"
        )
        if let minPages = expectation.minPages {
            #expect(pages.count >= minPages, "\(fixture.name): \(pages.count) pages, expected at least \(minPages)")
        }
        if expectation.textOnEveryPage {
            for (index, text) in outcome.pageTexts.map(corpusNormalize).enumerated() {
                #expect(!text.isEmpty, "\(fixture.name): page \(index + 1) has no text")
            }
        }
        for start in expectation.startsPage {
            let needle = corpusNormalize(start)
            let holders = pages.indices.filter { pages[$0].contains(needle) }
            #expect(holders.count == 1, "\(fixture.name): \(start) is on \(holders.count) pages")
            if let page = holders.first {
                #expect(pages[page].hasPrefix(needle), "\(fixture.name): \(start) is on page \(page + 1 + bodyStart) but does not start it")
            }
        }
        for group in expectation.samePage {
            let holders = Set(group.flatMap { text in pages.indices.filter { pages[$0].contains(corpusNormalize(text)) } })
            #expect(holders.count == 1, "\(fixture.name): \(group) are on pages \(holders.sorted().map { $0 + 1 + bodyStart })")
        }
        if expectation.layout == .handout {
            HandoutProbe.assertInsideBody(outcome.pageExtents, paper: outcome.paperSize, name: fixture.name)
        }
        guard expectation.layout == .manual else { return }
        let margins = expectation.layout.pageMargins
        let paper = outcome.paperSize
        var minX = CGFloat.greatestFiniteMagnitude, maxX = -CGFloat.greatestFiniteMagnitude
        for (index, extent) in outcome.pageExtents.enumerated() {
            guard let extent else { continue }
            let page = index + 1
            #expect(extent.minX >= margins.left - 0.5, "\(fixture.name): page \(page) text starts at x \(extent.minX), margin \(margins.left)")
            #expect(extent.maxX <= paper.width - margins.right + 0.5, "\(fixture.name): page \(page) text ends at x \(extent.maxX), margin edge \(paper.width - margins.right)")
            // The top edge is measured on ink, not on the line boxes: a line's selection box spans
            // the font's ascent and line gap, and Hiragino's stands about 4 pt above its glyphs
            // (kit #164: boxes to y 789.1, ink to 781.5, against an edge at 785.3). Printing clips
            // at that edge, so ink can never cross it: content pushed past it is cut there, and its
            // ink then reaches the edge (784.75 in the planted control). So the ink must stay a
            // point clear of the edge; the corpus's highest ink is 781.75.
            if let inkTop = outcome.pageInkTops[index] {
                #expect(inkTop <= paper.height - margins.top - 1, "\(fixture.name): page \(page) ink reaches y \(inkTop), top margin edge \(paper.height - margins.top) (cut there?)")
            }
            #expect(extent.minY >= margins.bottom - 0.5, "\(fixture.name): page \(page) text reaches y \(extent.minY), bottom margin edge \(margins.bottom)")
            minX = min(minX, extent.minX)
            maxX = max(maxX, extent.maxX)
        }
        #expect(abs(minX - margins.left) <= 0.5, "\(fixture.name): the leftmost text is at x \(minX), not at the \(margins.left) pt binding margin")
        #expect(maxX <= paper.width - margins.right + 0.5 && maxX > paper.width - margins.right - 60, "\(fixture.name): the rightmost text is at x \(maxX)")
    }

    static func assertInk(pageHasInk: [Bool], fixtureName: String) {
        for (index, hasInk) in pageHasInk.enumerated() {
            #expect(hasInk, "\(fixtureName): page \(index + 1) has no ink")
        }
    }

    // MARK: Export + DOM inspection

    struct DOMState: Decodable {
        var rendered: Int
        var failed: Int
        var images: Int
        var distinctImages: Int
        var text: String
    }

    struct Inspected {
        var dom: DOMState
        /// `#content`'s text as laid out for print, without KaTeX's hidden MathML copy.
        var printText: String
        var renderedHTML: String?
        var diagramErrorCount: Int
        /// The width the page was laid out at before printing; it must be the printable width.
        var layoutWidth: CGFloat
    }

    /// Every run of three or more letters or digits in the text the printed page shows that
    /// isn't in the PDF's text (both normalised). Catches content that lays out but doesn't
    /// print, whether or not a fixture thought to put a marker in it.
    static func wordsMissing(from pdfText: String, visibleText: String) -> [String] {
        let words = visibleText.precomposedStringWithCompatibilityMapping
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 }
        var seen = Set<String>()
        return words.filter { seen.insert($0).inserted && !pdfText.contains(corpusNormalize($0)) }
    }

    /// The page's text under print media, the way it's printed. KaTeX keeps an
    /// accessibility copy of each expression that print never draws, so it's left out.
    private static let printTextScript = """
    (() => {
      const hidden = [...document.querySelectorAll(".katex-mathml")];
      for (const el of hidden) el.style.display = "none";
      const text = document.getElementById("content").innerText;
      for (const el of hidden) el.style.display = "";
      return text;
    })()
    """

    struct ExportOutcome {
        var pageCount: Int
        var pageTexts: [String]
        var pageHasInk: [Bool]
        var inspected: Inspected
        var imageXObjectCount: Int
        /// The union of each page's text-line boxes in PDF points (origin bottom left); nil for a page with no text.
        var pageExtents: [CGRect?]
        var paperSize: CGSize
        /// The manual layout's report (S2), nil in the document layout.
        var manual: ManualReport?
        /// The final file, for the manual layout's own checks.
        var data: Data
        /// The manual layout only: the y (PDF points, origin bottom left) of each page's topmost
        /// painted pixel; nil for a blank page or the document layout.
        var pageInkTops: [CGFloat?] = []
        /// The handout layout's report (S3), nil in the other layouts.
        var handout: HandoutReport?
    }

    /// Every DOM query the corpus needs, read through `inspect` on the exporter that then
    /// prints, per the corpus contract's test seam — never a second, reimplemented exporter.
    private static let domInspectionScript = """
    (() => {
      const rendered = document.querySelectorAll(".mermaid-block.rendered").length;
      const failed = document.querySelectorAll(".mermaid-block.error").length;
      const loaded = [...document.images].filter((img) => img.complete && img.naturalWidth > 0);
      const images = loaded.length;
      // Keyed by file name: `nested/../img/rel.png` and `img/rel.png` are one file under two URLs.
      const distinctImages = new Set(loaded.map((img) => img.currentSrc.split("#")[0].split("/").pop())).size;
      const text = document.getElementById("content").innerText;
      return JSON.stringify({ rendered, failed, images, distinctImages, text });
    })()
    """

    static func exportOnce(
        markdown: String, baseDirectory: URL?, allowRemoteImages: Bool, layout: ExportLayout = .document,
        displayName: String? = nil, paper: DocumentExporter.Paper = .a4, measureInk: Bool = true
    ) async throws -> ExportOutcome {
        let outputDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }
        let pdfURL = outputDirectory.appendingPathComponent("export.pdf")

        var inspected: Inspected!
        var manual: ManualReport?
        var handout: HandoutReport?
        var hooks = ManualHooks()
        hooks.report = { manual = $0 }
        hooks.handoutReport = { handout = $0 }
        let result = try await DocumentExporter.exportPDF(
            markdown: markdown, to: pdfURL, theme: .dawn,
            baseDirectory: baseDirectory, allowRemoteImages: allowRemoteImages, paper: paper, layout: layout,
            displayName: displayName,
            // The goldens are English whatever the language of the machine that runs them.
            calloutTitles: .english, inspect: { exporter in
            let raw = try await exporter.webView.evaluateJavaScript(Self.domInspectionScript) as? String ?? "{}"
            let dom = try JSONDecoder().decode(DOMState.self, from: Data(raw.utf8))
            // Lay the page out for print to read what printing shows, then hand it back as it was.
            exporter.webView.mediaType = "print"
            defer { exporter.webView.mediaType = nil }
            let printText = try await exporter.webView.evaluateJavaScript(Self.printTextScript) as? String ?? ""
            inspected = Inspected(
                dom: dom, printText: printText,
                renderedHTML: exporter.renderedHTML, diagramErrorCount: exporter.diagramErrors.count,
                layoutWidth: exporter.webView.frame.width
            )
        }, hooks: hooks)
        _ = result

        let document = try #require(PDFDocument(url: pdfURL))
        let pages = (0..<document.pageCount).map { document.page(at: $0) }
        let pageTexts = pages.map { $0?.string ?? "" }
        let pageHasInk = measureInk
            ? pages.map { $0.map(Self.pageHasInk) ?? false }
            : Array(repeating: true, count: pages.count)
        let imageXObjectCount = PDFImageInspector.imageXObjectCount(at: pdfURL)

        let bottomMargin = layout.pageMargins.bottom
        let pageExtents = pages.map { page -> CGRect? in
            guard let page else { return nil }
            let lines = page.selection(for: page.bounds(for: .mediaBox))?.selectionsByLine() ?? []
            // The manual layout's footer sits in the bottom margin on purpose; the margins are
            // measured on everything else.
            let boxes = lines.filter { line in
                let text = (line.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                return !(manual != nil && text.wholeMatch(of: ManualProbe.footerPattern) != nil && line.bounds(for: page).maxY < bottomMargin)
            }.map { $0.bounds(for: page) }.filter { !$0.isEmpty }
            return boxes.dropFirst().reduce(boxes.first) { $0?.union($1) }
        }
        let paperSize = pages.first??.bounds(for: .mediaBox).size ?? .zero
        let pageInkTops = layout == .manual ? pages.map { $0.flatMap(Self.inkTop) } : []

        return ExportOutcome(
            pageCount: document.pageCount, pageTexts: pageTexts,
            pageHasInk: pageHasInk, inspected: inspected, imageXObjectCount: imageXObjectCount,
            pageExtents: pageExtents, paperSize: paperSize, manual: manual, data: try Data(contentsOf: pdfURL),
            pageInkTops: pageInkTops, handout: handout
        )
    }

    /// How many device pixels per PDF point `inkTop` renders at: a quarter-point grid.
    static let inkScale: CGFloat = 4

    /// The y (PDF points, origin bottom left) of the top edge of the topmost row of `page` with a
    /// painted pixel, rendered on white at `inkScale`; nil if nothing is painted. What paper shows,
    /// unlike a text line's selection box, which spans the font's whole ascent and line gap
    /// whether or not any glyph reaches that high (kit #164: Hiragino's boxes stand above the
    /// first line's ink).
    static func inkTop(_ page: PDFPage) -> CGFloat? {
        let box = page.bounds(for: .mediaBox)
        let width = Int(box.width * inkScale), height = Int(box.height * inkScale)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: inkScale, y: inkScale)
        page.draw(with: .mediaBox, to: context)
        guard let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        // Row 0 of a bitmap context's memory is the top of the image.
        for row in 0..<height {
            let start = row * width * 4
            for offset in stride(from: start, to: start + width * 4, by: 4)
            where pixels[offset] < 250 || pixels[offset + 1] < 250 || pixels[offset + 2] < 250 {
                return CGFloat(height - row) / inkScale
            }
        }
        return nil
    }

    /// A 1-bit threshold on a small raster: non-white pixels mean the page has ink.
    static func pageHasInk(_ page: PDFPage) -> Bool {
        let image = page.thumbnail(of: NSSize(width: 300, height: 424), for: .mediaBox)
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return false }
        for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.redComponent < 0.95 || color.greenComponent < 0.95 || color.blueComponent < 0.95 { return true }
            }
        }
        return false
    }
}

// MARK: - Golden storage

/// A golden file's first line: what produced it, so a runner-image drift shows up as a
/// clearly labelled re-record chore rather than an anonymous text diff.
struct GoldenHeader: Equatable {
    var osBuild: String
    var webKit: String
    var paper: String

    var line: String { "OS build: \(osBuild) | WebKit: \(webKit) | Paper: \(paper)" }

    static func current(paper: String) -> GoldenHeader {
        GoldenHeader(
            osBuild: ProcessInfo.processInfo.operatingSystemVersionString,
            webKit: Bundle(for: WKWebView.self).infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
            paper: paper
        )
    }

    static func parse(_ line: String) -> GoldenHeader? {
        let parts = line.components(separatedBy: " | ")
        guard parts.count == 3 else { return nil }
        func value(_ part: String) -> String {
            guard let range = part.range(of: ": ") else { return "" }
            return String(part[range.upperBound...])
        }
        return GoldenHeader(osBuild: value(parts[0]), webKit: value(parts[1]), paper: value(parts[2]))
    }
}

/// One line of a page as PDFKit selects it: its text and its box in PDF points (origin bottom
/// left), rounded to whole points.
struct GoldenLine: Equatable {
    var text: String
    var minX: Int, minY: Int, maxX: Int, maxY: Int

    var coordinates: [Int] { [minX, minY, maxX, maxY] }
    var render: String { "\(minX) \(minY) \(maxX) \(maxY) | \(text)" }

    static func parse(_ line: String) -> GoldenLine? {
        guard let separator = line.range(of: " | ") else { return nil }
        let numbers = line[..<separator.lowerBound].split(separator: " ").compactMap { Int($0) }
        guard numbers.count == 4 else { return nil }
        return GoldenLine(
            text: String(line[separator.upperBound...]),
            minX: numbers[0], minY: numbers[1], maxX: numbers[2], maxY: numbers[3]
        )
    }
}

/// The golden is a page's text lines with their boxes, not `PDFPage.string`: the string's order
/// is PDFKit's to choose (a KaTeX fraction's "1" came before or after its neighbours across two
/// runs of the same build, mars-dawn-kit audit D F6), and it holds no position at all.
///
/// - Each page is a multiset of lines, written sorted by text, then top to bottom, then left to
///   right; extraction order is not recorded.
/// - A box is rounded to whole points, y up from the bottom of the page.
/// - Comparing is exact on text and on the number of times each text occurs, and
///   `coordinateTolerance` whole points on each of the four coordinates. Rounding alone moves a
///   coordinate by one, so a box that sits on a .5 may flip between runs; two points is a move.
enum GoldenStore {
    static let coordinateTolerance = 1

    static func url(for name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // MarsDawnExportTests
            .appendingPathComponent("Goldens")
            .appendingPathComponent("\(name).txt")
    }

    /// NFKC composition only; whitespace inside a line is kept, so the file stays readable and
    /// a PR diff shows the changed lines.
    static func normalize(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping
    }

    /// Every page's lines, in the golden's order.
    static func pageLines(of document: PDFDocument) -> [[GoldenLine]] {
        (0..<document.pageCount).map { index in
            guard let page = document.page(at: index) else { return [] }
            let lines = page.selection(for: page.bounds(for: .mediaBox))?.selectionsByLine() ?? []
            return sorted(lines.compactMap { selection -> GoldenLine? in
                let box = selection.bounds(for: page)
                let text = normalize(selection.string ?? "")
                    .components(separatedBy: .newlines).joined(separator: " ")
                    .trimmingCharacters(in: .whitespaces)
                guard !box.isEmpty, !text.isEmpty else { return nil }
                return GoldenLine(
                    text: text, minX: Int(box.minX.rounded()), minY: Int(box.minY.rounded()),
                    maxX: Int(box.maxX.rounded()), maxY: Int(box.maxY.rounded())
                )
            })
        }
    }

    static func sorted(_ lines: [GoldenLine]) -> [GoldenLine] {
        lines.sorted { a, b in
            if a.text != b.text { return a.text.unicodeScalars.lexicographicallyPrecedes(b.text.unicodeScalars) }
            if a.maxY != b.maxY { return a.maxY > b.maxY }
            return a.minX < b.minX
        }
    }

    static func render(header: GoldenHeader, pages: [[GoldenLine]]) -> String {
        var lines = [
            header.line, "Page count: \(pages.count)",
            "Lines: minX minY maxX maxY | text, whole points from the page's bottom left, sorted by text; "
                + "compared within \(coordinateTolerance) pt",
        ]
        for (index, page) in pages.enumerated() {
            lines.append("")
            lines.append("--- Page \(index + 1) ---")
            lines.append(contentsOf: page.map(\.render))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Splits a rendered golden's body back into per-page lines.
    static func pages(from content: String) -> [[GoldenLine]] {
        var pages: [[GoldenLine]] = []
        var current: [GoldenLine]?
        for line in content.components(separatedBy: "\n").dropFirst(3) {
            if line.hasPrefix("--- Page ") {
                if let current { pages.append(current) }
                current = []
            } else if let parsed = GoldenLine.parse(line) {
                current?.append(parsed)
            }
        }
        if let current { pages.append(current) }
        return pages
    }

    /// What differs, in words: the page count, lines present on one side only, and lines that
    /// moved by more than `coordinateTolerance`. Empty when the pages match.
    static func differences(recorded: [[GoldenLine]], current: [[GoldenLine]]) -> [String] {
        var found: [String] = []
        if recorded.count != current.count { found.append("page count \(recorded.count) -> \(current.count)") }
        for page in 0..<min(recorded.count, current.count) {
            let before = Dictionary(grouping: recorded[page], by: \.text)
            let after = Dictionary(grouping: current[page], by: \.text)
            for text in Set(before.keys).union(after.keys).sorted() {
                let was = sorted(before[text] ?? []), now = sorted(after[text] ?? [])
                if was.count != now.count {
                    found.append("page \(page + 1): \"\(text)\" \(was.count)x -> \(now.count)x")
                    continue
                }
                for (old, new) in zip(was, now)
                where zip(old.coordinates, new.coordinates).contains(where: { abs($0 - $1) > coordinateTolerance }) {
                    found.append("page \(page + 1): \"\(text)\" moved \(old.coordinates) -> \(new.coordinates)")
                }
            }
        }
        return found
    }
}
#endif
