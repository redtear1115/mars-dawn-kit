#if os(macOS)
import AppKit
import Foundation
import PDFKit
import Testing
import WebKit
@testable import MarsDawnExport
@testable import MarsDawnKit

/// The handout layout (mars-dawn#432 S3): the notes column stays empty on both papers, page 1
/// starts with the header, the footer survives hostile names and dates, and nothing from the
/// document runs. Each check that could pass on a broken build has a control beside it that
/// must find what the check says is absent.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(10)))
struct HandoutLayoutTests {
    struct Run {
        var document: PDFDocument
        var data: Data
        var texts: [String]
        var report: HandoutReport?
        var manual: ManualReport?
    }

    static func export(
        _ markdown: String, layout: ExportLayout = .handout, displayName: String? = nil, paper: DocumentExporter.Paper = .a4,
        baseDirectory: URL? = nil, hooks: ManualHooks = ManualHooks()
    ) async throws -> Run {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("handout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("out.pdf")
        var report: HandoutReport?
        var manual: ManualReport?
        var hooks = hooks
        hooks.handoutReport = { report = $0 }
        hooks.report = { manual = $0 }
        _ = try await DocumentExporter.exportPDF(
            markdown: markdown, to: url, theme: .dawn, baseDirectory: baseDirectory, allowRemoteImages: false, paper: paper,
            layout: layout, displayName: displayName, calloutTitles: .english, inspect: nil, hooks: hooks
        )
        let data = try Data(contentsOf: url)
        let document = try #require(PDFDocument(data: data))
        return Run(document: document, data: data, texts: ManualProbe.pageTexts(document), report: report, manual: manual)
    }

    static func fixture(_ name: String, layout: ExportLayout = .handout, paper: DocumentExporter.Paper) async throws -> Run {
        let fixture = try CorpusLoader.load(name)
        defer { fixture.cleanUp() }
        return try await export(
            fixture.markdown, layout: layout, displayName: fixture.expectation.displayName, paper: paper,
            baseDirectory: fixture.baseDirectory
        )
    }

    // MARK: K1-1, K1-4: the notes column, on A4 and Letter (amendment A1-R2)

    @Test(arguments: ["handout-en", "handout-cjk"], DocumentExporter.Paper.allCases)
    func theNotesColumnHoldsOnlySpanningTables(_ name: String, _ paper: DocumentExporter.Paper) async throws {
        let run = try await Self.fixture(name, paper: paper)
        let report = try #require(run.report)
        let column = HandoutProbe.column(run.document, tables: report.tables)
        #expect(column.strayText.isEmpty, "\(name) \(paper): text in the column outside a spanning table: \(column.strayText)")
        #expect(column.strayInk.isEmpty, "\(name) \(paper): ink in the column without a spanning table: \(column.strayInk)")
        #expect(HandoutProbe.inkPastPrintable(run.document).isEmpty, "\(name) \(paper): ink past the printable width: \(HandoutProbe.inkPastPrintable(run.document))")
        // Each table that spans is on a page the probe reports; recorded for the hand-back.
        let spans = report.tables.filter { $0.kind != .natural }
        #expect(spans.isEmpty == column.spanningPages.isEmpty, "\(name) \(paper): \(spans.count) spanning tables, pages \(column.spanningPages)")
        print("HANDOUT-COLUMN \(name) \(paper): tables \(report.tables.map(\.kind.rawValue)) spanning pages \(column.spanningPages)")
        // Fully visible: every marker, including the tables' last columns and the 80-column
        // code line, is in the text, and every page has its footer.
        let fixture = try CorpusLoader.load(name)
        defer { fixture.cleanUp() }
        let text = corpusNormalize(run.texts.map(HandoutProbe.withoutFooter).joined())
        for marker in fixture.expectation.markers {
            #expect(text.contains(corpusNormalize(marker)), "\(name) \(paper): \(marker) missing")
        }
        for (index, page) in run.texts.enumerated() {
            #expect(HandoutProbe.footer(page)?.hasSuffix("\(index + 1) / \(run.texts.count)") == true, "\(name) \(paper): page \(index + 1) footer")
        }
    }

    /// Control for the probes above: the same fixture in the document layout has text and ink
    /// in the column's range that belongs to no spanning table.
    @Test(arguments: ["handout-en", "handout-cjk"])
    func controlTheDocumentLayoutFillsTheColumnsRange(_ name: String) async throws {
        let run = try await Self.fixture(name, layout: .document, paper: .a4)
        let column = HandoutProbe.column(run.document, tables: [])
        #expect(!column.strayText.isEmpty, "\(name): the probe found no text in the column's range")
        #expect(!column.strayInk.isEmpty, "\(name): the probe found no ink in the column's range")
    }

    /// A1-R2 on handout-en: the two-column table keeps its natural width inside the body, the
    /// six-column one runs into the column and breaks only between words (its URL and path
    /// cells may wrap anywhere), the ten-column one fills body and column with a fixed layout.
    @Test(arguments: DocumentExporter.Paper.allCases)
    func tablesFitByWidth(_ paper: DocumentExporter.Paper) async throws {
        let run = try await Self.fixture("handout-en", paper: paper)
        let tables = try #require(run.report?.tables)
        func table(_ marker: String) throws -> HandoutLayout.TableFit {
            try #require(tables.first { $0.text.contains(marker) }, "\(paper): no table holds \(marker)")
        }
        let six = try table("HOCELL1"), two = try table("HONARROW1"), ten = try table("HOTENA")
        #expect(six.kind == .span && two.kind == .natural && ten.kind == .wide, "\(paper): \(six.kind), \(two.kind), \(ten.kind)")
        #expect(two.width < 337, "\(paper): the narrow table is \(two.width) px")
        // Whole words: each is inside one line of the PDF's text.
        let lines = run.texts.flatMap(ManualProbe.lines)
        for word in ["HOCELL1", "Export", "handout", "Johnson", "Quarterly", "progress", "started", "summary", "appendix", "HOCELL2", "CHANGELOG.md", "HONARROW1"] {
            #expect(lines.contains { $0.split(separator: " ").contains { $0 == word } }, "\(paper): \(word) is split across lines")
        }
    }

    /// Control for K1-4: without the handout's table fitting, the ten-column table is cut at
    /// the body (its last column never prints) or its words are split.
    @Test func controlWithoutTableFittingTheWideTableIsCut() async throws {
        let fixture = try CorpusLoader.load("handout-en")
        defer { fixture.cleanUp() }
        var hooks = ManualHooks()
        hooks.handoutFitsTables = false
        let run = try await Self.export(
            fixture.markdown, displayName: fixture.expectation.displayName, baseDirectory: fixture.baseDirectory, hooks: hooks
        )
        let text = corpusNormalize(run.texts.map(HandoutProbe.withoutFooter).joined())
        let column = HandoutProbe.column(run.document, tables: [])
        print("HANDOUT-CONTROL HOTENJ \(text.contains("HOTENJ")) column text \(column.strayText) ink \(column.strayInk) past \(HandoutProbe.inkPastPrintable(run.document))")
        let cut = !text.contains("HOTENJ") || !column.strayText.isEmpty
        #expect(cut, "the ten-column table printed whole without the table fitting")
        #expect(run.report?.tables.isEmpty == true)
    }

    // MARK: K1-2: header, no cover, contents or outline

    @Test func pageOneStartsWithTheHeaderAndThereIsNoFrontMatterPage() async throws {
        let run = try await Self.fixture("handout-cjk", paper: .a4)
        let first = ManualProbe.lines(run.texts[0])
        #expect(Array(first.prefix(3)) == ["第三季會議講義 ZHTITLE", "2026年10月01日", "第一章 頁面設計 ZHH1"], "\(first.prefix(3))")
        #expect(run.document.outlineRoot == nil || run.document.outlineRoot?.numberOfChildren == 0)
        #expect(run.manual == nil)
        #expect(!run.texts.joined().contains("Contents"))
        // No title: the display name is the header.
        let untitled = try await Self.fixture("handout-en", paper: .a4)
        #expect(Array(ManualProbe.lines(untitled.texts[0]).prefix(2)) == ["Field Notes HONAME", "2026-10-01"])
        // Neither title nor display name: no header, the body comes first.
        let bare = try await Self.export("---\ndate: 2026-10-01\n---\n\nBODYFIRST text.\n")
        #expect(ManualProbe.lines(bare.texts[0]).first == "BODYFIRST text.")
        #expect(HandoutProbe.footer(bare.texts[0]) == "2026-10-01 · 1 / 1")
    }

    /// Control: the same fixture as a handbook has a cover, a contents page and an outline,
    /// and the probes above see them.
    @Test func controlTheHandbookHasCoverContentsAndOutline() async throws {
        let run = try await Self.fixture("handout-cjk", layout: .manual, paper: .a4)
        #expect(run.manual?.cover != nil, "no cover")
        #expect(run.texts.joined().contains("Contents"), "no contents")
        #expect((run.document.outlineRoot?.numberOfChildren ?? 0) > 0, "no outline")
    }

    // MARK: K1-3: the CJK display name extracts exactly, on both papers

    @Test(arguments: DocumentExporter.Paper.allCases)
    func theRadicalTwinInTheFooterExtractsExactly(_ paper: DocumentExporter.Paper) async throws {
        let run = try await Self.fixture("handout-cjk", paper: paper)
        for (index, page) in run.texts.enumerated() {
            #expect(HandoutProbe.footer(page) == "會議講義⾴頁 · 2026年10月01日 · \(index + 1) / \(run.texts.count)", "\(paper) page \(index + 1): \(String(describing: HandoutProbe.footer(page)))")
        }
        if case .repaired = run.report?.repair {} else { Issue.record("\(paper): repair \(String(describing: run.report?.repair))") }
        let english = try await Self.fixture("handout-en", paper: paper)
        #expect(english.report?.repair == .unchanged("no radical destinations"))
    }

    // MARK: K1-5: injection

    static let payload = ManualLayoutTests.payload

    static func injectionState(_ hooks: inout ManualHooks, into states: @escaping ([String: String]) -> Void) {
        hooks.afterPassB = { webView in
            let script = """
            return JSON.stringify({
              pwned: typeof window.__pwned,
              handlers: document.querySelectorAll("[onerror]").length,
              injected: document.querySelectorAll('img[src="x"]').length
            });
            """
            var result: [String: String] = [:]
            for (name, world) in [("page", WKContentWorld.page), ("handout", HandoutLayout.world)] {
                result[name] = try await webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: world) as? String
            }
            states(result)
        }
    }

    @Test func theTitleDateAndDisplayNameNeverRun() async throws {
        let p = Self.payload
        func flat(_ text: String) -> String {
            String(text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) && $0 != "\u{2028}" }.map(Character.init))
        }
        // The payload as the title and the date; then, with no title, as the display name.
        let cases: [(markdown: String, displayName: String?, shown: [String])] = [
            ("---\ntitle: FTITLE\(p)\ndate: FDATE\(p)\n---\n\nBody.\n", "NAME", ["FTITLE", "FDATE"]),
            ("---\ndate: 2026-10-01\n---\n\nBody.\n", "FNAME" + p, ["FNAME"]),
        ]
        for item in cases {
            var states: [String: String] = [:]
            var hooks = ManualHooks()
            Self.injectionState(&hooks) { states = $0 }
            let run = try await Self.export(item.markdown, displayName: item.displayName, hooks: hooks)
            for world in ["page", "handout"] {
                #expect(states[world] == #"{"pwned":"undefined","handlers":0,"injected":0}"#, "\(world) world: \(states[world] ?? "nil")")
            }
            let header = flat(HandoutProbe.withoutFooter(run.texts[0]))
            for field in item.shown {
                #expect(header.contains(field + flat(p)), "\(field): the header doesn't show the payload: \(run.texts[0])")
            }
        }
    }

    // MARK: K1-7: the date

    @Test func theExportDateIsTheExportingMachinesDay() {
        // 2026-10-20 23:30 UTC is already 2026-10-21 in UTC+8.
        let now = Date(timeIntervalSince1970: 1_792_539_000)
        #expect(HandoutLayout.exportDate(now: now, timeZone: TimeZone(identifier: "UTC")!) == "2026-10-20")
        #expect(HandoutLayout.exportDate(now: now, timeZone: TimeZone(secondsFromGMT: 8 * 3600)!) == "2026-10-21")
        #expect(HandoutLayout.exportDate(now: now, timeZone: TimeZone(identifier: "Asia/Taipei")!) == "2026-10-21")
    }

    @Test func withoutAFrontMatterDateTheFooterHasTheInjectedDay() async throws {
        var hooks = ManualHooks()
        hooks.now = Date(timeIntervalSince1970: 1_792_539_000)
        for (zone, day) in [(TimeZone(identifier: "UTC")!, "2026-10-20"), (TimeZone(secondsFromGMT: 8 * 3600)!, "2026-10-21")] {
            hooks.timeZone = zone
            let run = try await Self.export("# Untitled clock\n\nBody.\n", displayName: "clock", hooks: hooks)
            #expect(HandoutProbe.footer(run.texts[0]) == "clock · \(day) · 1 / 1")
            #expect(ManualProbe.lines(run.texts[0]).prefix(2) == ["clock", day])
        }
        // A front-matter date wins over the clock, verbatim.
        let dated = try await Self.export("---\ndate: Oct 1, 2026\n---\n\nBody.\n", displayName: "clock", hooks: hooks)
        #expect(HandoutProbe.footer(dated.texts[0]) == "clock · Oct 1, 2026 · 1 / 1")
    }

    // MARK: K1-8: footer hardening

    /// The characters drawn in the rightmost `width` points of the page's lowest line, as a
    /// set: PDFKit's string for a line that starts with Hebrew is in right-to-left reading
    /// order, and so is the order of its character boxes, so only what a region holds is
    /// evidence of where it was drawn (checked against a 2x render, 2026-10-21).
    static func rightEnd(_ page: PDFPage, width: CGFloat) -> Set<Character>? {
        guard let line = page.selection(for: page.bounds(for: .mediaBox))?.selectionsByLine()
            .min(by: { $0.bounds(for: page).minY < $1.bounds(for: page).minY }) else { return nil }
        let box = line.bounds(for: page)
        let region = CGRect(x: box.maxX - width, y: box.minY, width: width, height: box.height)
        return Set((page.selection(for: region)?.string ?? "").filter { !$0.isWhitespace })
    }

    @Test func rightToLeftNamesCannotMoveThePageNumber() async throws {
        let body = String(repeating: "Filler sentence for the page. ", count: 220)
        for name in ["evil\u{202E}2 / 1 :egap", "\u{05E9}\u{05DC}\u{05D5}\u{05DD} \u{05E2}\u{05D5}\u{05DC}\u{05DD} 12", "\u{2067}abc\u{2069}\u{200F}"] {
            let run = try await Self.export("---\ndate: 2026-10-01\n---\n\n\(body)\n", displayName: name)
            #expect(run.texts.count >= 2)
            for index in run.texts.indices {
                let page = try #require(run.document.page(at: index))
                // The last glyph is N; n comes just before it, not at the other end.
                let total = run.texts.count, number = index + 1
                let tight = try #require(Self.rightEnd(page, width: 10))
                let wider = try #require(Self.rightEnd(page, width: 20))
                let names = Set(name.filter { $0.isLetter })
                #expect(tight.contains(String(total).last!) && tight.isDisjoint(with: names), "page \(number): right end holds \(tight)")
                if number != total {
                    #expect(!tight.contains(String(number).last!) && wider.contains(String(number).last!), "page \(number): right end \(tight), \(wider)")
                }
            }
            let report = try #require(run.report)
            #expect(!report.footerText.unicodeScalars.contains { HandoutLayout.bidiControls.contains($0.value) }, "a Bidi control survived: \(report.footerText)")
        }
    }

    @Test func aLongNameAndDateStayInsideTheBody() async throws {
        // 255 bytes of name (the file-name limit) and a 500-character date.
        let name = String(repeating: "會議講義", count: 21) + "end"
        #expect(name.utf8.count == 255)
        let date = String(repeating: "2026-10-01 ", count: 46).prefix(500)
        let body = String(repeating: "Filler sentence for the page. ", count: 220)
        for paper in DocumentExporter.Paper.allCases {
            let run = try await Self.export("---\ndate: \(date)\n---\n\n\(body)\n", displayName: name, paper: paper)
            #expect(HandoutProbe.textInColumn(run.document).isEmpty, "\(paper): \(HandoutProbe.textInColumn(run.document))")
            for index in run.texts.indices {
                let page = try #require(run.document.page(at: index))
                let line = try #require(page.selection(for: page.bounds(for: .mediaBox))?.selectionsByLine().last)
                let box = line.bounds(for: page)
                #expect(box.minX >= ExportLayout.handout.pageMargins.left - 0.5 && box.maxX <= HandoutProbe.bodyMaxX(paperWidth: page.bounds(for: .mediaBox).width) + 0.5,
                        "\(paper) page \(index + 1): footer spans \(box.minX)–\(box.maxX)")
                let footer = HandoutProbe.footer(run.texts[index]) ?? ""
                #expect(footer.hasSuffix("· \(index + 1) / \(run.texts.count)") && footer.contains("…") && footer.hasPrefix("會議"), "\(paper): \(footer)")
            }
            // What the repair was told is what was drawn.
            let report = try #require(run.report)
            #expect(report.footerText.components(separatedBy: "\n").first == HandoutProbe.footer(run.texts[0]))
            #expect(report.footerDate.count <= HandoutLayout.maxDateLength)
        }
    }

    // MARK: Units

    @Test func sanitizingRemovesBidiControlsAndBreaks() {
        #expect(HandoutLayout.sanitized("a\u{202E}b\u{2066}c\u{2069}d\u{200F}") == "abcd")
        #expect(HandoutLayout.sanitized(" a\tb\n\u{0085}c\u{2028}d\u{2029}e\u{0007}  f ") == "a b c d e f")
        #expect(HandoutLayout.sanitized("\u{0000}\u{009F}") == "")
    }

    @Test func fittingCutsTheNameInTheMiddleAndKeepsThePageNumber() {
        let font = CTFontCreateWithName(ManualLayout.footerFontName as CFString, ManualLayout.footerFontSize, nil)
        let (name, date) = HandoutLayout.Footers.fit(
            name: String(repeating: "abcdefghij", count: 30) + "TAIL", date: "2026-10-01", pageCount: 12, width: 337, font: font
        )
        #expect(name?.contains("…") == true && name?.hasPrefix("abc") == true && name?.hasSuffix("TAIL") == true)
        #expect(date == "2026-10-01")
        let short = HandoutLayout.Footers.fit(name: "notes", date: String(repeating: "x", count: 60), pageCount: 1, width: 337, font: font)
        #expect(short.0 == "notes" && short.1.count == HandoutLayout.maxDateLength && short.1.hasSuffix("…"))
    }
}
#endif
