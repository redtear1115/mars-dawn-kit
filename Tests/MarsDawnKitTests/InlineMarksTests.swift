import Testing
@testable import MarsDawnKit

/// HackMD's `==mark==`, `^sup^` and `~sub~` (#133), with `~~del~~` unchanged.
struct InlineMarksTests {
    /// The body of the only paragraph `markdown` renders to.
    private func inline(_ markdown: String) -> String {
        let html = MarkdownRenderer.render(markdown)
        guard let start = html.range(of: #">"#, range: html.range(of: "<p ")!.lowerBound..<html.endIndex),
              let end = html.range(of: "</p>", options: .backwards)
        else { return html }
        return String(html[start.upperBound..<end.lowerBound])
    }

    @Test(arguments: [
        ("==marked==", "<mark>marked</mark>"),
        ("a ==two words== b", "a <mark>two words</mark> b"),
        ("x^2^", "x<sup>2</sup>"),
        ("H~2~O", "H<sub>2</sub>O"),
        ("~~strike~~", "<del>strike</del>"),
        ("~~a~~ ~b~", "<del>a</del> <sub>b</sub>"),
        // Whitespace inside: not a subscript, so the single-tilde strikethrough GFM gives it.
        ("~a b~", "<del>a b</del>"),
        ("This ~is struck~ text", "This <del>is struck</del> text"),
        ("~a\u{3000}b~", "<del>a\u{3000}b</del>"),
        ("~a **b** c~", "<del>a <strong>b</strong> c</del>"),
        ("e=mc^2^ and H~2~O", "e=mc<sup>2</sup> and H<sub>2</sub>O"),
    ])
    func theThreeMarks(markdown: String, html: String) {
        #expect(inline(markdown) == html)
    }

    @Test(arguments: [
        "a ~ b ~ c",
        "a == b == c",
        "x ^ y ^ z",
        "==unmatched",
        "unmatched==",
        "^unmatched",
        "~unmatched",
        "a=b and c==d",
        "====",
        "===x===",
        "^^x^^",
        "^has space^",
        "^ x^",
        "== x==",
        "==x ==",
        "[^1][^2]",
        "~/a and ~/b",
    ])
    func unmatchedOrSpacedDelimitersStayLiteral(markdown: String) {
        let html = inline(markdown)
        #expect(!html.contains("<mark>") && !html.contains("<sup>") && !html.contains("<sub>") && !html.contains("<del>"))
        #expect(html == markdown.replacing("&", with: "&amp;"))
    }

    @Test(arguments: [
        (#"\==not marked=="#, "==not marked=="),
        (#"==not marked\=="#, "==not marked=="),
        (#"\^x\^"#, "^x^"),
        (#"x\^2^"#, "x^2^"),
        (#"\~x\~"#, "~x~"),
        (#"\~x~"#, "~x~"),
        (#"a\=b ==c=="#, "a=b <mark>c</mark>"),
        (#"==a\=b=="#, "<mark>a=b</mark>"),
        (#"==it's "quoted"=="#, "<mark>it’s “quoted”</mark>"),
        ("&amp;==a==", "&amp;<mark>a</mark>"),
    ])
    func escapesKeepADelimiterLiteral(markdown: String, html: String) {
        #expect(inline(markdown) == html)
    }

    @Test func marksNestWithEmphasisAndLinks() {
        #expect(inline("==a **b** c==") == "<mark>a <strong>b</strong> c</mark>")
        #expect(inline("**==a==**") == "<strong><mark>a</mark></strong>")
        #expect(inline("*^2^*") == "<em><sup>2</sup></em>")
        #expect(inline("==[l](https://x.y)==") == #"<mark><a href="https://x.y">l</a></mark>"#)
        #expect(inline("[==l==](https://x.y)") == #"<a href="https://x.y"><mark>l</mark></a>"#)
        #expect(inline("==a ^b^ c==") == "<mark>a <sup>b</sup> c</mark>")
        #expect(inline("~H^2^~") == "<sub>H<sup>2</sup></sub>")
        #expect(inline("~~==a==~~") == "<del><mark>a</mark></del>")
        #expect(inline("==~a~==") == "<mark><sub>a</sub></mark>")
    }

    /// A mark can't leave the container it began in, so the tags always nest.
    @Test func aMarkDoesNotCrossAContainer() {
        #expect(inline("==a **b== c**") == "==a <strong>b== c</strong>")
        #expect(inline("**a ==b** c==") == "<strong>a ==b</strong> c==")
        #expect(inline("^a **b^**") == "^a <strong>b^</strong>")
    }

    @Test func aSupDoesNotSpanASoftBreak() {
        #expect(inline("^a\nb^") == "^a\nb^")
        #expect(inline("==a\nb==") == "<mark>a\nb</mark>")
    }

    @Test func aCrossedPairKeepsTheOuterOne() {
        #expect(inline("==a ^b== c^") == "<mark>a ^b</mark> c^")
    }

    @Test func codeMathAndRawHTMLAreUntouched() {
        #expect(inline("`==a== ^b^ ~c~`") == "<code>==a== ^b^ ~c~</code>")
        #expect(inline("<span title=\"==a==\">x^2^</span>") == "<span title=\"==a==\">x<sup>2</sup></span>")
        #expect(MarkdownRenderer.render("```\n==a== ^b^ ~c~\n```\n").contains("==a== ^b^ ~c~"))
        #expect(MarkdownRenderer.render("    ==a== ^b^\n").contains("==a== ^b^"))
        #expect(MarkdownRenderer.render("<div>\n==a== ^b^\n</div>\n").contains("==a== ^b^"))
        let math = MarkdownRenderer.render("$a==b==c$ and $x^2^$ and $$\\sim a~b~$$\n")
        #expect(!math.contains("<mark>") && !math.contains("<sup>") && !math.contains("<sub>"))
        #expect(math.contains("a==b==c") && math.contains("x^2^"))
        // Next to math, outside it.
        #expect(inline("==$x$==").hasPrefix("<mark><span class=\"math-inline\">x</span></mark>"))
    }

    @Test func linkDestinationsAndAutolinksAreUntouched() {
        let link = inline("[a](https://x.y/?a==b==c^d^)")
        #expect(link == #"<a href="https://x.y/?a==b==c^d^">a</a>"#)
        #expect(inline("<https://x.y/^a^>") == #"<a href="https://x.y/^a^">https://x.y/^a^</a>"#)
        #expect(inline("![==a==](x.png)") == #"<img src="x.png" alt="==a==">"#)
    }

    @Test func headingsTablesAndListsCarryMarks() {
        let html = MarkdownRenderer.render("# H~2~O ==hot==\n\n| a ==b== | c^2^ |\n|--|--|\n| ~d~ | e |\n\n- ==item==\n")
        #expect(html.contains(#"<h1 id="h2o-hot" data-line="1">H<sub>2</sub>O <mark>hot</mark></h1>"#))
        #expect(html.contains("<th>a <mark>b</mark></th>"))
        #expect(html.contains("<th>c<sup>2</sup></th>"))
        #expect(html.contains("<td><sub>d</sub></td>"))
        #expect(html.contains("><mark>item</mark>\n</li>"))
    }

    @Test func footnotesCarryMarksToo() {
        let html = MarkdownRenderer.render("a[^n] ==b==\n\n[^n]: note ==here== and H~2~O\n")
        #expect(html.contains("<mark>b</mark>"))
        #expect(html.contains("note <mark>here</mark> and H<sub>2</sub>O"))
    }

    /// cmark-gfm numbers every inline of a paragraph that began with link reference definitions
    /// by the definition's line, so its ranges point at the wrong source. Marks that can't be
    /// read from the source stay literal, and `~~` stays a `<del>`, never a `<sub>`: the known
    /// gap of reading ranges, in a rare spot (definitions in the same paragraph as text).
    @Test func aParagraphAfterReferenceDefinitionsFallsBackToLiteral() {
        let html = MarkdownRenderer.render("[ref]: /url \"t~\"\n[q](?a:b) ~~_~~ ~~x~~ ~y~ ==z==\n")
        #expect(html.contains("<del>_</del> <del>x</del>"))
        #expect(!html.contains("<sub>") && !html.contains("<mark>"))
        // A blank line ends the definitions, and the paragraph after it reads as usual.
        #expect(MarkdownRenderer.render("[ref]: /u\n\n~~a~~ ~b~ ==c==\n").contains("<del>a</del> <sub>b</sub> <mark>c</mark>"))
    }

    @Test func aFootnoteReferenceIsNotASup() {
        let html = MarkdownRenderer.render("a[^1] b[^2] c\n\n[^1]: x\n[^2]: y\n")
        #expect(html.contains(#"<sup class="footnote-ref">"#))
        #expect(!html.contains("<sup>"))
    }

    @Test func frontMatterShiftsNothing() {
        let html = MarkdownRenderer.render("---\ntitle: t\n---\n\n==a== H~2~O\n")
        #expect(html.contains(#"<p data-line="5"><mark>a</mark> H<sub>2</sub>O</p>"#))
    }

    @Test func crLFAndCRLinesReadTheSame() {
        #expect(inline("a\r\n==b==\r\n~c~") == "a\n<mark>b</mark>\n<sub>c</sub>")
        #expect(inline("a\r==b==\r~c~") == "a\n<mark>b</mark>\n<sub>c</sub>")
    }

    @Test func nonASCIINeighboursAreFine() {
        #expect(inline("日本==語==です") == "日本<mark>語</mark>です")
        #expect(inline("😀==x==😀 ~😀~") == "😀<mark>x</mark>😀 <sub>😀</sub>")
    }

    /// The markup a document writes itself still comes through the same filters.
    @Test func writtenMarkTagsStillGoThroughTheRawHTMLRules() {
        #expect(inline("<mark>a</mark>") == "<mark>a</mark>")
        #expect(inline("==<script>x</script>==").contains("<mark>"))
    }

    /// Whatever is written, the tags come out balanced.
    @Test func randomDelimitersAlwaysBalance() {
        let pieces = ["=", "==", "^", "~", "~~", "\\", "*", "**", "_", " ", "a", "b", "\n", "`", "[x](y)", "$", "&amp;", "'", "[^1]", "> ", "- ", "|"]
        var generator = RendererDigestTests.SplitMix64(state: 0x133)
        for _ in 0..<3000 {
            var document = ""
            for _ in 0..<Int.random(in: 1...24, using: &generator) { document += pieces.randomElement(using: &generator)! }
            let html = MarkdownRenderer.render(document)
            for tag in ["mark", "sup", "sub"] {
                #expect(html.components(separatedBy: "<\(tag)>").count == html.components(separatedBy: "</\(tag)>").count, "\(document.debugDescription)")
            }
        }
    }

    /// A container with marks still treats its soft breaks as #129 does: CJK lines join, and
    /// `softBreaksAsLineBreaks` gives a `<br>`.
    @Test func softBreaksInAMarkedContainerFollowTheSoftBreakRules() {
        #expect(inline("==標記==中文\n第二行") == "<mark>標記</mark>中文第二行")
        #expect(inline("==a== b\nc") == "<mark>a</mark> b\nc")
        var options = MarkdownRenderer.Options()
        options.softBreaksAsLineBreaks = true
        #expect(MarkdownRenderer.render("==a==\nb", options: options).contains("<mark>a</mark><br>\nb"))
    }

    /// At a mark's edge the character a reader sees is inside the mark, so CJK lines still join
    /// (#155 review): the delimiters are tags, not characters. Unpaired ones show and don't join.
    @Test(arguments: [
        ("==標記==\n第二行", "<mark>標記</mark>第二行"),
        ("第一行\n==標記==", "第一行<mark>標記</mark>"),
        ("中文==標記==\n第二行", "中文<mark>標記</mark>第二行"),
        ("x^上^\n中文", "x<sup>上</sup>中文"),
        ("中文\n^上^", "中文<sup>上</sup>"),
        ("==**粗體**==\n中文", "<mark><strong>粗體</strong></mark>中文"),
        ("[==連結==](u)\n中文", "<a href=\"u\"><mark>連結</mark></a>中文"),
        ("**粗體**\n中文", "<strong>粗體</strong>中文"),
        ("==中文==\nabc", "<mark>中文</mark>\nabc"),
        ("中文==\n第二行", "中文==\n第二行"),
        ("==中\n文==", "<mark>中文</mark>"),
    ])
    func cjkLinesJoinAtAMarksEdge(markdown: String, expected: String) {
        #expect(inline(markdown) == expected)
    }

    @Test func withTheOptionOnEverySoftBreakIsALineBreakAtMarkEdgesToo() {
        var options = MarkdownRenderer.Options()
        options.softBreaksAsLineBreaks = true
        #expect(MarkdownRenderer.render("==標記==\n第二行", options: options).contains("<mark>標記</mark><br>\n第二行"))
        #expect(MarkdownRenderer.render("[==連結==](u)\n中文", options: options).contains("</a><br>\n中文"))
    }

    /// Splitting one long text around a mark is linear (#155 review: it was quadratic).
    @Test(.timeLimit(.minutes(1)))
    func aLongTextWithAMarkRendersInLinearTime() {
        #if DEBUG
        let budget = 10.0
        #else
        let budget = 1.0
        #endif
        let clock = ContinuousClock()
        let elapsed = clock.measure { _ = MarkdownRenderer.render(String(repeating: "abcdefghi ", count: 64_000) + "==x==") }
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        #expect(seconds < budget, "\(seconds) s")
    }

    /// After a hard break cmark puts later inlines on the paragraph's first line; a `~~del~~`
    /// whose shifted range lands between single tildes must stay `<del>` (#155 review).
    @Test(arguments: [
        ("，\\\n~~中~~，  \na~~a~~bbb\n", "a<del>a</del>bbb"),
        ("> a\\\n> _4_\\\n> ~~e~~，~~a~~b\n", "<del>e</del>，<del>a</del>b"),
    ])
    func aStrikethroughAfterAHardBreakStaysDel(markdown: String, expected: String) {
        let html = MarkdownRenderer.render(markdown)
        #expect(html.contains(expected), "\(html)")
        #expect(!html.contains("<sub>"), "\(html)")
    }

    @Test func aSubscriptAfterAHardBreakIsStillOne() {
        #expect(MarkdownRenderer.render("x  \nH~2~O\n").contains("H<sub>2</sub>O"))
        #expect(MarkdownRenderer.render("x\\\nH~2~O and ~~gone~~\n").contains("H<sub>2</sub>O and <del>gone</del>"))
    }
}
