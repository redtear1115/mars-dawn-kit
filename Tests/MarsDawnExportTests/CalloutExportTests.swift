#if os(macOS)
import AppKit
import Foundation
import PDFKit
import Testing
@testable import MarsDawnExport
@testable import MarsDawnKit

/// Callouts in the exported PDF (kit #135): the same bar and the same titles as the preview,
/// in the language the exporter is given.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(5)))
struct CalloutExportTests {
    struct Language: Sendable, CustomTestStringConvertible {
        let name: String
        let titles: CalloutTitles
        let words: [String]
        var testDescription: String { name }
    }

    nonisolated static let languages = [
        Language(name: "en", titles: .english, words: ["Note", "Tip", "Important", "Warning", "Caution"]),
        Language(name: "zh-Hant", titles: CalloutTitles(note: "附註", tip: "提示", important: "重要", warning: "警告", caution: "小心"),
                 words: ["附註", "提示", "重要", "警告", "小心"]),
        Language(name: "ja", titles: CalloutTitles(note: "メモ", tip: "ヒント", important: "重要", warning: "警告", caution: "危険"),
                 words: ["メモ", "ヒント", "重要", "警告", "危険"]),
    ]

    /// One callout of every type, each on a line of its own so the bar's rows are easy to find.
    static let markdown = """
    > [!NOTE]
    > alpha bravo

    > [!TIP]
    > charlie delta

    > [!IMPORTANT]
    > echo foxtrot

    > [!WARNING]
    > golf hotel

    > [!CAUTION]
    > india juliet
    """

    private func export(_ titles: CalloutTitles) async throws -> PDFDocument {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("callouts-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try await DocumentExporter.exportPDF(
            markdown: Self.markdown, to: url, theme: .dawn, baseDirectory: nil, allowRemoteImages: false, calloutTitles: titles
        )
        return try #require(PDFDocument(url: url))
    }

    @Test(arguments: languages)
    func eachExportPrintsItsOwnLanguagesTitles(_ language: Language) async throws {
        let document = try await export(language.titles)
        let text = (0..<document.pageCount).compactMap { document.page(at: $0)?.string }.joined(separator: "\n")
        for word in language.words {
            #expect(text.contains(word), "\(language.name): \(word) missing from \(text.debugDescription)")
        }
        for other in Self.languages where other.name != language.name {
            for word in other.words where !language.words.contains(word) {
                #expect(!text.contains(word), "\(language.name): \(other.name)'s \(word) is in the PDF")
            }
        }
        for body in ["alpha", "charlie", "echo", "golf", "india"] { #expect(text.contains(body)) }
        #expect(!text.contains("[!"), "no marker line reaches the PDF")
    }

    /// The bar is drawn: left of each title, at the callout's edge, the page has the role's colour.
    @Test func theBarIsDrawnAtTheCalloutsEdge() async throws {
        let document = try await export(.english)
        let page = try #require(document.page(at: 0))
        let box = page.bounds(for: .mediaBox)
        let scale: CGFloat = 4
        let context = try #require(Self.render(page, scale: scale))
        let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        // Dawn on white paper: accent, string, function, number, keyword (the mapping approved on kit #135).
        let palette = try #require(PreviewTheme.dawn.validated?.light)
        let expected = [palette.accent, palette.syntax.string, palette.syntax.function, palette.syntax.number, palette.syntax.keyword]
        for (word, hex) in zip(Self.languages[0].words, expected) {
            let selection = try #require(document.findString(word, withOptions: []).first, "\(word) is on the page")
            let bounds = selection.bounds(for: page)
            let centre = bounds.midY
            let row = Int((box.height - centre) * scale)
            var best = CGFloat.greatestFiniteMagnitude
            var bestX: CGFloat = 0
            // From 40 pt left of the title to its edge: the 4 px bar is about 19 px from the text.
            for x in Int((bounds.minX - 40) * scale)..<Int(bounds.minX * scale) {
                guard (0..<context.width).contains(x), (0..<context.height).contains(row) else { continue }
                let offset = (row * context.width + x) * 4
                let colour = NSColor(
                    srgbRed: CGFloat(pixels[offset]) / 255, green: CGFloat(pixels[offset + 1]) / 255,
                    blue: CGFloat(pixels[offset + 2]) / 255, alpha: 1
                )
                let distance = Self.distance(colour, hex)
                if distance < best { best = distance; bestX = CGFloat(x) / scale }
            }
            #expect(best < 0.16, "\(word): nearest to \(hex) left of the title is \(best) away (at x \(bestX), title at \(bounds.minX))")
            #expect(bounds.minX - bestX > 8 && bounds.minX - bestX < 30, "\(word): the bar is at x \(bestX), the title at \(bounds.minX)")
        }
    }

    /// `page` drawn on white at `scale` into an sRGB bitmap; row 0 of its memory is the top. Not
    /// `PDFPage.thumbnail(of:for:)`: that renders in the main display's colour space, so the pixels
    /// differ from machine to machine (kit #241).
    private static func render(_ page: PDFPage, scale: CGFloat) -> CGContext? {
        let box = page.bounds(for: .mediaBox)
        let width = Int(box.width * scale), height = Int(box.height * scale)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        return context
    }

    private static func distance(_ colour: NSColor, _ hex: String) -> CGFloat {
        let value = UInt32(hex.dropFirst(), radix: 16) ?? 0
        let r = CGFloat((value >> 16) & 0xFF) / 255, g = CGFloat((value >> 8) & 0xFF) / 255, b = CGFloat(value & 0xFF) / 255
        return ((colour.redComponent - r) * (colour.redComponent - r) + (colour.greenComponent - g) * (colour.greenComponent - g)
            + (colour.blueComponent - b) * (colour.blueComponent - b)).squareRoot()
    }
}
#endif
