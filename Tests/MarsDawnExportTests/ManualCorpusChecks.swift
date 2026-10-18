#if os(macOS)
import Foundation
import PDFKit
import Testing
@testable import MarsDawnExport
@testable import MarsDawnKit

/// The manual layout's checks on every manual corpus fixture (S2 of mars-dawn#432), run on the
/// same export as the corpus's other tiers. Truth is the final PDF's own text, annotations,
/// outline and CMaps; the exporter's report only says what it meant to do.
extension PDFCorpus {
    static func assertManual(_ outcome: ExportOutcome, fixture: CorpusFixture) throws {
        let name = fixture.name
        let expectation = fixture.expectation
        let report = try #require(outcome.manual, "\(name): the manual layout produced no report")
        let document = try #require(PDFDocument(data: outcome.data))
        let texts = outcome.pageTexts
        let bodyStart = report.bodyStart
        let hasCover = report.cover != nil
        let tocRange = (hasCover ? 1 : 0)..<bodyStart
        let bodyPages = texts.count - bodyStart

        // C: the cover is page 1 when, and only when, the front matter has a title.
        if let cover = expectation.cover { #expect(hasCover == cover, "\(name): cover \(hasCover), expected \(cover)") }
        if let cover = report.cover {
            #expect(ManualProbe.collapse(texts[0]).contains(ManualProbe.collapse(cover.title)), "\(name): page 1 doesn't show the title")
        }
        if let logo = expectation.logo {
            #expect((ManualProbe.imageXObjects(outcome.data, page: 0) > 0) == logo, "\(name): cover image \(logo ? "missing" : "unexpected")")
        }

        // PS: contents pages, then the body from a new page; no blank page.
        if let entries = expectation.tocEntries { #expect(report.headings.count == entries, "\(name): \(report.headings.count) contents entries") }
        #expect(tocRange.isEmpty == report.headings.isEmpty, "\(name): contents pages \(tocRange) for \(report.headings.count) headings")
        if let minTocPages = expectation.minTocPages {
            #expect(tocRange.count >= minTocPages, "\(name): the contents has \(tocRange.count) pages, expected at least \(minTocPages)")
        }
        #expect(bodyPages >= 1, "\(name): no body page")
        for (index, text) in texts.enumerated() {
            #expect(!ManualProbe.withoutFooter(text).isEmpty, "\(name): page \(index + 1) has nothing but a footer")
        }

        // F: "n / N" on every body page, counted from the body; none on the cover or contents.
        for (index, text) in texts.enumerated() {
            let footer = ManualProbe.footer(text)
            if index < bodyStart {
                #expect(footer == nil, "\(name): page \(index + 1) (cover/contents) has a footer")
            } else {
                #expect(footer?.n == index - bodyStart + 1 && footer?.total == bodyPages,
                        "\(name): page \(index + 1) footer \(String(describing: footer)), expected \(index - bodyStart + 1) / \(bodyPages)")
            }
        }

        // M1: each contents number is the body page its heading starts on, by the PDF's text.
        let truth = ManualProbe.truthPages(headings: report.headings, pageTexts: texts, bodyStart: bodyStart)
        for (index, heading) in report.headings.enumerated() {
            guard let page = truth[index] else {
                Issue.record("\(name): heading \(index) \"\(heading.text)\" not found in the body text")
                continue
            }
            #expect(report.numbers[index] == page - bodyStart + 1,
                    "\(name): heading \(index) \"\(heading.text)\" numbered \(String(describing: report.numbers[index])), starts on body page \(page - bodyStart + 1)")
        }
        // ...and the contents pages show those numbers, entry after entry.
        let tocText = corpusNormalize(texts[tocRange].joined(separator: "\n"))
        var cursor = tocText.startIndex
        for (index, heading) in report.headings.enumerated() {
            let entry = corpusNormalize(heading.text + (report.numbers[index].map(String.init) ?? ""))
            guard let found = tocText.range(of: entry, range: cursor..<tocText.endIndex) else {
                Issue.record("\(name): the contents doesn't show \"\(heading.text)\" with \(String(describing: report.numbers[index]))")
                continue
            }
            cursor = found.upperBound
        }

        // M2: pass A and pass B paginate alike (markers stripped, contents digits ignored).
        let passA = ManualProbe.pageTexts(report.passA), passB = ManualProbe.pageTexts(report.passB)
        #expect(passA.count == passB.count && passB.count == texts.count, "\(name): pages A \(passA.count), B \(passB.count), final \(texts.count)")
        let markers = try Regex(report.token + "(H[0-9]+|E)Z")
        func comparable(_ text: String, page: Int) -> [String] {
            var text = text.replacing(markers, with: "")
            if page < bodyStart { text = text.replacing(/[0-9]/, with: "") }
            return ManualProbe.lines(text)
        }
        for page in 0..<min(passA.count, passB.count) where comparable(passA[page], page: page) != comparable(passB[page], page: page) {
            Issue.record("\(name): page \(page + 1) differs between pass A and pass B")
        }
        // The markers being stripped above were really there (and only in pass A).
        if hasCover || !report.headings.isEmpty {
            #expect(passA.joined().contains(report.token), "\(name): pass A carries no marker")
        }
        #expect(!passB.joined().contains(report.token), "\(name): pass B still carries a marker")

        // F: the repair ran once on the final file, with one of the two allowed outcomes.
        switch report.repair {
        case .repaired:
            #expect(expectation.repair != "unchanged", "\(name): repair \(report.repair), expected unchanged")
        case .unchanged(let reason):
            #expect(reason == "no radical destinations", "\(name): repair left the file for \"\(reason)\"")
            #expect(expectation.repair != "repaired", "\(name): repair \(report.repair), expected repaired")
        }
        // ...checked at the CMap level, which PDFKit's own text extraction can hide.
        // The footer font maps only " ", "/" and digits: through its ToUnicode CMap if it has
        // one, else through a standard single-byte encoding over codes 32 ("  ") to 57 ("9").
        let cmaps = ManualProbe.cmapDestinations(outcome.data)
        let footerFonts = ManualProbe.fontDictionaries(outcome.data).filter { $0.baseFont == report.footerFont }
        #expect(!footerFonts.isEmpty, "\(name): no font dictionary for the footer font \(report.footerFont)")
        let footerAlphabet = Set("0123456789 /".unicodeScalars.map(\.value))
        for font in footerFonts {
            if font.hasToUnicode {
                for cmap in cmaps where cmap.font == report.footerFont {
                    #expect(cmap.destinations.isSubset(of: footerAlphabet), "\(name): footer CMap maps \(cmap.destinations.subtracting(footerAlphabet).sorted())")
                }
            } else {
                #expect(["MacRomanEncoding", "WinAnsiEncoding", "StandardEncoding"].contains(font.encoding ?? "")
                        && font.subtype == "TrueType" && (font.firstChar ?? 0) >= 32 && (font.lastChar ?? 999) <= 57,
                        "\(name): footer font \(font) is not a single-byte font over \" /0-9\"")
            }
        }
        let sourceRadicals = ManualProbe.radicals(in: Set(fixture.markdown.unicodeScalars.map(\.value)))
        for cmap in cmaps where cmap.font != report.footerFont {
            let extra = ManualProbe.radicals(in: cmap.destinations).subtracting(sourceRadicals)
            #expect(extra.isEmpty, "\(name): \(cmap.font) still maps radicals \(extra.sorted().map { String(format: "U+%04X", $0) })")
        }

        // O: bookmarks are the h1/h2 headings, nested, pointing at the pages they start on.
        var expectedOutline: [ManualProbe.OutlineEntry] = []
        var sawChapter = false
        for (index, heading) in report.headings.enumerated() {
            guard let page = truth[index] else { continue }
            if heading.level == 1 { sawChapter = true }
            expectedOutline.append(.init(label: heading.text, depth: heading.level == 2 && sawChapter ? 1 : 0, page: page))
        }
        #expect(ManualProbe.outline(document) == expectedOutline, "\(name): outline differs from the headings")

        // L: the PDFKit write keeps every link; the contents entries link to their headings.
        let printed = try #require(PDFDocument(data: report.passB))
        let before = ManualProbe.links(printed), after = ManualProbe.links(document)
        #expect(before == after, "\(name): links before the write \(before), after \(after)")
        var tocTargets: [(page: Int, y: CGFloat)] = []
        for index in tocRange {
            guard let page = document.page(at: index) else { continue }
            for link in page.annotations.filter({ $0.type == "Link" && $0.url == nil }).sorted(by: { $0.bounds.maxY > $1.bounds.maxY }) {
                guard let destination = link.destination, let target = destination.page else { continue }
                let entry = (document.index(for: target), destination.point.y)
                // A wrapped entry is one link drawn as two boxes.
                if let last = tocTargets.last, last.page == entry.0, abs(last.y - entry.1) < 0.5 { continue }
                tocTargets.append(entry)
            }
        }
        #expect(tocTargets.map(\.page) == truth.compactMap { $0 }, "\(name): contents links go to pages \(tocTargets.map(\.page)), headings start on \(truth)")

        // SEC-5: nothing about the export's own files or markers reaches the final file.
        let bytes = String(decoding: outcome.data, as: UTF8.self)
        for leak in [report.token, "/Users/", ".tmp.pdf", "marsdawn-manual-", report.workDirectory.path] {
            #expect(!bytes.contains(leak) && !texts.joined().contains(leak), "\(name): the final PDF contains \(leak)")
        }
    }
}
#endif
