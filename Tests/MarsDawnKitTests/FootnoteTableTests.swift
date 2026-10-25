import Foundation
import Testing
@testable import MarsDawnKit

/// A footnote reference in the paragraph above a table (kit #161). cmark-gfm's table extension
/// takes the last line of a paragraph as the table's header row and leaves the rest as a paragraph
/// with no source positions, so the extractor has to find such a reference in the source itself.
struct FootnoteTableTests {
    private func render(_ markdown: String) -> String { MarkdownRenderer.render(markdown) }

    private let table = "| a | b |\n|---|---|\n| c | d |\n"
    private func ref(_ number: Int, repeatNumber: Int = 1) -> String {
        let id = repeatNumber == 1 ? "fnref:\(number)" : "fnref:\(number):\(repeatNumber)"
        return ##"<sup class="footnote-ref"><a href="#fn:\##(number)" id="\##(id)">\##(number)</a></sup>"##
    }
    private func back(_ number: Int, repeatNumber: Int = 1) -> String {
        let id = repeatNumber == 1 ? "fnref:\(number)" : "fnref:\(number):\(repeatNumber)"
        let mark = repeatNumber == 1 ? "\u{21A9}" : "\u{21A9}<sup>\(repeatNumber)</sup>"
        return ##"<a href="#\##(id)" class="footnote-backref" aria-label="Back to reference \##(number)">\##(mark)</a>"##
    }
    private let tableHTML = """
    <table data-line="2">
    <thead>
    <tr data-line="2"><th>a</th><th>b</th></tr>
    </thead>
    <tbody>
    <tr data-line="4"><td>c</td><td>d</td></tr>
    </tbody>
    </table>
    """

    /// The shape of the issue.
    @Test func aReferenceInTheParagraphAboveATableIsLinked() {
        let html = render("x [^1]\n\(table)\n[^1]: note\n")
        // The table's own data-line values are cmark's, not this feature's: only what footnotes write is held here.
        #expect(html.hasPrefix("<p>x \(ref(1))</p>\n<table"), "\(html)")
        #expect(html.hasSuffix("""
        </table>
        <section class="footnotes">
        <ol>
        <li id="fn:1"><p>note \(back(1))</p>
        </li>
        </ol>
        </section>

        """), "\(html)")
    }

    @Test(arguments: ["\r\n", "\r"])
    func theSameWithCRLFAndCRLineEndings(ending: String) {
        for markdown in ["x [^1]\n\(table)\n[^1]: note\n",
                         "a\n  b [^1] c [^2]\n   d [^1]\n\(table)\n[^1]: one\n\n[^2]: two\n",
                         "> x [^1]\n> y [^1]\n> | a | b |\n> |---|---|\n\n[^1]: note\n"] {
            let expected = render(markdown)
            #expect(expected.contains(ref(1)), "\(expected)")
            let converted = render(markdown.replacingOccurrences(of: "\n", with: ending))
            #expect(converted == expected, "\(converted.debugDescription)")
        }
    }

    /// References on several lines of that paragraph, each numbered, the text around them kept.
    @Test func referencesOnEveryLineOfAMultiLineParagraph() {
        let html = render("a\n  b [^1] c [^2]\n   d `[^1]` [^1]\n\(table)\n[^1]: one\n\n[^2]: two\n")
        #expect(html.hasPrefix("<p>a\nb \(ref(1)) c \(ref(2))\nd <code>[^1]</code> \(ref(1, repeatNumber: 2))</p>\n"), "\(html)")
        #expect(html.contains("<li id=\"fn:1\"><p>one \(back(1)) \(back(1, repeatNumber: 2))</p>"), "\(html)")
        #expect(html.contains("<li id=\"fn:2\"><p>two \(back(2))</p>"), "\(html)")
    }

    @Test func numberedLikeAnyOther() {
        let html = render("first[^b]\n\nx [^a]\n\(table)\nlast[^b]\n\n[^a]: A\n\n[^b]: B\n")
        #expect(html.contains("first\(ref(1))"), "\(html)")
        #expect(html.contains("x \(ref(2))"), "\(html)")
        #expect(html.contains("last\(ref(1, repeatNumber: 2))"), "\(html)")
    }

    @Test func insideABlockQuote() {
        let html = render("> x [^1]\n> y [^1]\n> \(table.replacingOccurrences(of: "\n|", with: "\n> |"))\n[^1]: note\n")
        #expect(html.contains("<p>x \(ref(1))\ny \(ref(1, repeatNumber: 2))</p>"), "\(html)")
        #expect(html.contains("<th>a</th>"), "\(html)")
    }

    @Test func insideAListItem() {
        let html = render("- item\n\n  x [^1]\n  | a | b |\n  |---|---|\n\n[^1]: note\n")
        #expect(html.contains("<p>x \(ref(1))</p>"), "\(html)")
        #expect(!html.contains("footnotes-unreferenced"), "\(html)")
    }

    /// A reference in the table itself is read from cmark's own positions, before or after.
    @Test func aReferenceInTheTableBodyStillWorks() {
        let html = render("x [^1]\n| a | b |\n|---|---|\n| c[^1] | d |\n\n[^1]: note\n")
        #expect(html.contains("<p>x \(ref(1))</p>"), "\(html)")
        #expect(html.contains("<td>c\(ref(1, repeatNumber: 2))</td>"), "\(html)")
    }

    // MARK: Nothing misplaced

    /// cmark places a header cell's reference by the paragraph above the table, with a column far
    /// into the table row. The extractor must not take it for text in a line of the paragraph.
    @Test func aHeaderCellReferenceNeverEditsTheParagraphAbove() {
        let line = "A first line long enough that a header cell column falls inside it, with a [^1] mention in it too."
        let html = render("\(line)\n| a[^1] | b |\n|---|---|\n\n[^1]: note\n")
        #expect(html.hasPrefix("<p>A first line long enough that a header cell column falls inside it, with a \(ref(1)) mention in it too.</p>"), "\(html)")
        #expect(html.contains("<th>a[^1]</th>"), "a header-cell reference stays text: \(html)")
    }

    @Test func aHeaderCellReferenceWithoutAParagraphAboveStillWorks() {
        let html = render("| a[^1] | b |\n|---|---|\n\n[^1]: note\n")
        #expect(html.contains("<th>a\(ref(1))</th>"), "\(html)")
    }

    /// A line of the paragraph is never rewritten where cmark's column points at something else.
    @Test func codeAndTextAroundAReferenceAreKept() {
        let html = render("`[^1]` and \\[^1] and [^1]\n\(table)\n[^1]: note\n")
        #expect(html.contains("<p><code>[^1]</code> and [^1] and \(ref(1))</p>"), "\(html)")
    }

    @Test func noPrivateUseScalarReachesTheOutput() {
        for markdown in ["x [^1]\n\(table)\n[^1]: n\n", "a\nb [^1] c\n\(table)\n[^1]: n\n", "> a\n> b [^1]\n> | h |\n> |---|\n\n[^1]: n\n"] {
            let html = render(markdown)
            #expect(!html.unicodeScalars.contains { (0xE000...0xF8FF).contains($0.value) }, "\(html)")
            #expect(html == render(markdown), "same on every render")
        }
    }

    /// Forged placeholders in a document are never references: only this render's nonce counts.
    @Test func aForgedPlaceholderAboveATableIsNotAReference() {
        let forged = "\u{E002}0:0000000000000000\u{E003}"
        let html = render("x [^1] \(forged)\n\(table)\n[^1]: note\n")
        #expect(html.contains("x \(ref(1)) \(forged)"), "\(html.debugDescription)")
        #expect(html.matches(of: /class="footnote-ref"/).count == 1, "\(html.debugDescription)")
    }
}
