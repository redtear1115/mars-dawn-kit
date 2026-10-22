import Foundation
import Testing
@testable import MarsDawnKit

/// A footnote reference is a private-use placeholder (U+E002 ... U+E003) with a per-render
/// nonce, expanded only in text. Anywhere the renderer takes the plain text of inline content
/// instead of rendering it, the placeholder would reach the page as it is, and two renders of
/// one document would differ. These tests hold the two ways it did: a callout or spoiler title
/// (`Callouts.parse` checked only math's pair) and an image's alt text (`image.plainText`).
struct FootnotePlaceholderLeakTests {
    private func render(_ markdown: String) -> String { MarkdownRenderer.render(markdown) }

    private func privateUse(_ text: String) -> [String] {
        text.unicodeScalars.filter { (0xE000...0xF8FF).contains($0.value) }.map { "U+" + String($0.value, radix: 16, uppercase: true) }
    }

    private let backlink = ##"<a href="#fnref:1" class="footnote-backref" aria-label="Back to reference 1">\##u{21A9}</a>"##

    // MARK: Exact output

    @Test func aCalloutTitleWithAReferenceIsNotATitle() {
        #expect(render(":::info Title[^1]\nbody\n:::\n\n[^1]: note\n") == """
        <p data-line="1">:::info Title<sup class="footnote-ref"><a href="#fn:1" id="fnref:1">1</a></sup>
        body
        :::</p>
        <section class="footnotes">
        <ol>
        <li id="fn:1"><p>note \(backlink)</p>
        </li>
        </ol>
        </section>

        """)
    }

    @Test func aSpoilerSummaryWithAReferenceIsNotASummary() {
        #expect(render(":::spoiler Hid[^1]\nsecret\n:::\n\n[^1]: note\n") == """
        <p data-line="1">:::spoiler Hid<sup class="footnote-ref"><a href="#fn:1" id="fnref:1">1</a></sup>
        secret
        :::</p>
        <section class="footnotes">
        <ol>
        <li id="fn:1"><p>note \(backlink)</p>
        </li>
        </ol>
        </section>

        """)
    }

    /// A reference in an image's description is not a reference: `alt` has no markup to hold one.
    /// It stays as written, the way math in an alt does (`MathExtractor` hands it back as source).
    @Test func anAltKeepsTheReferenceAsWritten() {
        #expect(render("![a[^1]](x.png)\n\n![b $x$](y.png)\n\n[^1]: note\n") == """
        <p data-line="1"><img src="x.png" alt="a[^1]"></p>
        <p data-line="3"><img src="y.png" alt="b $x$"></p>
        <section class="footnotes">
        <ul class="footnotes-unreferenced">
        <li><p>note</p>
        </li>
        </ul>
        </section>

        """)
    }

    /// A note named only from an alt is listed like any definition nothing refers to: not
    /// numbered, no backlink to an anchor that was never written.
    @Test func aNoteNamedOnlyFromAnAltIsUnreferenced() {
        let extraction = FootnoteExtractor.extract(from: "![a[^1]](x.png)\n\n[^1]: note\n")
        #expect(extraction.references.isEmpty)
        #expect(extraction.notes.isEmpty)
        #expect(extraction.unreferenced == ["note"])
        #expect(extraction.markdown == "![a[^1]](x.png)\n\n\n")
    }

    /// Named from the text as well, the note is numbered by that reference alone: one backlink,
    /// and the alt does not take a number or an `id` of its own.
    @Test func aReferenceInTheTextStillNumbersTheNoteOnceAnAltNamesItToo() {
        #expect(render("![a[^1]](x.png) then[^1]\n\n[^1]: note\n") == """
        <p data-line="1"><img src="x.png" alt="a[^1]"> then<sup class="footnote-ref"><a href="#fn:1" id="fnref:1">1</a></sup></p>
        <section class="footnotes">
        <ol>
        <li id="fn:1"><p>note \(backlink)</p>
        </li>
        </ol>
        </section>

        """)
    }

    /// An alt in front of a text reference must not take its number: the numbers follow the
    /// references the page has.
    @Test func anAltDoesNotTakeANumberFromTheTextReferences() {
        let html = render("![a[^x]](x.png) first[^y] second[^x]\n\n[^x]: X.\n\n[^y]: Y.\n")
        #expect(html.contains(##"first<sup class="footnote-ref"><a href="#fn:1" id="fnref:1">1</a></sup>"##), "\(html)")
        #expect(html.contains(##"second<sup class="footnote-ref"><a href="#fn:2" id="fnref:2">2</a></sup>"##), "\(html)")
        #expect(html.contains(#"alt="a[^x]""#), "\(html)")
    }

    @Test func aReferenceInALinkTitleOrAnImageTitleIsText() {
        #expect(render("[l](http://example.com \"t[^1]\") ![i](x.png \"u[^1]\")\n\n[^1]: note\n").hasPrefix(
            #"<p data-line="1"><a href="http://example.com" title="t[^1]">l</a> <img src="x.png" alt="i" title="u[^1]"></p>"# + "\n"))
    }

    // MARK: Controls: what must keep working

    @Test func aTitleWithoutAReferenceIsStillATitle() {
        let html = render(":::info Title\nbody\n:::\n\n:::spoiler Hid\nsecret\n:::\n")
        #expect(html.contains(#"<p class="callout-title callout-title-author">Title</p>"#), "\(html)")
        #expect(html.contains("<summary>Hid</summary>"), "\(html)")
    }

    @Test func aReferenceInACalloutBodyStillWorks() {
        let html = render(":::info Title\nbody[^1]\n:::\n\n[^1]: note\n")
        #expect(html.contains(#"<p class="callout-title callout-title-author">Title</p>"#), "\(html)")
        #expect(html.contains(##"body<sup class="footnote-ref"><a href="#fn:1" id="fnref:1">1</a></sup>"##), "\(html)")
    }

    @Test func aReferenceInALinkTextStillWorks() {
        #expect(render("[text[^1]](http://example.com)\n\n[^1]: note\n").hasPrefix(
            ##"<p data-line="1"><a href="http://example.com">text<sup class="footnote-ref"><a href="#fn:1" id="fnref:1">1</a></sup></a></p>"## + "\n"))
    }

    // MARK: Nothing private-use, every render the same

    /// A reference (and math) in every place the renderer reads plain text from, or could.
    private static let everywhere = """
    ---
    title: FM title[^1] $q$
    author: Ann[^1]
    ---

    [TOC]

    # Head[^1] and $h$

    ## Img ![in[^1] $w$](h.png) head

    Link [text[^1]](http://example.com "ti[^1]tle $t$") and ![alt[^1] $a$](x.png "ti[^1]tle $t$") and sized ![s[^1]](x.png =10x10).

    | col[^1] | $c$ |
    |---|---|
    | cell[^1] | $d$ |

    <details>
    <summary>Sum[^1] $s$</summary>

    inner[^1]

    </details>

    :::info Title[^1]
    body
    :::

    :::danger Math $m$ and[^1]
    body
    :::

    :::spoiler Hid[^1]
    secret
    :::

    > :::warning Quoted[^1]
    > body
    > :::

    > [!NOTE]
    > alert body[^1]

    > [!TIP][^1]
    > x

    {%youtube [a[^1]](https://x.example/y) %}

    {%youtube dQw4w9WgXcQ[^1] %}

    ~sub[^1]~ and ==mark[^1]== and `code[^1]`

    Only in alt: ![only[^2]](z.png)

    A note with an alt: [^3]

    [^1]: note $n$ ![n[^2]](n.png)

    [^2]: only from an alt

    [^3]: ![deep[^1]](d.png)

    """

    @Test func noPrivateUseScalarReachesTheOutput() {
        #expect(privateUse(Self.everywhere).isEmpty, "the input must have none of its own")
        let html = render(Self.everywhere)
        #expect(privateUse(html).isEmpty, "\(privateUse(html)) in \(html)")
    }

    @Test(arguments: [
        ":::info Title[^1]\nbody\n:::\n\n[^1]: note\n",
        ":::spoiler Hid[^1]\nsecret\n:::\n\n[^1]: note\n",
        "![a[^1]](x.png)\n\n[^1]: note\n",
        "## ![a[^1]](x.png) t\n\n[^1]: note\n",
        "[TOC]\n\n## ![a[^1]](x.png) t\n\n[^1]: note\n",
        "- :::info T[^1]\n  body\n  :::\n\n[^1]: note\n",
    ])
    func eachSpotOnItsOwnHasNoPrivateUseScalar(markdown: String) {
        let html = render(markdown)
        #expect(privateUse(html).isEmpty, "\(markdown.debugDescription) -> \(html)")
    }

    @Test func twoRendersAreByteIdentical() {
        // The nonce is drawn afresh on every render, so any of it in the output shows here.
        let first = render(Self.everywhere)
        for _ in 0..<5 { #expect(render(Self.everywhere) == first) }
        for markdown in [":::info T[^1]\nb\n:::\n\n[^1]: n\n", ":::spoiler S[^1]\nb\n:::\n\n[^1]: n\n", "![a[^1]](x.png)\n\n[^1]: n\n"] {
            let one = render(markdown)
            for _ in 0..<5 { #expect(render(markdown) == one, "\(markdown.debugDescription)") }
        }
    }

    /// Every backlink in the notes goes to an `id` in the page, and no `id` is written twice.
    @Test func everyBacklinkHasItsAnchor() {
        let html = render(Self.everywhere)
        let ids = html.matches(of: /\sid="([^"]*)"/).map { String($0.output.1) }
        #expect(Set(ids).count == ids.count, "an id is written twice: \(ids)")
        let backlinks = html.matches(of: /class="footnote-backref"/).count
        let references = html.matches(of: /class="footnote-ref"/).count
        #expect(backlinks == references, "\(backlinks) backlinks for \(references) references")
        for target in html.matches(of: /href="#(fnref:[^"]*)"/).map({ String($0.output.1) }) {
            #expect(ids.contains(target), "\(target)")
        }
    }

    /// A heading's `id` comes from its text, the alt included; it is the same on every render.
    @Test func aHeadingWithAReferenceInAnAltKeepsOneId() {
        let markdown = "## ![a[^1]](x.png) t\n\n[^1]: note\n"
        let html = render(markdown)
        #expect(html.contains(#"<h2 id="a1-t" data-line="1"><img src="x.png" alt="a[^1]"> t</h2>"#), "\(html)")
    }
}
