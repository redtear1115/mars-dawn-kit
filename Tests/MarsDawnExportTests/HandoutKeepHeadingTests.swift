#if os(macOS)
import AppKit
import Foundation
import PDFKit
import Testing
@testable import MarsDawnExport

/// mars-dawn#491: in the handout layout the heading "Status by area" stayed alone at the foot
/// of page 1 while its table, which the handout keeps whole once it is fitted past the body
/// (`span`), moved to page 2. The heading has to travel with the table. The document layout
/// lets the same table split by rows, so it never had the problem: it is the control.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(10)))
struct HandoutKeepHeadingTests {
    /// The 1.2.0 release gate's meeting notes (mars-dawn#489), rebuilt from its sample PDF.
    static let gateSample = """
    ---
    title: Weekly Product Sync
    date: 2026-10-27
    ---

    # Weekly Product Sync — 2026-10-27

    **Attendees:** Ray, Design, QA, Support
    **Agenda:** 1.2.0 release readiness, What's New review, handout printing test

    ## Decisions

    - Ship Mac 1.2.0 this week; submission after the release gate.
    - Keep the Handout layout as a paid feature like every other export.
    - Print this handout on A4 to check the note column and margins.

    ## Status by area

    | Area | Owner | Status | Risk | Next step |
    |---|---|---|---|---|
    | Formatting bar and Format menu | App | Done, verified on #476/#477 | Low | Smoke in the release gate |
    | Find in Preview (⌘F / ⌘G / ⌘E) | App | Done, verified on #477 | Low | Smoke in the release gate |
    | Export layouts (Document / Handbook / Handout) | Kit + App | Done, verified on #481 | Medium | A4 printout by the owner |
    | What's New, 10 locales | Copy | Approved en + zh-Hant | Low | Attach in App Store Connect |

    ## Action items

    1. Release gate: full test runs on both axes, real-app smoke
    2. Owner: print this page on A4 and mark the note column
    3. Version 1.2.0 (build 12) merged

    ## Notes

    The handout keeps a ==blank column== for notes.[^1]

    [^1]: Footnote.
    """

    /// The index of the first page whose text holds `marker`, or nil. Not `withoutFooter`:
    /// PDFKit can put a table row and the footer on one line.
    static func page(of marker: String, in texts: [String]) -> Int? {
        texts.firstIndex { $0.contains(marker) }
    }

    @Test(arguments: [ExportLayout.handout, .document], DocumentExporter.Paper.allCases)
    func theHeadingIsOnTheSamePageAsItsTable(_ layout: ExportLayout, _ paper: DocumentExporter.Paper) async throws {
        let run = try await HandoutLayoutTests.export(Self.gateSample, layout: layout, paper: paper)
        let heading = try #require(Self.page(of: "Status by area", in: run.texts), "\(layout) \(paper): no heading")
        let table = try #require(Self.page(of: "Formatting", in: run.texts), "\(layout) \(paper): no table")
        #expect(heading == table, "\(layout) \(paper): the heading is on page \(heading + 1), its table on page \(table + 1)")
        if layout == .handout {
            // The case the fix is for: the table is fitted past the body and kept whole.
            #expect(run.report?.tables.contains { $0.kind == .span && $0.text.contains("Formatting") } == true,
                    "\(paper): the status table is not a span table any more: \(run.report?.tables.map(\.kind) ?? [])")
        }
    }
}
#endif
