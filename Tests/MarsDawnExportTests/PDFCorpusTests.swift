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

    /// Runs only under `MARSDAWN_PDF_GOLDENS=1` (the `pdf-goldens` CI job). Recording is a
    /// separate opt-in (`MARSDAWN_UPDATE_GOLDENS=1`); otherwise a mismatch fails the test.
    @Test(arguments: PDFCorpus.goldenFixtureNames)
    func golden(_ name: String) async throws {
        guard ProcessInfo.processInfo.environment["MARSDAWN_PDF_GOLDENS"] == "1" else { return }
        let fixture = name == "long" ? Self.makeLongFixture() : try CorpusLoader.load(name)
        defer { fixture.cleanUp() }
        try await Self.assertGolden(fixture)
    }

    static func assertGolden(_ fixture: CorpusFixture) async throws {
        let outcome = try await exportOnce(
            markdown: fixture.markdown, baseDirectory: fixture.baseDirectory,
            allowRemoteImages: fixture.expectation.allowRemoteImages, measureInk: false
        )
        let currentHeader = GoldenHeader.current(paper: "a4")
        let url = GoldenStore.url(for: fixture.name)

        if ProcessInfo.processInfo.environment["MARSDAWN_UPDATE_GOLDENS"] == "1" {
            let content = GoldenStore.render(header: currentHeader, pageTexts: outcome.pageTexts)
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

        let expectedContent = GoldenStore.render(header: recordedHeader, pageTexts: outcome.pageTexts)
        guard expectedContent != recorded else { return }

        let recordedPages = GoldenStore.pages(from: recorded)
        let currentPages = outcome.pageTexts.map(GoldenStore.normalize)
        var diffs: [String] = []
        if recordedPages.count != currentPages.count {
            diffs.append("page count \(recordedPages.count) -> \(currentPages.count)")
        }
        for index in 0..<min(recordedPages.count, currentPages.count) where recordedPages[index] != currentPages[index] {
            diffs.append("page \(index + 1) differs")
        }
        Issue.record("\(fixture.name): golden mismatch: \(diffs.isEmpty ? "text differs" : diffs.joined(separator: ", "))")
    }

    // MARK: Shared assertion pipeline (tiers 1, 2, 3, 5)

    static func assertFixture(_ fixture: CorpusFixture, checkStability: Bool) async throws {
        let outcome = try await exportOnce(
            markdown: fixture.markdown, baseDirectory: fixture.baseDirectory,
            allowRemoteImages: fixture.expectation.allowRemoteImages
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
            allowRemoteImages: fixture.expectation.allowRemoteImages, measureInk: false
        )
        #expect(second.pageCount == outcome.pageCount, "\(fixture.name): page count changed between two exports")
        #expect(
            second.pageTexts.map(corpusNormalize) == outcome.pageTexts.map(corpusNormalize),
            "\(fixture.name): text changed between two exports"
        )
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
        markdown: String, baseDirectory: URL?, allowRemoteImages: Bool, measureInk: Bool = true
    ) async throws -> ExportOutcome {
        let outputDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }
        let pdfURL = outputDirectory.appendingPathComponent("export.pdf")

        var inspected: Inspected!
        let result = try await DocumentExporter.exportPDF(
            markdown: markdown, to: pdfURL, theme: .dawn,
            baseDirectory: baseDirectory, allowRemoteImages: allowRemoteImages
        ) { exporter in
            let raw = try await exporter.webView.evaluateJavaScript(Self.domInspectionScript) as? String ?? "{}"
            let dom = try JSONDecoder().decode(DOMState.self, from: Data(raw.utf8))
            // Lay the page out for print to read what printing shows, then hand it back as it was.
            exporter.webView.mediaType = "print"
            defer { exporter.webView.mediaType = nil }
            let printText = try await exporter.webView.evaluateJavaScript(Self.printTextScript) as? String ?? ""
            inspected = Inspected(
                dom: dom, printText: printText,
                renderedHTML: exporter.renderedHTML, diagramErrorCount: exporter.diagramErrors.count
            )
        }
        _ = result

        let document = try #require(PDFDocument(url: pdfURL))
        let pages = (0..<document.pageCount).map { document.page(at: $0) }
        let pageTexts = pages.map { $0?.string ?? "" }
        let pageHasInk = measureInk
            ? pages.map { $0.map(Self.pageHasInk) ?? false }
            : Array(repeating: true, count: pages.count)
        let imageXObjectCount = PDFImageInspector.imageXObjectCount(at: pdfURL)

        return ExportOutcome(
            pageCount: document.pageCount, pageTexts: pageTexts,
            pageHasInk: pageHasInk, inspected: inspected, imageXObjectCount: imageXObjectCount
        )
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

enum GoldenStore {
    static func url(for name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // MarsDawnExportTests
            .appendingPathComponent("Goldens")
            .appendingPathComponent("\(name).txt")
    }

    /// NFKC composition only — unlike the marker-matching `corpusNormalize`, whitespace and
    /// line breaks are kept, so the file stays readable and a PR diff shows the changed page.
    static func normalize(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping
    }

    static func render(header: GoldenHeader, pageTexts: [String]) -> String {
        var lines = [header.line, "Page count: \(pageTexts.count)"]
        for (index, text) in pageTexts.enumerated() {
            lines.append("")
            lines.append("--- Page \(index + 1) ---")
            lines.append(normalize(text))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Splits a rendered golden's body back into per-page text, for a page-level diff message.
    static func pages(from content: String) -> [String] {
        var pages: [String] = []
        var current: [String]?
        for line in content.components(separatedBy: "\n").dropFirst(2) {
            if line.hasPrefix("--- Page ") {
                if let current { pages.append(current.joined(separator: "\n")) }
                current = []
            } else {
                current?.append(line)
            }
        }
        if let current { pages.append(current.joined(separator: "\n")) }
        return pages.map { $0.trimmingCharacters(in: .newlines) }
    }
}
#endif
