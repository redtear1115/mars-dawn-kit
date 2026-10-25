import Foundation
import Testing
@testable import MarsDawnKit

/// A footnote reference placeholder (U+E002 ... U+E003 with a per-render nonce) must never reach
/// the page (kit #159). The reported shape: cmark-gfm gave a reference on the line after a code
/// span a column six bytes too far right (on every line after a paragraph's first, a node's column
/// is its offset in the line's text added to the column the paragraph starts at, not where it is),
/// the extractor wrote its placeholder over the code span's closing backticks, and the
/// placeholder ended up inside `<code>`.
struct FootnoteCodeSpanTests {
    private func render(_ markdown: String) -> String { MarkdownRenderer.render(markdown) }

    private func privateUse(_ text: String) -> [String] {
        text.unicodeScalars.filter { (0xE000...0xF8FF).contains($0.value) }.map { "U+" + String($0.value, radix: 16, uppercase: true) }
    }

    private func ref(_ number: Int, _ occurrence: Int = 1) -> String {
        let id = occurrence == 1 ? "fnref:\(number)" : "fnref:\(number):\(occurrence)"
        return ##"<sup class="footnote-ref"><a href="#fn:\##(number)" id="\##(id)">\##(number)</a></sup>"##
    }

    /// The reproduction from the issue.
    private static let issue = "[^1]: `c`&#33; |`c```\")_[x](u (```\n![e](f =x4)[^1]    ```\n"

    @Test func theIssueShapeKeepsItsCodeAndHasNoPlaceholder() {
        let html = render(Self.issue)
        #expect(privateUse(html).isEmpty, "\(privateUse(html)) in \(html)")
        #expect(html == """
        <section class="footnotes">
        <ol>
        <li id="fn:1"><p><code>c</code>! |`c<code>")_[x](u (</code>
        <img src="f" alt="e" height="4">\(ref(1))    ``` <a href="#fnref:1" class="footnote-backref" aria-label="Back to reference 1">\u{21A9}</a></p>
        </li>
        </ol>
        </section>

        """)
    }

    @Test func theIssueShapeIsTheSameOnEveryRender() {
        let first = render(Self.issue)
        for _ in 0..<10 { #expect(render(Self.issue) == first) }
    }

    /// The placeholder goes over the `[^1]` and nothing else: the closing backticks stay.
    @Test func thePlaceholderReplacesTheReferenceAlone() {
        let extraction = FootnoteExtractor.extract(from: Self.issue)
        #expect(extraction.references.count == 1)
        #expect(extraction.markdown == "\n\n")
        let placeholder = String(decoding: FootnoteExtractor.placeholder(index: 0, nonce: extraction.nonce), as: UTF8.self)
        #expect(extraction.notes.map(\.markdown) == ["`c`&#33; |`c```\")_[x](u (```\n![e](f =x4)\(placeholder)    ```"])
    }

    // MARK: A reference on a later line of its paragraph

    /// Indented continuation lines, as a paragraph, a list item, a block quote and a definition
    /// have them: each reference is found where the line has it.
    @Test(arguments: [
        "a\n    b [^1] c\n\n[^1]: n\n",
        "a\n   b [^1] c\n\n[^1]: n\n",
        "a\n\tb [^1] c\n\n[^1]: n\n",
        "a  \nb [^1] c\n\n[^1]: n\n",
        "- a\n  b [^1] c\n\n[^1]: n\n",
        "> a\n> b [^1] c\n\n[^1]: n\n",
        "> a\n>   b [^1] c\n\n[^1]: n\n",
    ])
    func aReferenceOnAContinuationLineIsLinkedWhereItStands(markdown: String) {
        let html = render(markdown)
        #expect(html.contains("b \(ref(1)) c"), "\(markdown.debugDescription) -> \(html)")
        #expect(html.contains("<li id=\"fn:1\">"), "\(html)")
    }

    @Test func aReferenceOnTheLineAfterACodeSpanInADefinitionIsLinked() {
        let html = render("Text[^1] and[^2]\n\n[^1]: a `code` span\n    then [^2] here\n\n[^2]: two\n")
        #expect(html.contains("then \(ref(2, 2)) here"), "\(html)")
        #expect(privateUse(html).isEmpty, "\(html)")
    }

    /// cmark-gfm gives the text after a backslash line break the line it had before it, so such a
    /// reference cannot be found: it stays as written, and the note is listed as one nothing
    /// refers to, with no backlink to an anchor that was never written.
    @Test func aReferenceAfterABackslashBreakStaysTextAndLeavesNoDanglingBacklink() {
        let html = render("a\\\nb [^1] c\n\n[^1]: n\n")
        #expect(html.contains("b [^1] c"), "\(html)")
        #expect(!html.contains("footnote-backref"), "\(html)")
        #expect(html.contains("footnotes-unreferenced"), "\(html)")
    }

    // MARK: What must keep working

    @Test func aCodeSpanThatCrossesLinesKeepsItsReferenceAsWritten() {
        for markdown in ["[^1]: `a [^1] b`\n", "[^1]: `a\n    [^1] b`\n", "[^1]: x `a\n    b [^1]` c\n"] {
            let html = render(markdown)
            #expect(privateUse(html).isEmpty, "\(markdown.debugDescription) -> \(html)")
            #expect(html.contains("[^1]"), "\(markdown.debugDescription) -> \(html)")
        }
    }

    // MARK: Nothing of a placeholder reaches the page

    /// Found by a random search over fragments of footnote, code, table and image syntax: each
    /// left U+E002 ... U+E003 and the nonce in the page, and differed on every render.
    private static let found = [
        "[^1]: [^2]: \n    )&#33; |``[^2]~~",
        "[^1]: [^2]: \n    _[^2]: )|---|---|",
        "[^2]: [^1]: \n    x&#33;[^1]: |---|---|\n    ",
        "- [^1]: \n    \n    [^1]~~  _)![e](f)x(|---|---||<b>",
        "- [^1]: (![e](f =x4)(\n\n    ~~&#33;[^1]: \tab",
        "[^1]: [^2]: - - \n    ([^2]: > ",
    ]

    @Test(arguments: found)
    func noPrivateUseScalarReachesThePage(markdown: String) {
        #expect(privateUse(markdown).isEmpty, "the input must have none of its own")
        let html = render(markdown)
        #expect(privateUse(html).isEmpty, "\(markdown.debugDescription) -> \(html)")
        for _ in 0..<5 { #expect(render(markdown) == html, "\(markdown.debugDescription)") }
    }

    /// A document cannot make the renderer fall back, or hide a leak, by writing placeholders:
    /// the nonce is drawn afresh on every render. Its own private-use scalars come through as text.
    @Test func aForgedPlaceholderChangesNothing() {
        let forged = "\u{E002}0:0123456789abcdef\u{E003}"
        let plain = render("Text[^1] here\n\n[^1]: note\n")
        let withForged = render("Text[^1] here \(forged)\n\n[^1]: note\n")
        #expect(withForged.contains(##"Text<sup class="footnote-ref"><a href="#fn:1" id="fnref:1">1</a></sup> here \##(forged)"##), "\(withForged.debugDescription)")
        #expect(plain.contains("<li id=\"fn:1\">") && withForged.contains("<li id=\"fn:1\">"), "the notes are still a list of numbered notes")
        #expect(withForged.matches(of: /class="footnote-ref"/).count == 1)
    }

    /// A document that does not leak is not re-rendered as source: its footnotes are the same as ever.
    @Test func aDocumentWithoutALeakKeepsItsFootnotes() {
        let html = render("A[^1] and B[^2]\n\n[^1]: one\n\n[^2]: two `code`\n")
        #expect(html.matches(of: /class="footnote-ref"/).count == 2, "\(html)")
        #expect(html.contains("<section class=\"footnotes\">\n<ol>"), "\(html)")
    }
}
