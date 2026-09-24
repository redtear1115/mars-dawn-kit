import Foundation
import Testing
@testable import MarsDawnKit

/// Detection and splitting of front matter.
struct FrontMatterSplitTests {
    private func expectNoFrontMatter(_ text: String, sourceLocation: Testing.SourceLocation = #_sourceLocation) {
        let split = FrontMatter.split(text)
        #expect(split.frontMatter == nil, sourceLocation: sourceLocation)
        #expect(split.body == text[...], sourceLocation: sourceLocation)
        #expect(split.body.startIndex == text.startIndex, sourceLocation: sourceLocation)
        #expect(split.bodyLineOffset == 0, sourceLocation: sourceLocation)
    }

    @Test func splitsASimpleBlock() throws {
        let text = "---\ntitle: Hello\ndate: 2026-09-17\n---\n# Body\n"
        let split = FrontMatter.split(text)
        let frontMatter = try #require(split.frontMatter)
        #expect(frontMatter.lineRange == 1...4)
        #expect(frontMatter.rawText == "title: Hello\ndate: 2026-09-17\n")
        #expect(frontMatter.lines == ["title: Hello", "date: 2026-09-17"])
        let pairs = try #require(frontMatter.pairs)
        #expect(pairs.map(\.key) == ["title", "date"])
        #expect(pairs.map(\.value) == ["Hello", "2026-09-17"])
        #expect(split.body == "# Body\n")
        #expect(split.bodyLineOffset == 4)
        #expect(frontMatter.range == text.startIndex..<split.body.startIndex)
        #expect(text[frontMatter.range] == "---\ntitle: Hello\ndate: 2026-09-17\n---\n")
    }

    @Test(arguments: [
        "\n---\na: b\n---\n",           // blank line first
        " ---\na: b\n---\n",            // indented opener
        "--- \na: b\n---\n",            // trailing space
        "---\t\na: b\n---\n",           // trailing tab
        "----\na: b\n----\n",           // four dashes
        "--- # x\na: b\n---\n",         // anything after the dashes
        "...\na: b\n...\n",             // dots don't open
        "# Title\n---\na: b\n---\n",    // not on line 1
        "Title\n---\n",                 // setext heading
        "- - -\na: b\n---\n",           // another thematic break
        "",
        "---",
        "---\n",
    ])
    func onlyAnExactDelimiterOnLineOneOpens(_ text: String) {
        expectNoFrontMatter(text)
    }

    @Test(arguments: [
        "---\na: b\n",
        "---\na: b",
        "---\na: b\n--- \n",
        "---\na: b\n ---\n",
        "---\na: b\n....\n",
        "---\na: b\n-----\nc\n",
    ])
    func unterminatedBlockIsNotFrontMatter(_ text: String) {
        expectNoFrontMatter(text)
    }

    @Test func unterminatedBlockRendersAsPlainMarkdown() {
        // A thematic break, then a setext heading: exactly what renders without F1.
        let html = MarkdownRenderer.render("---\ntitle: x\n")
        #expect(html == "<hr data-line=\"1\">\n<p data-line=\"2\">title: x</p>\n")
        #expect(!html.contains("front-matter"))
    }

    @Test func dotsClose() throws {
        let split = FrontMatter.split("---\na: b\n...\nBody\n")
        #expect(try #require(split.frontMatter).lineRange == 1...3)
        #expect(split.body == "Body\n")
        #expect(split.bodyLineOffset == 3)
    }

    @Test func firstClosingLineWins() throws {
        let split = FrontMatter.split("---\na: b\n...\nc: d\n---\nBody\n")
        #expect(try #require(split.frontMatter).lines == ["a: b"])
        #expect(split.body == "c: d\n---\nBody\n")
        #expect(split.bodyLineOffset == 3)
    }

    @Test func crlfLineEndings() throws {
        let text = "---\r\ntitle: x\r\n\r\ntags: y\r\n---\r\n# Body\r\n"
        let split = FrontMatter.split(text)
        let frontMatter = try #require(split.frontMatter)
        #expect(frontMatter.lineRange == 1...5)
        #expect(frontMatter.rawText == "title: x\r\n\r\ntags: y\r\n")
        #expect(frontMatter.lines == ["title: x", "", "tags: y"])
        #expect(frontMatter.pairs?.map(\.value) == ["x", "y"])
        #expect(split.body == "# Body\r\n")
        #expect(split.bodyLineOffset == 5)
    }

    @Test func loneCRLineEndings() throws {
        let text = "---\rtitle: x\r---\r# Body\r"
        let split = FrontMatter.split(text)
        let frontMatter = try #require(split.frontMatter)
        #expect(frontMatter.lineRange == 1...3)
        #expect(frontMatter.rawText == "title: x\r")
        #expect(frontMatter.lines == ["title: x"])
        #expect(split.body == "# Body\r")
        #expect(split.bodyLineOffset == 3)
    }

    @Test func mixedLineEndings() throws {
        let split = FrontMatter.split("---\r\na: b\rc: d\n...\r\nBody")
        #expect(try #require(split.frontMatter).lines == ["a: b", "c: d"])
        #expect(split.body == "Body")
        #expect(split.bodyLineOffset == 4)
    }

    /// A single leading byte order mark is skipped (#27): a file a Windows editor saved with
    /// one has the same front matter as without it. Everything the split reports is the same
    /// as for the unmarked text, except `range`, which is against the string as given: it
    /// starts after the mark, which stays in the text and is not part of the block.
    @Test(arguments: ["\n", "\r\n"])
    func aLeadingByteOrderMarkIsSkipped(newline: String) throws {
        let plain = ["---", "title: Notes", "---", "# Body", ""].joined(separator: newline)
        let marked = "\u{FEFF}" + plain
        let expected = try #require(FrontMatter.split(plain).frontMatter)
        let split = FrontMatter.split(marked)
        let frontMatter = try #require(split.frontMatter, "the marked text has front matter")
        #expect(frontMatter.lineRange == expected.lineRange)
        #expect(frontMatter.rawText == expected.rawText)
        #expect(frontMatter.lines == expected.lines)
        #expect(frontMatter.pairs?.map(\.key) == ["title"])
        #expect(split.bodyLineOffset == FrontMatter.split(plain).bodyLineOffset)
        #expect(split.body == FrontMatter.split(plain).body)
        #expect(marked[..<frontMatter.range.lowerBound] == "\u{FEFF}")
        #expect(marked[frontMatter.range] == plain[plain.startIndex..<plain.range(of: "# Body")!.lowerBound])
        #expect(frontMatter.range.upperBound == split.body.startIndex)
    }

    /// Only one mark, and only at the very start: a second mark, or a mark on a later line,
    /// is text like any other.
    @Test(arguments: [
        "\u{FEFF}\u{FEFF}---\na: b\n---\nBody\n",
        "---\na: b\n\u{FEFF}---\nBody\n",
        " \u{FEFF}---\na: b\n---\nBody\n",
    ])
    func onlyOneLeadingByteOrderMarkIsSkipped(text: String) {
        expectNoFrontMatter(text)
    }

    /// The renderer takes the marked document's front matter off the page, as it does the
    /// unmarked one's, instead of rendering `title: Notes` as body text.
    @Test func aMarkedDocumentRendersLikeTheUnmarkedOne() {
        let plain = "---\ntitle: Notes\n---\n\n# Heading\n\nBody.\n"
        #expect(MarkdownRenderer.render("\u{FEFF}" + plain) == MarkdownRenderer.render(plain))
    }

    @Test func laterDelimitersStayThematicBreaks() {
        let html = MarkdownRenderer.render("---\na: b\n---\nText\n\n---\n\nMore\n")
        #expect(html.hasPrefix(#"<details class="front-matter" data-line="1">"#))
        #expect(html.hasSuffix("<p data-line=\"4\">Text</p>\n<hr data-line=\"6\">\n<p data-line=\"8\">More</p>\n"))
    }

    /// A block with no content isn't front matter: it carries nothing, and treating it as
    /// front matter would change how existing documents render. `---\n---` stays two
    /// thematic breaks, as it always was.
    @Test(arguments: [
        "---\n---\n", "---\n---", "---\r\n...\r\n", "---\n\n---\n", "---\n   \n\t\n---\n", "---\r...\r",
    ])
    func emptyBlockIsNotFrontMatter(_ text: String) {
        let split = FrontMatter.split(text)
        #expect(split.frontMatter == nil)
        #expect(split.body == text)
        #expect(split.bodyLineOffset == 0)
    }

    @Test func emptyBlockKeepsRenderingAsThematicBreaks() {
        #expect(MarkdownRenderer.render("---\n---\n") == "<hr data-line=\"1\">\n<hr data-line=\"2\">\n")
        // One non-blank line is enough to make it front matter again.
        #expect(MarkdownRenderer.render("---\na: b\n---\n").hasPrefix(#"<details class="front-matter""#))
    }

    @Test(arguments: ["---\na: b\n---", "---\na: b\n---\n"])
    func blockThatIsTheWholeFile(_ text: String) throws {
        let split = FrontMatter.split(text)
        #expect(try #require(split.frontMatter).lineRange == 1...3)
        #expect(split.body.isEmpty)
        #expect(split.body.startIndex == text.endIndex)
        #expect(split.bodyLineOffset == 3)
        #expect(MarkdownRenderer.render(text)
            == #"<details class="front-matter" data-line="1"><summary>Document info</summary><table><tbody><tr><th>a</th><td>b</td></tr></tbody></table></details>"# + "\n")
    }

    /// Blank lines alone make the block empty, so it isn't front matter at all. A block with
    /// one non-pair line is front matter with no pairs.
    @Test func blankLinesAloneAreNotFrontMatter() throws {
        #expect(FrontMatter.split("---\n\n  \n---\n").frontMatter == nil)
        #expect(try #require(FrontMatter.split("---\n\n  \nnot a pair\n---\n").frontMatter).pairs == nil)
    }

    @Test func nonASCIIContentSplitsOnLineBoundaries() throws {
        let split = FrontMatter.split("---\n標題: 火星黎明 🚀\n---\ne\u{301}\n")
        let frontMatter = try #require(split.frontMatter)
        #expect(frontMatter.pairs?.first?.key == "標題")
        #expect(frontMatter.pairs?.first?.value == "火星黎明 🚀")
        #expect(split.body == "e\u{301}\n")
    }
}

/// Which lines count as `key: value`.
struct FrontMatterKeyValueTests {
    @Test(arguments: [
        ("title: Hello", "title", "Hello"),
        ("title:Hello:x", nil, nil),                    // no space after the colon
        ("title:", "title", ""),
        ("title:   ", "title", ""),
        ("title:\tTabbed\t", "title", "Tabbed"),
        ("url: https://example.com:8080/a", "url", "https://example.com:8080/a"),
        ("time: 12:30", "time", "12:30"),
        ("quoted: \"a: b\"", "quoted", "\"a: b\""),
        ("list: [a, b]", "list", "[a, b]"),
        ("snake_case-key.v2: x", "snake_case-key.v2", "x"),
        ("_private: x", "_private", "x"),
        ("2024: x", "2024", "x"),
        ("Last updated: x", "Last updated", "x"),
        ("日期: 2026", "日期", "2026"),
        ("  indented: x", nil, nil),
        ("\tindented: x", nil, nil),
        ("- item: x", nil, nil),
        ("# comment: x", nil, nil),
        ("-key: x", nil, nil),
        (".key: x", nil, nil),
        ("key : x", nil, nil),
        ("two  spaces: x", nil, nil),
        ("\"quoted\": x", nil, nil),
        ("a:b: c", nil, nil),
        ("<b>: x", nil, nil),
        ("? complex", nil, nil),
        ("plain text", nil, nil),
        (": x", nil, nil),
        ("", nil, nil),
        // Combining marks, judged by scalar (see `keyValue(in:)`).
        ("e\u{301}te\u{301}: x", "e\u{301}te\u{301}", "x"),     // decomposed letters
        ("a\u{301}\u{316}\u{301}: x", "a\u{301}\u{316}\u{301}", "x"),
        ("क्षेत्र: x", "क्षेत्र", "x"),                              // virama (Mn) and vowel sign (Mc)
        ("ab\u{200D}c: x", "ab\u{200D}c", "x"),
        ("2\u{20E3}: x", "2\u{20E3}", "x"),                     // enclosing mark on a digit
        ("\u{301}a: x", nil, nil),                              // mark first
        ("_\u{301}: x", nil, nil),                              // mark on "_"
        ("a-\u{301}: x", nil, nil),                             // mark on "-"
        ("a.\u{301}b: x", nil, nil),                            // mark on "."
        ("a \u{301}b: x", nil, nil),                            // mark on a space
        ("\u{200D}a: x", nil, nil),
        ("a\u{0600}: x", nil, nil),                             // Prepend scalar before ":"
        ("a\u{0600}:x", nil, nil),
        ("a:\u{301} x", nil, nil),                              // mark straight after ":"
        ("a: \u{301}v", "a", "\u{301}v"),                       // value may start with a mark
        ("a: v \u{301}", "a", "v \u{301}"),
        ("a\u{0}: x", nil, nil),
        ("a: x\u{0}y", "a", "x\u{0}y"),
    ] as [(line: String, key: String?, value: String?)])
    func keyValueRule(_ testCase: (line: String, key: String?, value: String?)) {
        let pair = FrontMatter.keyValue(in: testCase.line)
        #expect(pair?.key == testCase.key)
        #expect(pair?.value == testCase.value)
    }

    @Test func anyNonPairLineMakesTheBlockNonSimple() throws {
        let nested = "---\ntitle: x\ntags:\n  - a\n  - b\n---\n"
        #expect(try #require(FrontMatter.split(nested).frontMatter).pairs == nil)
        let comment = "---\n# note\ntitle: x\n---\n"
        #expect(try #require(FrontMatter.split(comment).frontMatter).pairs == nil)
        let duplicates = "---\na: 1\n\na: 2\n---\n"
        #expect(try #require(FrontMatter.split(duplicates).frontMatter).pairs?.map(\.value) == ["1", "2"])
    }
}

/// How the renderer shows front matter.
struct FrontMatterRenderingTests {
    @Test func simpleBlockRendersAsATable() {
        let html = MarkdownRenderer.render("---\ntitle: Hello\ndate: 2026-09-17\n---\n# Body\n")
        #expect(html == #"<details class="front-matter" data-line="1"><summary>Document info</summary>"#
            + "<table><tbody><tr><th>title</th><td>Hello</td></tr><tr><th>date</th><td>2026-09-17</td></tr></tbody></table>"
            + "</details>\n"
            + #"<h1 id="body" data-line="5">Body</h1>"# + "\n")
    }

    @Test func otherBlocksRenderAsPreformattedText() {
        let html = MarkdownRenderer.render("---\ntitle: x\ntags:\n  - a\n\n  - b\n---\nText\n")
        #expect(html == #"<details class="front-matter" data-line="1"><summary>Document info</summary>"#
            + "<pre>title: x\ntags:\n  - a\n\n  - b</pre>"
            + "</details>\n"
            + #"<p data-line="8">Text</p>"# + "\n")
    }

    @Test func crlfBlockRendersWithPlainNewlines() {
        let html = MarkdownRenderer.render("---\r\n# c\r\na: b\r\n---\r\n")
        #expect(html.contains("<pre># c\na: b</pre>"))
        #expect(!html.contains("\r"))
    }

    /// A block whose only content is blank lines is still front matter as soon as one line
    /// has something in it; with nothing at all it isn't (see `emptyBlockIsNotFrontMatter`).
    @Test func blankLinesAroundContentStayInThePre() {
        #expect(MarkdownRenderer.render("---\n\nx\n\n---\n")
            == #"<details class="front-matter" data-line="1"><summary>Document info</summary><pre>"#
            + "\nx\n</pre></details>\n")
    }

    @Test func labelComesFromTheOptionsAndIsEscaped() {
        let localized = MarkdownRenderer.Options(frontMatterLabel: "文件資訊")
        #expect(MarkdownRenderer.render("---\na: b\n---\n", options: localized).contains("<summary>文件資訊</summary>"))

        let hostile = MarkdownRenderer.Options(frontMatterLabel: #"<img src=x onerror="alert(1)"> & more"#)
        let html = MarkdownRenderer.render("---\na: b\n---\n", options: hostile)
        #expect(html.contains(#"<summary>&lt;img src=x onerror="alert(1)"&gt; &amp; more</summary>"#))
        #expect(!html.contains("<img"))
    }

    /// Everything in the block is inert text, whether it renders as a table or as a `<pre>`.
    @Test func hostileContentIsInertText() {
        let values = """
        script: <script>alert(1)</script>
        amp: Tom & Jerry &amp; &lt;
        quotes: "double" 'single' `tick`
        url: javascript:alert(1)
        link: [x](javascript:alert(1))
        auto: <https://example.com> https://example.com
        html: <img src=x onerror=alert(1)><a href="javascript:alert(1)">y</a>
        md: **bold** ![i](x.png) <!-- c -->
        close: </td></tr></table></details><script>alert(2)</script>
        """
        let table = MarkdownRenderer.render("---\n" + values + "\n---\n")
        #expect(table.contains("<table>"))
        #expect(table.contains("<tr><th>script</th><td>&lt;script&gt;alert(1)&lt;/script&gt;</td></tr>"))
        #expect(table.contains("<tr><th>amp</th><td>Tom &amp; Jerry &amp;amp; &amp;lt;</td></tr>"))
        #expect(table.contains(#"<tr><th>quotes</th><td>"double" 'single' `tick`</td></tr>"#))
        #expect(table.contains("<tr><th>url</th><td>javascript:alert(1)</td></tr>"))
        #expect(table.contains("<tr><th>link</th><td>[x](javascript:alert(1))</td></tr>"))
        #expect(table.contains("<tr><th>md</th><td>**bold** ![i](x.png) &lt;!-- c --&gt;</td></tr>"))
        #expect(table.contains("<tr><th>close</th><td>&lt;/td&gt;&lt;/tr&gt;&lt;/table&gt;&lt;/details&gt;&lt;script&gt;alert(2)&lt;/script&gt;</td></tr>"))

        // A line that isn't `key: value` switches to the <pre>, with the same content.
        let pre = MarkdownRenderer.render("---\n" + values + "\n<b>: not a key\n---\n")
        #expect(pre.contains("<pre>script: &lt;script&gt;alert(1)&lt;/script&gt;\n"))
        #expect(pre.contains("\n&lt;b&gt;: not a key</pre>"))

        for html in [table, pre] {
            let block = String(html[..<html.range(of: "</details>")!.upperBound])
            // Escaped text has no "<", so every "<…>" is real markup: only the fixed tags.
            let tags = Set(block.matches(of: /<[^>]*>/).map { String($0.output) })
            let allowed: Set<String> = [
                #"<details class="front-matter" data-line="1">"#, "</details>", "<summary>", "</summary>",
                "<table>", "</table>", "<tbody>", "</tbody>", "<tr>", "</tr>", "<th>", "</th>",
                "<td>", "</td>", "<pre>", "</pre>",
            ]
            #expect(tags.isSubset(of: allowed), "\(tags.subtracting(allowed))")
            #expect(block.hasPrefix(#"<details class="front-matter" data-line="1"><summary>Document info</summary>"#))
            #expect(block.components(separatedBy: "</details>").count == 2)
            #expect(html.components(separatedBy: "</details>").count == 2)
        }
    }

    @Test func nulBecomesAReplacementCharacter() {
        let table = MarkdownRenderer.render("---\na: b\u{0}c\n---\n", options: .init(frontMatterLabel: "L\u{0}"))
        #expect(table.contains("<summary>L\u{FFFD}</summary>"))
        #expect(table.contains("<td>b\u{FFFD}c</td>"))
        #expect(!table.utf8.contains(0))

        let pre = MarkdownRenderer.render("---\n\u{0}<x>\u{0}\n---\nBody \u{0}\n")
        #expect(pre.contains("<pre>\u{FFFD}&lt;x&gt;\u{FFFD}</pre>"))
        #expect(pre.contains("<p data-line=\"4\">Body \u{FFFD}</p>"))  // cmark does the same
        #expect(!pre.utf8.contains(0))

        // The split itself keeps the text as written.
        #expect(FrontMatter.split("---\na: \u{0}\n---\n").frontMatter?.pairs?.first?.value == "\u{0}")
    }

    /// Documented: the body is parsed on its own, so a U+FEFF right after the closing
    /// delimiter is dropped as a byte order mark instead of rendering as text.
    @Test func byteOrderMarkStartingTheBodyIsDropped() {
        let html = MarkdownRenderer.render("---\na: b\n---\n\u{FEFF}Text\n")
        #expect(html.hasSuffix("<p data-line=\"4\">Text</p>\n"))
        #expect(!html.unicodeScalars.contains("\u{FEFF}"))
        // In place (padded), the same character would have been text.
        #expect(MarkdownRenderer.render("\n\n\n\u{FEFF}Text\n").unicodeScalars.contains("\u{FEFF}"))
        // Anywhere later in the body it is kept.
        #expect(MarkdownRenderer.render("---\na: b\n---\nA\u{FEFF}B\n").unicodeScalars.contains("\u{FEFF}"))
    }

    /// A Prepend scalar (U+0600) fuses with the "<" after it into one `Character`, which used
    /// to hide it from `escapeHTML`. The byte-level escaper (0.2.1) escapes it, and the
    /// front-matter path inherits that because it uses the shared escaper.
    @Test func prependScalarBeforeALessThanSign() {
        let html = MarkdownRenderer.render("---\na: \u{0600}<script>alert(1)</script>\n---\n")
        let block = html as NSString
        #expect(block.range(of: "<script").location == NSNotFound)
        #expect(block.range(of: "&lt;/script&gt;").location != NSNotFound)
    }

    @Test func frontMatterIsNotParsedAsMarkdown() {
        // Without F1 this would be a thematic break and a setext heading.
        let html = MarkdownRenderer.render("---\ntitle: x\n---\n")
        #expect(!html.contains("<hr"))
        #expect(!html.contains("<h2"))
        #expect(!html.contains("<p"))
    }

    @Test func bodyLinesAreFileLines() {
        let body = "# Heading\n\nPara\n\n- a\n- b\n\n| t |\n|---|\n| c |\n\n> quote\n\n```\ncode\n```\n"
        let html = MarkdownRenderer.render("---\ntitle: x\n---\n" + body)
        #expect(html.contains(#"<h1 id="heading" data-line="4">"#))
        #expect(html.contains(#"<p data-line="6">Para</p>"#))
        #expect(html.contains(#"<ul data-line="8">"#))
        #expect(html.contains(#"<li data-line="9">b"#))
        #expect(html.contains(#"<table data-line="11">"#))
        #expect(html.contains(#"<tr data-line="13">"#))
        #expect(html.contains(#"<blockquote data-line="15">"#))
        #expect(html.contains(#"<pre data-line="17"><code>"#))
    }

    /// The offset gives the same line numbers as the body preceded by as many blank lines.
    @Test(arguments: [
        ("---\ntitle: x\n---\n", "\n\n\n"),
        ("---\r\na: b\r\nc\r\n...\r\n", "\r\n\r\n\r\n\r\n"),
        ("---\ra: b\r---\r", "\r\r\r"),
    ])
    func offsetMatchesPaddedBody(_ frontMatter: String, _ padding: String) {
        let body = RenderGoldenCorpus.documents[0] + "\n" + RenderGoldenCorpus.documents[3] + "\n\nSetext\n---\n"
        let withFrontMatter = MarkdownRenderer.render(frontMatter + body)
        let block = String(withFrontMatter[..<withFrontMatter.range(of: "</details>\n")!.upperBound])
        #expect(withFrontMatter == block + MarkdownRenderer.render(padding + body))
        #expect(withFrontMatter != block + MarkdownRenderer.render(body))
    }

    @Test func slugsAndBodyAreUnaffected() {
        let body = "# Title\n\n## Title\n\nText *em*.\n"
        let html = MarkdownRenderer.render("---\ntitle: Title\n---\n" + body)
        #expect(html.contains(#"<h1 id="title" data-line="4">Title</h1>"#))
        #expect(html.contains(#"<h2 id="title-1" data-line="6">Title</h2>"#))
    }

    @Test func asyncOverloadMatches() async {
        let source = "---\na: <b>\n---\n# H\n"
        let asyncResult = await MarkdownRenderer.renderResult(source)
        #expect(asyncResult == Self.renderBlocking(source))
        #expect(asyncResult?.html.contains("<td>&lt;b&gt;</td>") == true)
    }

    private static func renderBlocking(_ source: String) -> MarkdownRenderer.RenderResult {
        MarkdownRenderer.renderResult(source)
    }

    @Test func previewStylesTheBlockAndPrintHidesIt() throws {
        let url = try #require(Bundle.module.url(forResource: "Preview/preview", withExtension: "css"))
        let css = try String(contentsOf: url, encoding: .utf8)
        #expect(css.contains(".front-matter {"))
        #expect(css.contains("@media print { .front-matter { display: none !important; } }"))
        // K1's fallback rule is kept.
        #expect(css.contains(".source-fallback { white-space: pre-wrap; overflow-wrap: anywhere; }"))
    }
}

/// Front matter with K1's guards: the body is what gets depth-checked and parsed.
struct FrontMatterFallbackTests {
    private static func renderBlocking(_ source: String, options: MarkdownRenderer.Options = .init()) -> MarkdownRenderer.RenderResult {
        MarkdownRenderer.renderResult(source, options: options)
    }

    @Test func tooDeepBodyKeepsTheBlockAndFallsBackForTheBody() async throws {
        let frontMatter = "---\ntitle: <script>alert(1)</script>\n---\n"
        let body = String(repeating: ">", count: 300) + " <b>x</b> & y\n"
        let depth = CMarkDepthScan.maximumDepth(of: body)
        #expect(depth > ParseLimits.default.maxDepth)
        let expected = MarkdownRenderer.RenderResult(
            html: #"<details class="front-matter" data-line="1"><summary>Document info</summary>"#
                + "<table><tbody><tr><th>title</th><td>&lt;script&gt;alert(1)&lt;/script&gt;</td></tr></tbody></table></details>\n"
                + #"<pre class="source-fallback" data-line="4">"#
                + String(repeating: "&gt;", count: 300) + " &lt;b&gt;x&lt;/b&gt; &amp; y\n</pre>",
            fallback: .tooDeep(depth: depth)
        )
        let source = frontMatter + body
        #expect(Self.renderBlocking(source) == expected)
        #expect(onSmallStackThread { MarkdownRenderer.renderResult(source) } == expected)
        #expect(await Task.detached { await MarkdownRenderer.renderResult(source) }.value == expected)
    }

    @Test(arguments: NestingShape.allCases)
    func everyTooDeepShapeBehindFrontMatterFallsBack(_ shape: NestingShape) {
        let body = shape.source(shape.deepCount)
        let source = "---\r\na: b\r\n---\r\n" + body
        let result = onSmallStackThread { MarkdownRenderer.renderResult(source) }
        #expect(result.fallback == .tooDeep(depth: CMarkDepthScan.maximumDepth(of: body)))
        #expect(result.html.hasSuffix(MarkdownRenderer.sourceFallbackHTML(body, firstLine: 4)))
    }

    @Test func deepTextInsideTheBlockIsNeverParsed() {
        let source = "---\n" + String(repeating: ">", count: 5_000) + "\n---\nok\n"
        #expect(CMarkDepthScan.maximumDepth(of: source) > ParseLimits.default.maxDepth)
        let result = onSmallStackThread { MarkdownRenderer.renderResult(source) }
        #expect(result.fallback == nil)
        #expect(result.html.contains("<pre>" + String(repeating: "&gt;", count: 5_000) + "</pre>"))
        #expect(result.html.hasSuffix("<p data-line=\"4\">ok</p>\n"))
    }

    @Test func byteLimitCoversTheWholeFile() {
        let source = "---\ntitle: a long enough value\n---\nBody\n"
        let bodyBytes = "Body\n".utf8.count
        let limited = MarkdownRenderer.Options(maxBytes: source.utf8.count - 1)
        #expect(bodyBytes <= source.utf8.count - 1)
        let result = Self.renderBlocking(source, options: limited)
        #expect(result == MarkdownRenderer.RenderResult(
            html: MarkdownRenderer.sourceFallbackHTML(source), fallback: .tooLarge))
        #expect(result.html.hasPrefix(#"<pre class="source-fallback" data-line="1">---"#))

        let exact = MarkdownRenderer.Options(maxBytes: source.utf8.count)
        #expect(Self.renderBlocking(source, options: exact).fallback == nil)
        #expect(Self.renderBlocking(source, options: exact).html.contains("front-matter"))
    }

    @Test func byteLimitAppliesToTheAsyncOverloadToo() async {
        let source = "---\na: b\n---\n"
        let result = await MarkdownRenderer.renderResult(source, options: .init(maxBytes: 3))
        #expect(result?.fallback == .tooLarge)
        #expect(result?.html == MarkdownRenderer.sourceFallbackHTML(source))
    }
}

/// Documents without front matter render exactly as they did before front matter support.
struct NoFrontMatterGoldenTests {
    /// SHA-256 of each `RenderGoldenCorpus.documents` entry's HTML, recorded on
    /// k1-nesting-hardening (fa99d18) before front matter support was added.
    /// The entry for `"\u{FEFF}---\ntitle: x\n---\nBody\n"` was removed with that document (#27):
    /// a single leading byte order mark is now skipped, so it has front matter.
    static let k1Digests = [
        "cf98d15423aaffb634dde01aae28658a9a9f4aced29495fb4988bfb6da26e916",
        "5c92caa0edc56c3ab2a4262261b79f91fb7e6e033d7ec19d9706ecad63c0e2fc",
        "009b4f37f21d4fef4c32b859f664bc8c8fd5df1083bf42d4e372259e1a063ba2",
        "9d28b7eeb7ebc33190bb3fa51bdd0b7755f705f72e158615fe26c30325e5dcf1",
        "8aab8838d2c76adb638d402b3fb7acb64168c212d614c50ccd6815e02183652b",
        "e8e28504b1b2287b9904056bcefc86eaebc1ba4fdc2b9df0efb1543ab3027613",
        "c628de0d2b717b191214caa8647eb8b9b0012b6add9ba0c36bba50900fafb507",
        // Document 7 has a footnote (`Term[^1]`), which #44 renders as one; the rest is as before.
        "d30e93f36891679d1b1921a878ef038adbe2124ff4013c5200340093ce89184a",
        "eca41a28c3b54d8185c3b06cb60997f4b3de70f63c0c7ce7b2bf6b7c4b7a287b",
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        "abbdf27ee3810af6a2530a9a944b4fccfa2846fbc608427a9cb47fb86360adf2",
        "6ada9ce9c76637954c276eeafda3ce432a0a6b4ce7520a09a42dbc0073e4b472",
        "85d6f08a1798fc5c0d366dd05956a5844c8225ffae3b124a490611893b592c5a",
        "05d4694175b7eade9bce1b9252ea1da763a382246593be8e5277af402c5fc90c",
        "05d4694175b7eade9bce1b9252ea1da763a382246593be8e5277af402c5fc90c",
        "05d4694175b7eade9bce1b9252ea1da763a382246593be8e5277af402c5fc90c",
        "48fd9269683f432ec1c63befb671ab02a75513cbeb3a608fb190a6f1a9b90a97",
        "88745db2f18d2f6624c141c5a7516bd4cd8bcc91cc76ca329073ab7518b4c74c",
        "28a0a13423b426a764a6e3965b3071fb97433bbeb499744c847b2c66ae64e659",
        "03dfd008bb5b073b98e60809fe12dd621628200400735249339d9a8c82a56a4e",
        "5a62e46d607406055641ae0d4c858b639d285e56487ca8cbf284da8b1675562a",
        "21a5c53fa5a87cf0a3c7b9e9292c6f999f8c204bc973f2465a10691b43f2e557",
        "76392f6250089f4144aa335da6cfcaa9952a972598286cc15c23d96d0dc0e54a",
        "76392f6250089f4144aa335da6cfcaa9952a972598286cc15c23d96d0dc0e54a",
        "5eabf05375f5caadcd22fd253d176ef8e89121009963dbb5c40eac6e44eaf9b4",
        "012887db87cce4295e399677fac00dbec1463dd25f28b0fc7af8c39ec08aebc1",
    ]

    @Test func corpusRendersAsBeforeFrontMatterSupport() {
        let documents = RenderGoldenCorpus.documents
        #expect(documents.count == Self.k1Digests.count)
        for (index, (document, digest)) in zip(documents, Self.k1Digests).enumerated() {
            #expect(FrontMatter.split(document).frontMatter == nil, "document \(index)")
            let html = MarkdownRenderer.render(document)
            #expect(RenderGoldenCorpus.digest(html) == digest, "document \(index): \(document.debugDescription) → \(html.debugDescription)")
        }
    }

    @Test func customLabelDoesNotChangeDocumentsWithoutFrontMatter() {
        let options = MarkdownRenderer.Options(frontMatterLabel: "<x>")
        for document in RenderGoldenCorpus.documents {
            #expect(MarkdownRenderer.render(document, options: options) == MarkdownRenderer.render(document))
        }
    }
}

/// #97: `split` must not scan to the end of a large document to prove an opened front matter
/// block never closes. These assert on `FrontMatter.search`'s `linesScanned`, an ordinary
/// returned value, rather than on wall-clock time (and rather than shared mutable state, which
/// would race against every other test's concurrent calls into `split`).
struct FrontMatterUnclosedScanBoundTests {
    /// Well within the bound: a document this size closing its front matter must still behave
    /// exactly as it did before the bound existed.
    @Test func closedFrontMatterWellWithinTheBoundIsUnchanged() throws {
        let innerLines = (0..<200).map { "k\($0): v\($0)" }
        let text = "---\n" + innerLines.map { $0 + "\n" }.joined() + "---\n# Body\n"
        let split = FrontMatter.split(text)
        let frontMatter = try #require(split.frontMatter)
        #expect(frontMatter.lines == innerLines)
        #expect(frontMatter.pairs?.map(\.key) == innerLines.indices.map { "k\($0)" })
        #expect(split.body == "# Body\n")
        #expect(split.bodyLineOffset == innerLines.count + 2)
        #expect(FrontMatter.search(text).linesScanned == innerLines.count + 1)
    }

    /// The closing delimiter sitting on the very last line the search is still willing to look
    /// at (see the bound arithmetic in `search`) must still be found.
    @Test func closingDelimiterRightAtTheBoundIsStillFound() throws {
        let max = FrontMatter.maxUnclosedSearchLines
        let innerLines = (0..<(max - 1)).map { "line \($0)" }
        let text = "---\n" + innerLines.map { $0 + "\n" }.joined() + "---\n# Body\n"
        let split = FrontMatter.split(text)
        let frontMatter = try #require(split.frontMatter)
        #expect(frontMatter.lines == innerLines)
        #expect(split.body == "# Body\n")
    }

    /// One line further out than the case above: the search has already given up by the time it
    /// would reach this closer, so the document is (deliberately) treated as having no front
    /// matter, exactly as it is today for a front matter block that never closes at all.
    @Test func closingDelimiterOneLinePastTheBoundIsNotFound() {
        let max = FrontMatter.maxUnclosedSearchLines
        let innerLines = (0..<max).map { "line \($0)" }
        let text = "---\n" + innerLines.map { $0 + "\n" }.joined() + "---\n# Body\n"
        let split = FrontMatter.split(text)
        #expect(split.frontMatter == nil)
        #expect(split.body == text[...])
    }

    /// The app's reported case: a large document whose front matter never closes (the closing
    /// line is being retyped). The search must stop after `maxUnclosedSearchLines` lines, not
    /// scan on to the end of a huge document.
    @Test func unclosedFrontMatterOnALargeDocumentIsBounded() {
        let lineCount = 200_000
        let text = "---\n" + String(repeating: "not a delimiter\n", count: lineCount)
        let result = FrontMatter.search(text)
        #expect(result.frontMatter == nil)
        #expect(result.body == text[...])
        // Bounded: the search looked at only a small, fixed slice of the document, not
        // something that scales with its 200,000 lines.
        #expect(result.linesScanned <= FrontMatter.maxUnclosedSearchLines)
    }
}
