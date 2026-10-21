#if os(macOS)
import Foundation
import Testing
@testable import MarsDawnExport

/// Margins per layout (S1 of mars-dawn#432). The corpus measures them on printed pages; these
/// pin the numbers and the width the exporter lays the page out at.
struct ExportLayoutTests {
    @Test func documentKeepsTheMarginsExportHasAlwaysHad() {
        let margins = ExportLayout.document.pageMargins
        #expect(margins.top == 51 && margins.bottom == 51)
        #expect(margins.left == 45 && margins.right == 45)
        #expect(ExportLayout.document.printableWidth(paperWidth: 595) == 505)
    }

    @Test func manualIs20mmWithA25mmBindingSideOnTheLeft() {
        let margins = ExportLayout.manual.pageMargins
        #expect(abs(margins.top - 56.693) < 0.001 && abs(margins.bottom - 56.693) < 0.001)
        #expect(abs(margins.left - 70.866) < 0.001)
        #expect(abs(margins.right - 56.693) < 0.001)
    }

    /// The exporter lays out at the paper width minus both side margins, so the column the
    /// blocks are measured in is the column that prints.
    @Test func printableWidthFollowsTheLayout() {
        #expect(abs(ExportLayout.manual.printableWidth(paperWidth: 595) - 467.441) < 0.001)
        #expect(abs(ExportLayout.manual.printableWidth(paperWidth: 612) - 484.441) < 0.001)
        #expect(ExportLayout.manual.printableWidth(paperWidth: 595) < ExportLayout.document.printableWidth(paperWidth: 595))
    }

    /// The handout (S3): the document layout's margins plus a notes column on the right, so the
    /// body is about two thirds of the width between the outer margins.
    @Test func handoutIsTheDocumentMarginsPlusANotesColumn() {
        // It prints at the document's margins, so a wide table can reach into the column (A1-R2).
        #expect(NSEdgeInsetsEqual(ExportLayout.handout.pageMargins, ExportLayout.document.pageMargins))
        let margins = ExportLayout.handout.bodyMargins
        #expect(margins.top == 51 && margins.bottom == 51 && margins.left == 45)
        #expect(margins.right == 45 + ExportLayout.notesColumnWidth)
        #expect(NSEdgeInsetsEqual(ExportLayout.document.bodyMargins, ExportLayout.document.pageMargins))
        for paper in [CGFloat(595), 612] {
            let ratio = (paper - margins.left - margins.right) / (paper - 90)
            #expect(ratio > 0.64 && ratio < 0.69, "\(paper): body is \(ratio) of the width")
        }
    }

    @Test func layoutNamesAreTheCLIValues() {
        #expect(ExportLayout.allCases.map(\.rawValue) == ["document", "manual", "handout"])
    }
}
#endif
