import Foundation
import Testing
@testable import MarsDawnKit

/// Footnotes (#44): `[^label]` references and `[^label]: text` definitions, rendered as numbered
/// references and a notes section, through the same renderer and the same safety rules as the
/// body, without moving any `data-line`.
struct FootnoteTests {
    private func render(_ markdown: String) -> String { MarkdownRenderer.render(markdown) }

    /// Everything before the notes section.
    private func body(_ html: String) -> String {
        html.components(separatedBy: "<section class=\"footnotes\">").first ?? html
    }

    private func section(_ html: String) -> String? {
        guard let range = html.range(of: "<section class=\"footnotes\">") else { return nil }
        return String(html[range.lowerBound...])
    }

    private func dataLines(_ html: String) -> [Int] {
        html.matches(of: /data-line="(\d+)"/).map { Int($0.output.1)! }
    }

    /// Every `id` and in-page `href` in `html`.
    private func anchors(_ html: String) -> [String] {
        html.matches(of: /(?:id="|href="#)([^"]*)"/).map { String($0.output.1) }
    }

    // MARK: Shape

    @Test func aReferenceAndItsNote() {
        let html = render("Text.[^a]\n\n[^a]: The note.\n")
        #expect(html == """
        <p data-line="1">Text.<sup class="footnote-ref"><a href="#fn:1" id="fnref:1">1</a></sup></p>
        <section class="footnotes">
        <ol>
        <li id="fn:1"><p>The note. <a href="#fnref:1" class="footnote-backref" aria-label="Back to reference 1">\u{21A9}</a></p>
        </li>
        </ol>
        </section>

        """)
    }

    @Test func numbersFollowFirstUseAndARepeatGetsItsOwnBacklink() {
        let html = render("B[^b] A[^a] B again[^b]\n\n[^a]: Note A.\n\n[^b]: Note B.\n")
        #expect(body(html).contains(##"<a href="#fn:1" id="fnref:1">1</a>"##), "b is referenced first")
        #expect(body(html).contains(##"<a href="#fn:2" id="fnref:2">2</a>"##))
        #expect(body(html).contains(##"<a href="#fn:1" id="fnref:1:2">1</a>"##), "the repeat")
        let notes = section(html) ?? ""
        #expect(notes.contains(##"<li id="fn:1"><p>Note B."##) && notes.contains(##"<li id="fn:2"><p>Note A."##))
        #expect(notes.contains(##"href="#fnref:1:2""##), "one backlink per reference")
    }

    @Test func anUndefinedReferenceStaysText() {
        let html = render("Missing[^nope] here.\n\nKnown[^k].\n\n[^k]: Yes.\n")
        #expect(body(html).contains("Missing[^nope] here."))
        #expect(body(html).components(separatedBy: "footnote-ref").count == 2, "one real reference")
    }

    @Test func referencesInCodeAreNotReferences() {
        let html = render("`[^a]` and\n\n```\n[^a]\n```\n\nReal[^a].\n\n[^a]: Note.\n")
        #expect(body(html).contains("<code>[^a]</code>"))
        #expect(body(html).contains("<code>[^a]\n</code>"))
        #expect(body(html).components(separatedBy: "footnote-ref").count == 2)
    }

    /// Before #44 a definition whose text is one URL was a link reference definition: it
    /// vanished, and the reference became a link reading "^word".
    @Test func aURLOnlyDefinitionIsANoteNotALink() {
        let html = render("See[^word].\n\n[^word]: https://example.com\n")
        #expect(!body(html).contains("example.com"), "\(html)")
        #expect(body(html).contains("footnote-ref"))
        #expect(section(html)?.contains("https://example.com") == true)
    }

    @Test func aMultiParagraphNote() {
        let html = render("X[^m]\n\n[^m]: First.\n\n    Second.\n")
        let notes = section(html) ?? ""
        #expect(notes.contains("<p>First.</p>") && notes.contains("<p>Second. <a href=\"#fnref:1\""), "\(notes)")
        #expect(!html.contains("<pre"), "the indented paragraph is not code")
    }

    @Test func notesInAQuoteOrAListLeaveNoEmptyBlock() {
        let html = render("Q[^q] L[^l]\n\n> [^q]: Quoted.\n\n- [^l]: Listed.\n")
        #expect(!body(html).contains("<blockquote"), "\(html)")
        #expect(!body(html).contains("<ul"), "\(html)")
        #expect(section(html)?.contains("Quoted.") == true && section(html)?.contains("Listed.") == true)
    }

    @Test func aDefinitionNothingRefersToIsListedUnnumbered() {
        let html = render("Used[^u].\n\n[^u]: Used note.\n\n[^x]: Orphan note.\n")
        let notes = section(html) ?? ""
        #expect(notes.contains(##"<ul class="footnotes-unreferenced">"##))
        #expect(notes.contains("<li><p>Orphan note.</p>"), "\(notes)")
        #expect(!notes.contains("fn:2"), "unnumbered, no id")
        // With no reference at all, the notes are still listed.
        #expect(section(render("[^x]: Only an orphan.\n"))?.contains("Only an orphan.") == true)
    }

    /// Math follows the kit's rule that Markdown wins (MathExtractor): with no definition,
    /// `$[^1]$` is TeX; with one, `[^1]` is a footnote reference, as it was a link before #44
    /// (`[^1]: Note.` was a link reference definition then).
    @Test func mathAndFootnotesFollowMarkdownFirst() {
        #expect(render("Math $[^1]$ here.\n").contains(##"<span class="math-inline">[^1]</span>"##))
        let withDefinition = render("Math $[^1]$ here.\n\n[^1]: Note.\n")
        #expect(withDefinition.contains("footnote-ref"), "\(withDefinition)")
        #expect(!withDefinition.contains("math-inline"))
        // Math elsewhere in the same document is untouched.
        #expect(render("$x^2$ and a note[^1].\n\n[^1]: With $y$.\n").components(separatedBy: "math-inline").count == 3)
    }

    // MARK: Ids and user text

    /// No label is ever written into an `id` or `href`; a label that is a heading's slug, or
    /// raw HTML, can't make one.
    @Test func idsAreNumbersOnly() {
        let html = render("# fn\n\nA[^fn] B[^<b>x</b>] C[^fnref:1]\n\n[^fn]: One.\n\n[^<b>x</b>]: Two.\n\n[^fnref:1]: Three.\n")
        for anchor in anchors(html) where anchor != "fn" {
            #expect(anchor.wholeMatch(of: /fn(ref)?:\d+(:\d+)?/) != nil, "\(anchor)")
        }
        #expect(html.contains(##"<h1 id="fn""##), "the heading keeps its slug")
        #expect(!html.contains("<b>x</b>"), "the label's HTML never reaches the page")
    }

    /// A heading's `id` is what it was before footnotes existed, and the same on every render.
    @Test func aHeadingWithAReferenceKeepsItsID() {
        let source = "# Title[^1]\n\n[^1]: Note.\n"
        let first = render(source), second = render(source)
        #expect(first.contains(##"<h1 id="title1""##), "\(first)")
        #expect(first == second)
    }

    /// Something that looks like a placeholder, typed into the document, is text.
    @Test func aTypedPlaceholderLookAlikeIsText() {
        let lookAlike = "\u{E002}0:0000000000000000\u{E003}"
        let html = render("Typed \(lookAlike) and real[^a].\n\n[^a]: Note.\n")
        #expect(html.contains(lookAlike))
        #expect(body(html).components(separatedBy: "footnote-ref").count == 2)
    }

    /// A note is rendered exactly as the same Markdown in the body: the same escaping and raw
    /// HTML rules, minus `data-line`.
    @Test(arguments: [
        "<script>alert(1)</script>",
        "<link rel=\"stylesheet\" href=\"x.css\"> text",
        "inline <link rel=\"stylesheet\" href=\"x.css\"> in a sentence",
        "[x](javascript:alert(1)) and <a href=\"javascript:alert(1)\">y</a>",
        "![i](file:///etc/passwd) & \"q\" <b>bold</b>",
    ])
    func aNoteGoesThroughTheBodysSafetyRules(_ text: String) {
        let html = render("X[^a]\n\n[^a]: \(text)\n")
        let alone = render(text).replacing(try! Regex(#" data-line="\d+""#), with: "")
        let noteRange = try! #require(html.range(of: "<li id=\"fn:1\">"))
        var note = String(html[noteRange.upperBound...])
        note = String(note[..<note.range(of: " <a href=\"#fnref:1\"")!.lowerBound])
        #expect(alone.hasPrefix(note), "note: \(note)\nbody: \(alone)")
    }

    // MARK: Lines

    @Test func bodyLinesAreUnchanged() {
        let source = """
        # Top[^1]

        Para[^2]
        [^1]: One,
            continued.

        [^2]: Two.

        ## After

        - item
        """
        let html = render(source)
        #expect(dataLines(body(html)) == [1, 3, 9, 11, 11], "\(html)")
        #expect(section(html).map(dataLines) == [], "the notes carry no data-line")
    }

    @Test func aDocumentWithoutFootnotesIsUntouched() {
        let source = "# A\n\n[x]: https://x\n\n[x] and [^] and [^ ] and ^1\n"
        var generator = SystemRandomNumberGenerator()
        let extraction = FootnoteExtractor.extract(from: source, using: &generator)
        #expect(extraction.markdown == source && extraction.isEmpty)
        #expect(!render(source).contains("footnotes"))
    }

    // MARK: Limits

    @Test func manyReferencesAndManyNotesStayQuick() {
        let manyReferences = "Many" + String(repeating: "[^1]", count: 10_000) + "\n\n[^1]: One note.\n"
        let manyNotes = (0..<10_000).map { "R[^n\($0)]" }.joined(separator: " ") + "\n\n"
            + (0..<10_000).map { "[^n\($0)]: note \($0)" }.joined(separator: "\n\n") + "\n"
        for source in [manyReferences, manyNotes] {
            let start = Date()
            let result = MarkdownRenderer.renderResult(source)
            #expect(Date().timeIntervalSince(start) < 10)
            #expect(result.fallback == nil)
            #expect(result.html.components(separatedBy: "footnote-ref").count == 10_001)
        }
    }

    // MARK: Statistics

    @Test func statisticsCountNotesOnceAndNotTheMarkers() {
        let with = TextStatistics(markdownBody: "Word[^1] two.\n\n[^1]: Note text.\n")
        let plain = TextStatistics(markdownBody: "Word two.\n\nNote text.\n")
        #expect(with.words == plain.words && with.characters == plain.characters)
        #expect(with.words == 4)
    }
}
