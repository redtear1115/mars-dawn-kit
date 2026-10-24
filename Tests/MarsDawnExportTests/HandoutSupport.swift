#if os(macOS)
import AppKit
import Foundation
import PDFKit
import Testing
@testable import MarsDawnExport

/// Instruments for the handout layout's tests (mars-dawn#432 S3). Like `ManualProbe`, they read
/// the PDF itself: PDFKit text and its line boxes, the outline, the font dictionaries, pixels.
@MainActor
enum HandoutProbe {
    /// A footer line: "name · date · n / N", or "date · n / N" without a name.
    static let footerPattern = /^(?:(.+) · )?(.+) · (\d+) \/ (\d+)$/

    /// The footer line of a page: the last line that reads like a footer. Not always the
    /// page's last line: PDFKit can order a table's cells near the bottom after it.
    static func footer(_ text: String) -> String? {
        ManualProbe.lines(text).last { $0.wholeMatch(of: footerPattern) != nil }
    }

    /// Page text without its footer line.
    static func withoutFooter(_ text: String) -> String {
        var all = ManualProbe.lines(text)
        if let index = all.lastIndex(where: { $0.wholeMatch(of: footerPattern) != nil }) { all.remove(at: index) }
        return all.joined(separator: "\n")
    }

    /// The body's right edge on paper `width` points wide: where the notes column starts.
    static func bodyMaxX(paperWidth width: CGFloat) -> CGFloat { width - ExportLayout.handout.bodyMargins.right }

    /// Every page's text lines lie between the left margin and the printable width's right
    /// edge (a spanning table may reach past the body's, A1-R2; `column` checks those).
    static func assertInsideBody(_ extents: [CGRect?], paper: CGSize, name: String) {
        let left = ExportLayout.handout.pageMargins.left
        let right = paper.width - ExportLayout.handout.pageMargins.right
        for (index, extent) in extents.enumerated() {
            guard let extent else { continue }
            #expect(extent.minX >= left - 0.5, "\(name): page \(index + 1) text starts at x \(extent.minX), margin \(left)")
            #expect(extent.maxX <= right + 0.5, "\(name): page \(index + 1) text ends at x \(extent.maxX), body edge \(right)")
        }
    }

    /// Text lines that reach past the body's right edge, per page (0-based) with their text.
    static func linesInColumn(_ document: PDFDocument) -> [(page: Int, text: String)] {
        var found: [(page: Int, text: String)] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let right = bodyMaxX(paperWidth: page.bounds(for: .mediaBox).width)
            for line in page.selection(for: page.bounds(for: .mediaBox))?.selectionsByLine() ?? [] {
                let box = line.bounds(for: page)
                if !box.isEmpty, box.maxX > right + 0.5 { found.append((index, line.string ?? "")) }
            }
        }
        return found
    }

    /// Text-line boxes per page that reach past the body's right edge, as "page:text" strings.
    static func textInColumn(_ document: PDFDocument) -> [String] {
        linesInColumn(document).map { "\($0.page + 1):\($0.text)" }
    }

    /// The notes column under amendment A1-R2: text there must be a table's that was let into
    /// it (`.span` or `.wide`), and ink there may only be on a page carrying such a table.
    struct Column {
        /// 1-based pages where a spanning table's text is in the column.
        var spanningPages: [Int] = []
        /// Column text that belongs to no spanning table, as "page:text".
        var strayText: [String] = []
        /// 1-based pages with ink in the column and no spanning table.
        var strayInk: [String] = []
    }

    static func column(_ document: PDFDocument, tables: [HandoutLayout.TableFit]) -> Column {
        let spanning = tables.filter { $0.kind != .natural }.map { corpusNormalize($0.text) }
        var column = Column()
        for line in linesInColumn(document) {
            let text = corpusNormalize(line.text)
            if !text.isEmpty, spanning.contains(where: { $0.contains(text) }) {
                if !column.spanningPages.contains(line.page + 1) { column.spanningPages.append(line.page + 1) }
            } else {
                column.strayText.append("\(line.page + 1):\(line.text)")
            }
        }
        column.strayInk = inkInColumn(document).filter { entry in
            !column.spanningPages.contains(Int(entry.split(separator: ":")[0]) ?? 0)
        }
        return column
    }

    /// Pixels painted right of the printable width (the outer margin), as "page:count".
    static func inkPastPrintable(_ document: PDFDocument) -> [String] {
        ink(document) { box in (box.width - ExportLayout.handout.pageMargins.right + 1, nil) }
    }

    /// Pixels painted in the notes column (from just right of the body's edge to the paper's
    /// edge, between the top and bottom margins), other than the column's own rule, as
    /// "page:count". Rendered at 2x on white.
    static func inkInColumn(_ document: PDFDocument) -> [String] {
        ink(document) { box in (bodyMaxX(paperWidth: box.width) + 1, bodyMaxX(paperWidth: box.width) + 12) }
    }

    /// Pixels painted from x `from` (points) to the paper's edge, between the top and bottom
    /// margins, other than a 3 pt band around `skip` (the column's rule), as "page:count".
    static func ink(_ document: PDFDocument, region: (CGRect) -> (from: CGFloat, skip: CGFloat?)?) -> [String] {
        var found: [String] = []
        let margins = ExportLayout.handout.bodyMargins
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let box = page.bounds(for: .mediaBox)
            let scale: CGFloat = 2
            let width = Int(box.width * scale), height = Int(box.height * scale)
            guard let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ), let pixels = { () -> UnsafeMutablePointer<UInt8>? in
                context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                context.scaleBy(x: scale, y: scale)
                page.draw(with: .mediaBox, to: context)
                return context.data?.assumingMemoryBound(to: UInt8.self)
            }(), let (from, skip) = region(box) else { continue }
            let columns = Int(from * scale)..<width
            // Rows from the top: the top margin down to the bottom margin.
            let rows = Int(margins.top * scale)..<(height - Int(margins.bottom * scale))
            var count = 0
            for row in rows {
                for column in columns where skip.map({ abs(CGFloat(column) / scale - $0) > 1.5 }) ?? true {
                    let offset = (row * width + column) * 4
                    if pixels[offset] < 245 || pixels[offset + 1] < 245 || pixels[offset + 2] < 245 { count += 1 }
                }
            }
            if count > 0 { found.append("\(index + 1):\(count)") }
        }
        return found
    }

    /// The box of a page's footer line (PDF points): the lowest line whose text reads like a footer.
    static func footerBox(_ page: PDFPage) -> CGRect? {
        let lines = page.selection(for: page.bounds(for: .mediaBox))?.selectionsByLine() ?? []
        return lines
            .filter { ($0.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).wholeMatch(of: footerPattern) != nil }
            .map { $0.bounds(for: page) }
            .min { $0.minY < $1.minY }
    }

    /// Where the notes column's rule is drawn: 12 pt right of the body's edge (read here from the
    /// margins, not from `HandoutLayout.Footers`, whose position this checks).
    static func ruleX(paperWidth width: CGFloat) -> CGFloat { bodyMaxX(paperWidth: width) + 12 }

    /// The share of rows between the top and bottom margins that have a painted pixel within
    /// 1.5 pt of the rule's x on page `index`, rendered at 2x on white: 1 for a rule that runs the
    /// whole height, 0 where nothing is drawn there.
    static func ruleCoverage(_ document: PDFDocument, page index: Int) -> Double {
        guard let page = document.page(at: index) else { return 0 }
        let box = page.bounds(for: .mediaBox)
        let scale: CGFloat = 2
        let width = Int(box.width * scale), height = Int(box.height * scale)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return 0 }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        guard let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return 0 }
        let x = ruleX(paperWidth: box.width)
        let columns = Int((x - 1.5) * scale)...Int((x + 1.5) * scale)
        let margins = ExportLayout.handout.bodyMargins
        let rows = Int(margins.top * scale)..<(height - Int(margins.bottom * scale))
        let painted = rows.filter { row in
            columns.contains { column in
                let offset = (row * width + column) * 4
                return pixels[offset] < 245 || pixels[offset + 1] < 245 || pixels[offset + 2] < 245
            }
        }
        return Double(painted.count) / Double(rows.count)
    }

    /// How many font dictionaries name each base font (subset tag removed).
    static func fontCounts(_ data: Data) -> [String: Int] {
        ManualProbe.fontDictionaries(data).reduce(into: [:]) { $0[$1.baseFont, default: 0] += 1 }
    }

    /// The front matter's `date` line, read here with a plain pattern (not the layout's reader).
    static func frontMatterDate(_ markdown: String) -> String? {
        markdown.firstMatch(of: /(?m)^date: (.+)$/).map { String($0.1) }
    }
}

extension PDFCorpus {
    /// The handout layout's own checks (S3 of mars-dawn#432) on a corpus fixture.
    static func assertHandout(_ outcome: ExportOutcome, fixture: CorpusFixture) {
        let name = fixture.name
        #expect(outcome.manual == nil, "\(name): the handout ran the manual layout's passes")
        guard let report = outcome.handout else {
            Issue.record("\(name): the handout layout's run reported nothing")
            return
        }
        guard let document = PDFDocument(data: outcome.data) else {
            Issue.record("\(name): the final file doesn't open")
            return
        }
        // No cover, contents or bookmarks; no name in the document's metadata.
        #expect(document.outlineRoot == nil || document.outlineRoot?.numberOfChildren == 0, "\(name): the handout has an outline")
        let attributes = document.documentAttributes ?? [:]
        #expect(attributes[PDFDocumentAttribute.titleAttribute] == nil, "\(name): PDF /Title \(String(describing: attributes[PDFDocumentAttribute.titleAttribute]))")
        // Footer on every page: name · date · n / N, as the reader sees it.
        let date = HandoutProbe.frontMatterDate(fixture.markdown)
        let total = outcome.pageTexts.count
        for (index, text) in outcome.pageTexts.enumerated() {
            let expected = [fixture.expectation.displayName, date].compactMap { $0 }.joined(separator: " · ") + " · \(index + 1) / \(total)"
            #expect(HandoutProbe.footer(text) == expected, "\(name): page \(index + 1) footer \(String(describing: HandoutProbe.footer(text))), expected \(expected)")
        }
        // The footer's fonts are its own: each appears in one font dictionary at most.
        let counts = HandoutProbe.fontCounts(outcome.data)
        for font in report.footerFonts {
            #expect((counts[font] ?? 0) <= 1, "\(name): \(font) is in \(counts[font] ?? 0) font dictionaries; the body uses it too")
        }
        switch fixture.expectation.repair {
        case "repaired":
            if case .repaired = report.repair {} else { Issue.record("\(name): repair \(report.repair), expected repaired") }
        case "unchanged":
            #expect(report.repair == .unchanged("no radical destinations"), "\(name): repair \(report.repair)")
        default:
            break
        }
        let column = HandoutProbe.column(document, tables: report.tables)
        #expect(column.strayText.isEmpty, "\(name): text in the notes column outside a spanning table: \(column.strayText)")
        #expect(column.strayInk.isEmpty, "\(name): ink in the notes column on a page without a spanning table: \(column.strayInk)")
        #expect(HandoutProbe.inkPastPrintable(document).isEmpty, "\(name): ink past the printable width: \(HandoutProbe.inkPastPrintable(document))")
    }
}
#endif
