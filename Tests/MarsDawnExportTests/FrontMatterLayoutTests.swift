#if os(macOS)
import Testing
@testable import MarsDawnExport

/// Front-matter layout choices shared by the app and CLI (mars-dawn#668).
struct FrontMatterLayoutTests {
    @Test func recognizedValues() {
        let values: [(String, ExportLayout)] = [
            ("handbook", .manual), ("handout", .handout),
            ("standard", .document), ("document", .document),
            ("\"HANDBOOK\"", .manual), ("'HANDOUT'", .handout),
            ("STANDARD", .document), ("\"  Document  \"", .document),
        ]
        for (value, expected) in values {
            #expect(ExportLayout.frontMatterLayout("---\nlayout: \(value)\n---\n# Title") == expected)
        }
    }

    @Test func unknownAndEmptyValuesAreIgnored() {
        for value in ["unknown", "manual", "", "\"\"", "'   '"] {
            #expect(ExportLayout.frontMatterLayout("---\nlayout: \(value)\n---\n# Title") == nil)
        }
    }

    @Test func onlyFrontMatterIsRead() {
        #expect(ExportLayout.frontMatterLayout("# Title") == nil)
        #expect(ExportLayout.frontMatterLayout("layout: handbook") == nil)
        #expect(ExportLayout.frontMatterLayout("---\ntitle: Title\n---\nlayout: handbook") == nil)
    }

    @Test func firstOccurrenceWins() {
        #expect(ExportLayout.frontMatterLayout("---\nlayout: handout\nlayout: handbook\n---") == .handout)
        for value in ["unknown", "manual", ""] {
            #expect(ExportLayout.frontMatterLayout("---\nlayout: \(value)\nlayout: handbook\n---") == nil)
        }
    }
}
#endif
