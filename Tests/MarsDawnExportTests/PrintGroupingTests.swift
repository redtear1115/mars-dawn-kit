#if os(macOS)
import AppKit
import Foundation
import PDFKit
import Testing
@testable import MarsDawnExport

/// mars-dawn#15: right before printing, the export puts `#content`'s top-level blocks into plain
/// groups of `printGroupSize`, so WebKit's paint of each page stops walking every block of the
/// document. The groups must change nothing that prints: every layout's PDF is compared, line by
/// line and position by position, with the same export printed ungrouped (the control).
@MainActor
@Suite(.serialized, .timeLimit(.minutes(10)))
struct PrintGroupingTests {
    /// A page's text lines with their boxes, to a hundredth of a point.
    struct Printed: Equatable {
        var pages: [[String]]
        var texts: [String]
        var groups: Int
    }

    static func export(_ markdown: String, layout: ExportLayout, grouped: Bool) async throws -> Printed {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("print-groups-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("out.pdf")
        var exporter: DocumentExporter?
        _ = try await DocumentExporter.exportPDF(
            markdown: markdown, to: url, theme: .dawn, baseDirectory: nil, allowRemoteImages: false,
            layout: layout, displayName: "Groups", calloutTitles: .english,
            inspect: { $0.groupsBlocksForPrint = grouped; exporter = $0 },
            hooks: { var hooks = ManualHooks(); hooks.now = Date(timeIntervalSince1970: 1_800_000_000); hooks.timeZone = TimeZone(identifier: "UTC"); return hooks }()
        )
        let document = try #require(PDFDocument(url: url))
        let pages = (0..<document.pageCount).map { index -> [String] in
            guard let page = document.page(at: index) else { return [] }
            return (page.selection(for: page.bounds(for: .mediaBox))?.selectionsByLine() ?? []).map { line in
                let box = line.bounds(for: page)
                let text = (line.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                return String(format: "%@ @ %.2f %.2f %.2f %.2f", text, box.minX, box.minY, box.width, box.height)
            }
        }
        let texts = (0..<document.pageCount).map { document.page(at: $0)?.string ?? "" }
        return Printed(pages: pages, texts: texts, groups: exporter?.printGroupCount ?? -1)
    }

    /// Exports `markdown` grouped and ungrouped and expects the same PDF text in the same places.
    static func expectSamePrint(_ markdown: String, layout: ExportLayout, minimumGroups: Int,
                                sourceLocation: SourceLocation = #_sourceLocation) async throws -> Printed {
        let grouped = try await export(markdown, layout: layout, grouped: true)
        let control = try await export(markdown, layout: layout, grouped: false)
        #expect(grouped.groups >= minimumGroups, "positive: the page printed in groups", sourceLocation: sourceLocation)
        #expect(control.groups == 0, "control: the page printed ungrouped", sourceLocation: sourceLocation)
        #expect(grouped.pages.count == control.pages.count, "\(layout): page count", sourceLocation: sourceLocation)
        for index in 0..<min(grouped.pages.count, control.pages.count) where grouped.pages[index] != control.pages[index] {
            Issue.record("\(layout): page \(index + 1) differs:\n\(grouped.pages[index].joined(separator: "\n"))\n--- ungrouped ---\n\(control.pages[index].joined(separator: "\n"))",
                         sourceLocation: sourceLocation)
        }
        return grouped
    }

    /// Top-level blocks at known places: with no heading before them, every paragraph and
    /// `<!--BREAK-->` marker is one block of `#content`, so the blocks around a group's edge are
    /// known. A break lands on a group's first block (index 50), one inside a group (61), and the
    /// handbook's `#` breaks land on a group's last block (99, a heading kept with its paragraph)
    /// and first block (100).
    nonisolated static let boundaries: String = {
        var blocks: [String] = []
        func paragraph(_ n: Int) { blocks.append("Paragraph P\(n) with enough words to fill part of a line in the export.") }
        for n in 0..<49 { paragraph(n) }
        blocks.append("<!--BREAK-->")                                    // 49: last of group 1
        blocks.append("After break one: first of group two.")           // 50: first of group 2
        for n in 51..<60 { paragraph(n) }
        blocks.append("<!--BREAK-->")                                    // 60
        blocks.append("After break two: inside group two.")             // 61
        for n in 62..<99 { paragraph(n) }
        blocks.append("# Chapter Last Of Group\n\nChapter one's paragraph.") // 99: kept, last of group 2
        blocks.append("# Chapter First Of Group\n\nChapter two's paragraph.") // 100: kept, first of group 3
        for n in 101..<160 { paragraph(n) }
        return blocks.joined(separator: "\n\n") + "\n"
    }()

    /// Many kinds of block, headings kept with what follows, runs of headings, and breaks.
    nonisolated static let mixed: String = {
        var blocks: [String] = []
        for n in 0..<60 {
            switch n % 10 {
            case 0: blocks.append("## Section \(n)\n\n### Sub \(n)\n\nIntro for section \(n), short.")
            case 1: blocks.append("```swift\n" + (0..<(n % 23 + 3)).map { "let line\($0) = \($0 * n)" }.joined(separator: "\n") + "\n```")
            case 2: blocks.append("- item a \(n)\n- item b \(n)\n  - nested \(n)\n- item c")
            case 3: blocks.append("> Quoted \(n), a few words long.\n>\n> Second paragraph of the quote.")
            case 4: blocks.append("| A | B | C |\n|---|---|---|\n" + (0..<(n % 7 + 2)).map { "| a\($0) | b\($0) | c\($0) |" }.joined(separator: "\n"))
            case 5: blocks.append("#### Small heading \(n)\n\n" + String(repeating: "Longer text for block \(n). ", count: 30))
            case 6: blocks.append("<!--BREAK-->")
            case 7: blocks.append("# Top \(n)\n\nUnder the top heading.")
            case 8: blocks.append("$$\nx_{\(n)} = \\frac{a}{b}\n$$")
            default: blocks.append("Plain paragraph \(n).\n\n---")
            }
        }
        return blocks.joined(separator: "\n\n") + "\n"
    }()

    @Test(arguments: [ExportLayout.document, .manual, .handout])
    func groupsPrintTheSameAtGroupEdges(layout: ExportLayout) async throws {
        let printed = try await Self.expectSamePrint(Self.boundaries, layout: layout, minimumGroups: 3)
        // The breaks did break: the block after each marker starts a page (positive, in every layout).
        for opening in ["After break one", "After break two"] {
            let page = try #require(printed.texts.firstIndex { $0.contains(opening) }, "\(opening) printed")
            let first = printed.texts[page].components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
            #expect(first?.hasPrefix(opening) == true, "\(layout): \(opening) starts page \(page + 1)")
        }
        if layout == .manual {
            for heading in ["Chapter Last Of Group", "Chapter First Of Group"] {
                let pages = printed.texts.indices.filter { printed.texts[$0].contains(heading) }
                let page = try #require(pages.last, "\(heading) printed")
                let first = printed.texts[page].components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
                #expect(first?.contains(heading) == true, "manual: \(heading) starts page \(page + 1)")
            }
        }
    }

    @Test(arguments: [ExportLayout.document, .manual, .handout])
    func groupsPrintTheSameForMixedBlocks(layout: ExportLayout) async throws {
        _ = try await Self.expectSamePrint(Self.mixed, layout: layout, minimumGroups: 2)
    }

    /// A code block too tall (over 300 px) for keep-with-next to keep a heading with it.
    nonisolated static let tallCode: String = "```\n" + (0..<40).map { "line \($0)" }.joined(separator: "\n") + "\n```\n\n"

    /// The first block's top margin is dropped (`.markdown-body > :first-child`), grouped too: a
    /// rule and a heading (too tall a block after it to be kept with it) have one to drop; a kept
    /// heading, front matter (not printed) and a paragraph are the other first blocks there are.
    @Test(arguments: [
        "***\n\n" + boundaries,
        "# Opening heading\n\n" + tallCode + boundaries,
        "# Opening heading\n\n" + boundaries,
        "---\ntitle: Front\n---\n\n## Opening after front matter\n\n" + boundaries,
        "Opening paragraph.\n\n" + boundaries,
    ])
    func theFirstBlockKeepsItsPlace(markdown: String) async throws {
        _ = try await Self.expectSamePrint(markdown, layout: .document, minimumGroups: 3)
    }

    /// The document's own CSS can select by a block's place under `#content` or match any `div`,
    /// so a document that brings a `<style>` is printed ungrouped, exactly like the control.
    /// Grouped, the first would print in 4 pages instead of 7 (its paragraphs no longer matched),
    /// and the second would draw the bar beside every group, moving every line right.
    @Test(arguments: [
        "<style>#content > p { font-size: 28px; }</style>\n\n",
        "<style>#content > div { border-left: 30px solid red; }</style>\n\n",
        "<svg width=\"0\" height=\"0\"><STYLE>#content > p { font-size: 28px; }</STYLE></svg>\n\n",
    ])
    func aDocumentWithItsOwnCSSIsNotGrouped(style: String) async throws {
        let printed = try await Self.expectSamePrint(style + Self.boundaries, layout: .document, minimumGroups: 0)
        #expect(printed.groups == 0, "printed ungrouped")
    }

    /// A `style` attribute applies wherever its element is, and a Mermaid diagram's SVG brings a
    /// `<style>` of its own on the page: neither turns grouping off.
    @Test(arguments: [
        "<p style=\"font-size: 28px; border-left: 4px solid red\">Styled paragraph.</p>\n\n<div style=\"margin: 12px\">Styled div.</div>\n\n",
        "```mermaid\ngraph TD\n  A --> B\n```\n\n",
    ])
    func inlineStylesAndDiagramsStillGroup(opening: String) async throws {
        _ = try await Self.expectSamePrint(opening + Self.boundaries, layout: .document, minimumGroups: 3)
    }

    @Test func authorCSSIsFoundInTheRenderedHTML() {
        #expect(DocumentExporter.bringsItsOwnCSS("<p>a</p><style>p{}</style>"))
        #expect(DocumentExporter.bringsItsOwnCSS("<svg><StYlE>p{}</StYlE></svg>"))
        #expect(!DocumentExporter.bringsItsOwnCSS("<p style=\"color: red\">a</p><pre><code>&lt;style&gt;</code></pre>"))
    }

    /// A short document has nothing to group, and prints as it did.
    @Test func aShortDocumentIsNotGrouped() async throws {
        let printed = try await Self.export("# Title\n\nOne paragraph.\n", layout: .document, grouped: true)
        #expect(printed.groups == 0)
        #expect(printed.texts.count == 1)
    }
}
#endif
