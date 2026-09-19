#if os(macOS)
import AppKit
import CoreText
import Foundation
import PDFKit
import Testing
@testable import MarsDawnExport
@testable import MarsDawnKit

/// CJK text in an exported PDF reads and searches as the ideographs the page shows, not as the
/// CJK radicals that share their glyphs (mars-dawn-kit#18).
@MainActor
@Suite(.serialized, .timeLimit(.minutes(3)))
struct ToUnicodeRepairTests {
    /// Characters whose glyph PingFang and Songti share with a radical (頁面目文示言一車馬), one
    /// that has its own glyph (食), and ones with no radical twin (中國字).
    static let fixture = "# 頁面目錄\n\n文字顯示：頁面 目 文 示 言 食 一 車 馬 中 國\n"
    static let radicalRanges: [ClosedRange<UInt32>] = [0x2E80...0x2EFF, 0x2F00...0x2FDF]

    private static func radicals(in text: String) -> [Unicode.Scalar] {
        text.unicodeScalars.filter { scalar in radicalRanges.contains { $0.contains(scalar.value) } }
    }

    private func export(_ markdown: String, theme: PreviewTheme, paper: DocumentExporter.Paper = .a4) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tounicode-\(UUID().uuidString).pdf")
        _ = try await DocumentExporter.exportPDF(
            markdown: markdown, to: url, theme: theme, baseDirectory: nil, allowRemoteImages: false, paper: paper
        )
        return url
    }

    // MARK: End to end

    /// In all three font designs (sans, serif, rounded), the text layer holds the ideographs and
    /// search finds them.
    @Test(arguments: [PreviewTheme.dawn, .classic, .vivid])
    func exportedCJKTextReadsAndSearchesAsWritten(theme: PreviewTheme) async throws {
        let url = try await export(Self.fixture, theme: theme)
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try #require(PDFDocument(url: url))
        let text = (0..<document.pageCount).compactMap { document.page(at: $0)?.string }.joined()
        #expect(Self.radicals(in: text).isEmpty, "\(theme): radicals \(Self.radicals(in: text))")
        for word in ["頁面", "目", "文", "示", "言", "一", "車", "馬", "食", "中", "國"] {
            #expect(text.contains(word), "\(theme): \(word) in the text layer")
        }
        for word in ["頁面", "目", "文", "示"] {
            #expect(!document.findString(word, withOptions: []).isEmpty, "\(theme): search finds \(word)")
        }
    }

    /// A radical the document really contains stays a radical: its glyph is the ideograph's
    /// too, so the one mapping can't be right for both, and the source decides. Other radicals
    /// in the same PDF are still repaired.
    @Test func aRadicalInTheSourceStaysARadical() async throws {
        let url = try await export("示 and the radical ⽰, and 頁面.\n", theme: .dawn)
        defer { try? FileManager.default.removeItem(at: url) }
        let text = try #require(PDFDocument(url: url)?.page(at: 0)?.string)
        #expect(text.unicodeScalars.contains("\u{2F70}"), "⽰ stays: \(text)")
        #expect(text.contains("頁面"), "頁面 is still repaired: \(text)")
    }

    /// A PDF with nothing to repair is left byte for byte as printed: no update is appended.
    @Test func anExportWithNoRadicalsGetsNoUpdate() async throws {
        let url = try await export("# Plain\n\nEnglish only, and 中國 with no radical twins.\n", theme: .dawn)
        defer { try? FileManager.default.removeItem(at: url) }
        let data = try Data(contentsOf: url)
        #expect(data.range(of: Data("/Prev".utf8)) == nil)
        #expect(Self.startXrefCount(data) == 1)
    }

    // MARK: The update itself, on PDFs drawn directly

    /// Glyph runs drawn with no Unicode, as WebKit's print path draws them: CoreGraphics then
    /// writes the radical into the ToUnicode CMap for every shared glyph.
    static func glyphRunPDF(_ runs: [(font: String, text: String)]) -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let consumer = CGDataConsumer(data: data as CFMutableData)!
        let context = CGContext(consumer: consumer, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        for (line, run) in runs.enumerated() {
            let font = CTFontCreateWithName(run.font as CFString, 20, nil)
            let characters = Array(run.text.utf16)
            var glyphs = [CGGlyph](repeating: 0, count: characters.count)
            CTFontGetGlyphsForCharacters(font, characters, &glyphs, characters.count)
            var positions = (0..<glyphs.count).map { CGPoint(x: 30 + CGFloat($0) * 22, y: 780 - CGFloat(line) * 40) }
            CTFontDrawGlyphs(font, glyphs, &positions, glyphs.count, context)
        }
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    static func startXrefCount(_ data: Data) -> Int {
        String(decoding: data, as: UTF8.self).components(separatedBy: "startxref").count - 1
    }

    /// Two fonts, so two CMaps: both are repaired, as an incremental update whose structure is
    /// checked entry by entry, and every page draws exactly as before.
    @Test func theRepairIsAValidIncrementalUpdateThatDrawsIdentically() throws {
        let original = Self.glyphRunPDF([("PingFangTC-Regular", "頁面目文示"), ("STSongti-TC-Regular", "言一車馬")])
        let before = try #require(PDFDocument(data: original)?.page(at: 0)?.string)
        #expect(!Self.radicals(in: before).isEmpty, "precondition: the drawn PDF has radicals in its text layer")

        let (repaired, outcome) = ToUnicodeRepair.repair(original, source: "")
        guard case .repaired(let cmaps, let mappings) = outcome else {
            Issue.record("expected a repair, got \(outcome)")
            return
        }
        #expect(cmaps == 2, "one CMap per font")
        #expect(mappings >= 9)

        // Incremental: the original bytes are an exact prefix.
        #expect(repaired.prefix(original.count) == original)
        // The chain: the new startxref names an xref section whose entries point at `n g obj`,
        // and whose trailer's /Prev is the original startxref.
        let originalStart = try #require(ToUnicodeRepair.lastStartXref([UInt8](original)))
        let newStart = try #require(ToUnicodeRepair.lastStartXref([UInt8](repaired)))
        #expect(newStart > original.count - 1)
        let table = try #require(ToUnicodeRepair.XrefTable([UInt8](repaired), at: newStart))
        #expect(table.entries.count == 2)
        for (number, entry) in table.entries {
            let head = String(decoding: repaired[entry.offset..<(entry.offset + 20)], as: UTF8.self)
            #expect(head.hasPrefix("\(number) \(entry.generation) obj"), "entry \(number) points at its object")
        }
        #expect(table.trailer.contains("/Prev \(originalStart)"))
        #expect(table.trailer.contains("/Root"))

        // It opens, reads as the ideographs, and draws the same.
        let after = try #require(PDFDocument(data: repaired))
        let text = try #require(after.page(at: 0)?.string)
        #expect(Self.radicals(in: text).isEmpty, "\(text)")
        #expect("頁面目文示言一車馬".allSatisfy { text.contains($0) }, "\(text)")
        let beforePage = try #require(PDFDocument(data: original)?.page(at: 0))
        #expect(Self.differingBytes(Self.raster(beforePage), Self.raster(try #require(after.page(at: 0)))) == 0)
        // The raster comparison can see a difference: a page with other text differs.
        let other = try #require(PDFDocument(data: Self.glyphRunPDF([("PingFangTC-Regular", "中國字")]))?.page(at: 0))
        #expect(Self.differingBytes(Self.raster(beforePage), Self.raster(other)) > 0)
    }

    @Test func aDrawnPDFWithNoRadicalsIsReturnedAsItIs() {
        let original = Self.glyphRunPDF([("PingFangTC-Regular", "中國字"), ("Helvetica", "Plain")])
        let (result, outcome) = ToUnicodeRepair.repair(original, source: "")
        #expect(result == original)
        #expect(outcome == .unchanged("no radical destinations"))
    }

    /// Input it doesn't understand is left exactly as it is.
    @Test func unexpectedInputIsLeftAsItIs() {
        for input in [Data(), Data("not a pdf".utf8), Data("%PDF-1.7\n1 0 obj\n<<>>\nendobj\nstartxref\n9\n%%EOF\n".utf8)] {
            let (result, outcome) = ToUnicodeRepair.repair(input, source: "")
            #expect(result == input)
            if case .repaired = outcome { Issue.record("repaired unexpected input") }
        }
        // An update already appended (a /Prev in the trailer) isn't stacked on.
        let once = ToUnicodeRepair.repair(Self.glyphRunPDF([("PingFangTC-Regular", "頁面")]), source: "").0
        let (twice, outcome) = ToUnicodeRepair.repair(once, source: "")
        #expect(twice == once)
        #expect(outcome == .unchanged("already updated"))
    }

    // MARK: CMap syntax

    @Test func bfcharBfrangeAndArraysAreAllRewritten() throws {
        let cmap = """
        /CIDInit /ProcSet findresource begin
        begincmap
        1 begincodespacerange
        <00> <ff>
        endcodespacerange
        2 beginbfchar
        <01> <2fb4>
        <02> <0041>
        endbfchar
        2 beginbfrange
        <03> <05> <2f6b>
        <06> <07> [<2f70> <4e2d>]
        endbfrange
        endcmap
        CMapName currentdict /CMap defineresource pop
        end
        """
        let (rewritten, changes) = try #require(ToUnicodeRepair.rewriteCMap(cmap, keeping: []))
        // 2FB4→9801 (頁); the range 2F6B,2F6C,2F6D→ 7528?, 76EE(目), 77DB; 2F70→793A (示).
        #expect(rewritten.contains("<01> <9801>"))
        #expect(rewritten.contains("<02> <0041>"))
        #expect(rewritten.contains("<04> <76ee>"), "the middle of a range is rewritten: \(rewritten)")
        #expect(rewritten.contains("<06> <793a>"))
        #expect(rewritten.contains("<07> <4e2d>"))
        #expect(changes == 5)
        #expect(rewritten.hasPrefix("/CIDInit"))
        #expect(rewritten.contains("endcmap\nCMapName"))
        // Keeping a radical the source contains leaves that one alone.
        let (kept, keptChanges) = try #require(ToUnicodeRepair.rewriteCMap(cmap, keeping: [0x2F70]))
        #expect(kept.contains("<06> <2f70>"))
        #expect(keptChanges == 4)
    }

    @Test func cmapSyntaxItDoesNotKnowIsRefused() {
        // Something other than whitespace between mapping blocks: not rewritten.
        #expect(ToUnicodeRepair.rewriteCMap("1 beginbfchar\n<01> <2fb4>\nendbfchar\n1 begincidrange\n<00> <ff> 1\nendcidrange\n1 beginbfchar\n<02> <2fb4>\nendbfchar\n", keeping: []) == nil)
        #expect(ToUnicodeRepair.rewriteCMap("1 beginbfchar\n<01> /notahex\nendbfchar\n", keeping: []) == nil)
    }

    // MARK: Raster

    static func raster(_ page: PDFPage) -> [UInt8] {
        let box = page.bounds(for: .mediaBox)
        let width = Int(box.width * 2), height = Int(box.height * 2)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { raw in
            let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            context.setFillColor(.white)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.scaleBy(x: 2, y: 2)
            page.draw(with: .mediaBox, to: context)
        }
        return pixels
    }

    static func differingBytes(_ a: [UInt8], _ b: [UInt8]) -> Int {
        guard a.count == b.count else { return max(a.count, b.count) }
        return zip(a, b).reduce(0) { $0 + ($1.0 == $1.1 ? 0 : 1) }
    }
}
#endif
