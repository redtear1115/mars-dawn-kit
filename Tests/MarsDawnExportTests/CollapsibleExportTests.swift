#if os(macOS)
import AppKit
import Foundation
import PDFKit
import Testing
import WebKit
@testable import MarsDawnExport
@testable import MarsDawnKit

/// The export's `details` option (redtear1115/mars-dawn#300, item 3): `.expand`, the default,
/// prints every `<details>` open; `.asWritten` prints only the open ones' content. Read from the
/// PDF's own text, on `Fixtures/collapsible-fixture.md` (sections A–K).
///
/// Sections A, C and G are plain `<details>` and are checked everywhere. D–F (`:::spoiler`) and
/// H–I (foldable callouts) are `<details>` only once the renderer makes them so (kit#256); their
/// tests are each enabled by a probe of the renderer, so they start running by themselves when
/// it does, and never fail for a renderer that doesn't yet.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(5)))
struct CollapsibleExportTests {
    static func fixture() throws -> String {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/collapsible-fixture", withExtension: "md"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The PDF's text. `details: nil` leaves the parameter out, so the default is what runs.
    static func pdfText(_ markdown: String, details: DetailsMode?, layout: ExportLayout = .document) async throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("marsdawn-collapsible-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        if let details {
            _ = try await DocumentExporter.exportPDF(
                markdown: markdown, to: url, theme: .dawn, baseDirectory: nil, allowRemoteImages: false, layout: layout, details: details
            )
        } else {
            _ = try await DocumentExporter.exportPDF(
                markdown: markdown, to: url, theme: .dawn, baseDirectory: nil, allowRemoteImages: false, layout: layout
            )
        }
        let document = try #require(PDFDocument(url: url))
        return (0..<document.pageCount).compactMap { document.page(at: $0)?.string }.joined(separator: "\n")
    }

    static let frontMatter = ["FM-TITLE-SECRET", "FM-AUTHOR-SECRET", "FM-TAGS-SECRET", "Document info"]
    static let alwaysPrinted = [
        "INTRO-ALWAYS", "SUMMARY-A", "AFTER-A", "SUMMARY-C", "BODY-C", "SUMMARY-G-OUTER", "BODY-J",
        "BODY-K line 1", "BODY-K line 42", "END-OF-FIXTURE",
    ]

    // MARK: A, C, G

    @Test func byDefaultEveryDetailsPrintsOpen() async throws {
        let text = try await Self.pdfText(Self.fixture(), details: nil)
        for part in Self.alwaysPrinted + ["BODY-A first", "BODY-A2", "BODY-A-CODE", "BODY-G-OUTER", "SUMMARY-G-INNER", "BODY-G-INNER"] {
            #expect(text.contains(part), "the PDF holds \(part)")
        }
        for part in Self.frontMatter {
            #expect(!text.contains(part), "front matter stays out: \(part)")
        }
    }

    @Test(arguments: [ExportLayout.document, .manual, .handout])
    func asWrittenPrintsOnlyTheOpenOnesContent(layout: ExportLayout) async throws {
        let text = try await Self.pdfText(Self.fixture(), details: .asWritten, layout: layout)
        for part in Self.alwaysPrinted {
            #expect(text.contains(part), "\(layout): the PDF holds \(part)")
        }
        // The Handbook's cover and the handout's header show the front matter's title (and the
        // cover its author) on purpose; the front-matter block itself stays out in every layout.
        let frontMatter = layout == .document ? Self.frontMatter : ["FM-TAGS-SECRET", "Document info"]
        // G's inner summary is inside the closed outer block, so it goes with it.
        for part in ["BODY-A first", "BODY-A2", "BODY-A-CODE", "BODY-G-OUTER", "SUMMARY-G-INNER", "BODY-G-INNER"] + frontMatter {
            #expect(!text.contains(part), "\(layout): the PDF leaves out \(part)")
        }
    }

    /// The page as-written prints: A and G closed, C open, the class that keeps print CSS from
    /// opening them on `<html>`, a summary a bold block with no marker. Expand: every one open
    /// and no class.
    @Test(arguments: [DetailsMode.expand, .asWritten])
    func theExportPage(details: DetailsMode) async throws {
        let exporter = DocumentExporter(baseDirectory: nil, allowRemoteImages: false, details: details)
        try await exporter.prepare(markdown: Self.fixture(), theme: .dawn)
        exporter.webView.mediaType = "print"
        let text = try #require(try await exporter.webView.evaluateJavaScript("""
            JSON.stringify({
              open: Object.fromEntries([...document.querySelectorAll("details:not(.front-matter)")]
                .map((d) => [d.querySelector(":scope > summary").textContent, d.open])),
              marked: document.documentElement.classList.contains("marsdawn-details-as-written"),
              shown: [...document.querySelectorAll("#content p")].filter((p) => p.checkVisibility()).map((p) => p.textContent.split(" ")[0]),
              frontMatter: getComputedStyle(document.querySelector("details.front-matter")).display,
              summary: getComputedStyle(document.querySelector("details:not(.front-matter) > summary")).display,
              weight: getComputedStyle(document.querySelector("details:not(.front-matter) > summary")).fontWeight,
            })
            """) as? String)
        let state = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let open = try #require(state["open"] as? [String: Bool])
        let shown = state["shown"] as? [String] ?? []
        let expand = details == .expand
        #expect(open["SUMMARY-A"] == expand)
        #expect(open["SUMMARY-C"] == true)
        #expect(open["SUMMARY-G-OUTER"] == expand)
        #expect(open["SUMMARY-G-INNER"] == expand)
        #expect(state["marked"] as? Bool == !expand)
        #expect(shown.contains("BODY-A") == expand)
        #expect(shown.contains("BODY-G-INNER") == expand)
        #expect(shown.contains("BODY-C"))
        #expect(state["frontMatter"] as? String == "none")
        #expect(state["summary"] as? String == "block", "a summary prints as a block, so with no triangle")
        #expect(state["weight"] as? String == "600")
    }

    /// An exclusive group written with both members open: WebKit keeps the first open, and so
    /// does the as-written PDF. The name is gone from the page in both modes.
    @Test func asWrittenKeepsTheFirstOpenMemberOfAnExclusiveGroup() async throws {
        let markdown = """
            <details name="g" open>
            <summary>GROUP-ONE</summary>

            GROUP-ONE-BODY

            </details>

            <details name="g" open>
            <summary>GROUP-TWO</summary>

            GROUP-TWO-BODY

            </details>
            """
        let written = try await Self.pdfText(markdown, details: .asWritten)
        #expect(written.contains("GROUP-ONE-BODY"))
        #expect(!written.contains("GROUP-TWO-BODY"))
        #expect(written.contains("GROUP-TWO"))
        let expanded = try await Self.pdfText(markdown, details: .expand)
        #expect(expanded.contains("GROUP-ONE-BODY") && expanded.contains("GROUP-TWO-BODY"))

        let exporter = DocumentExporter(baseDirectory: nil, allowRemoteImages: false, details: .asWritten)
        try await exporter.prepare(markdown: markdown, theme: .dawn)
        let names = try await exporter.webView.evaluateJavaScript(#"document.querySelectorAll("details[name]").length"#) as? Int
        #expect(names == 0)
    }

    /// A heading inside a closed block doesn't print, so the Handbook's contents leave it out
    /// (it has no page); with expand it prints and is listed.
    @Test func theHandbookListsNoHeadingOfAClosedBlock() async throws {
        let markdown = """
            # Shown chapter

            Text.

            <details>
            <summary>Closed</summary>

            ## HIDDEN-HEADING

            HIDDEN-BODY

            </details>
            """
        let written = try await Self.pdfText(markdown, details: .asWritten, layout: .manual)
        #expect(written.contains("Shown chapter"))
        #expect(!written.contains("HIDDEN-HEADING"))
        let expanded = try await Self.pdfText(markdown, details: .expand, layout: .manual)
        #expect(expanded.components(separatedBy: "HIDDEN-HEADING").count == 3, "listed and printed: \(expanded)")
    }

    /// `--format png` shares `prepare`, so it takes the same option: expand opens every block,
    /// as-written leaves A and G closed as the preview first shows them.
    @Test(arguments: [DetailsMode.expand, .asWritten])
    func thePNGTakesTheSameOption(details: DetailsMode) async throws {
        var open: [String: Bool] = [:]
        _ = try await DocumentImageRenderer.render(markdown: Self.fixture(), theme: .dawn, baseDirectory: nil, details: details) { webView in
            let text = try await webView.evaluateJavaScript("""
                JSON.stringify(Object.fromEntries([...document.querySelectorAll("details:not(.front-matter)")]
                  .map((d) => [d.querySelector(":scope > summary").textContent, d.open])))
                """) as? String ?? "{}"
            open = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Bool] ?? [:]
        }
        #expect(open["SUMMARY-A"] == (details == .expand))
        #expect(open["SUMMARY-G-INNER"] == (details == .expand))
        #expect(open["SUMMARY-C"] == true)
    }

    // MARK: D–F, H–I (kit#256)

    /// Whether the renderer makes `markdown` into HTML holding `count` `<details` openings,
    /// `open` ones among them when `open` is set.
    nonisolated static func renders(_ markdown: String, details count: Int = 1, open: Bool = false) -> Bool {
        let html = MarkdownRenderer.render(markdown, options: .preview(baseDirectory: nil))
        let openings = html.components(separatedBy: "<details").count - 1
        guard openings >= count else { return false }
        return !open || html.range(of: #"<details[^>]*\sopen"#, options: .regularExpression) != nil
    }

    nonisolated static var spoilerIsDetails: Bool { renders(":::spoiler T\nx\n:::\n") }
    nonisolated static var openSpoilerIsDetails: Bool { renders(":::spoiler {state=\"open\"} T\nx\n:::\n", open: true) }
    nonisolated static var nestedSpoilerIsDetails: Bool { renders("::::spoiler O\no\n\n:::spoiler I\ni\n:::\n::::\n", details: 2) }
    nonisolated static var foldedCalloutIsDetails: Bool { renders("> [!note]- T\n> x\n") }
    nonisolated static var expandedCalloutIsDetails: Bool { renders("> [!tip]+ T\n> x\n", open: true) }

    /// Section `name`'s markers: what the fixture prints there with `details`.
    static func checkSection(_ text: String, details: DetailsMode, summaries: [String], bodies: [String], open: Bool) {
        for part in summaries {
            #expect(text.contains(part), "\(details): the PDF holds \(part)")
        }
        for part in bodies {
            #expect(text.contains(part) == (details == .expand || open), "\(details): \(part)")
        }
    }

    @Test(.enabled(if: spoilerIsDetails, "a :::spoiler renders as <details>"), arguments: [DetailsMode.expand, .asWritten])
    func sectionD(details: DetailsMode) async throws {
        let text = try await Self.pdfText(Self.fixture(), details: details)
        Self.checkSection(text, details: details, summaries: ["SUMMARY-D"], bodies: ["BODY-D"], open: false)
    }

    @Test(.enabled(if: openSpoilerIsDetails, "a :::spoiler {state=\"open\"} renders as <details open> (kit#256)"),
          arguments: [DetailsMode.expand, .asWritten])
    func sectionE(details: DetailsMode) async throws {
        let text = try await Self.pdfText(Self.fixture(), details: details)
        Self.checkSection(text, details: details, summaries: ["SUMMARY-E"], bodies: ["BODY-E"], open: true)
        #expect(!text.contains("state="), "the attribute is not in the title")
    }

    @Test(.enabled(if: nestedSpoilerIsDetails, "a ::::spoiler holding a :::spoiler renders as nested <details> (kit#256)"),
          arguments: [DetailsMode.expand, .asWritten])
    func sectionF(details: DetailsMode) async throws {
        let text = try await Self.pdfText(Self.fixture(), details: details)
        Self.checkSection(
            text, details: details, summaries: ["SUMMARY-F-OUTER"],
            bodies: ["BODY-F-OUTER", "SUMMARY-F-INNER", "BODY-F-INNER", "BODY-F-AFTER"], open: false
        )
    }

    @Test(.enabled(if: foldedCalloutIsDetails, "> [!note]- renders as <details> (kit#256)"), arguments: [DetailsMode.expand, .asWritten])
    func sectionH(details: DetailsMode) async throws {
        let text = try await Self.pdfText(Self.fixture(), details: details)
        Self.checkSection(text, details: details, summaries: ["SUMMARY-H"], bodies: ["BODY-H"], open: false)
    }

    @Test(.enabled(if: expandedCalloutIsDetails, "> [!tip]+ renders as <details open> (kit#256)"), arguments: [DetailsMode.expand, .asWritten])
    func sectionI(details: DetailsMode) async throws {
        let text = try await Self.pdfText(Self.fixture(), details: details)
        Self.checkSection(text, details: details, summaries: ["SUMMARY-I"], bodies: ["BODY-I"], open: true)
    }
}
#endif
