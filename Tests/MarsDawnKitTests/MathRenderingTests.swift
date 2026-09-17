import Foundation
import Testing
@testable import MarsDawnKit

/// What the renderer emits for math: the element shapes, the escaping, the `data-line`
/// numbers, and the fact that nothing about a document without math changes.
///
/// `MathExtractorTests` covers what counts as math. These tests start from the rendered HTML.
struct MathRenderingTests {
    // MARK: Helpers

    /// The contents of every math element, in document order, with the escaping undone.
    ///
    /// Undoing it is the point: the assertions below compare against the TeX as written, so a
    /// missing `escapeHTML` shows up as a mismatch here and as a stray `<` in `html`.
    static func math(in html: String) -> [(kind: String, tex: String)] {
        var found: [(String, String)] = []
        var rest = Substring(html)
        while let start = rest.range(of: "<span class=\"math-inline")
            ?? rest.range(of: "<div class=\"math-block\"") {
            let isBlock = rest[start].hasPrefix("<div")
            let afterTag = rest[start.upperBound...]
            guard let close = afterTag.firstIndex(of: ">") else { break }
            let attributes = afterTag[..<close]
            let body = afterTag[afterTag.index(after: close)...]
            guard let end = body.range(of: isBlock ? "</div>" : "</span>") else { break }
            let kind = isBlock ? "block" : (attributes.contains("math-display") ? "display" : "inline")
            found.append((kind, unescape(String(body[..<end.lowerBound]))))
            rest = body[end.upperBound...]
        }
        return found
    }

    /// The reverse of `escapeHTML`. `&amp;` last, so `&amp;lt;` comes back as `&lt;`.
    static func unescape(_ html: String) -> String {
        html.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    static func lines(of html: String, forClass className: String) -> [String] {
        var found: [String] = []
        var rest = Substring(html)
        while let start = rest.range(of: "class=\"\(className)\" data-line=\"") {
            let after = rest[start.upperBound...]
            guard let end = after.firstIndex(of: "\"") else { break }
            found.append(String(after[..<end]))
            rest = after[end...]
        }
        return found
    }

    // MARK: Shapes

    @Test func inlineMathIsASpanHoldingOnlyTheTeX() {
        let html = MarkdownRenderer.render(#"Inline $a\,b$ here."#)
        #expect(html == "<p data-line=\"1\">Inline <span class=\"math-inline\">a\\,b</span> here.</p>\n")
    }

    @Test func aDisplayFenceIsADivCarryingItsSourceLine() {
        let html = MarkdownRenderer.render("Intro\n\n$$\na \\\\ b\n$$\n\nAfter\n")
        #expect(html.contains("<div class=\"math-block\" data-line=\"3\">\na \\\\ b\n</div>\n"))
        // The lines after a rewritten block still address the file.
        #expect(html.contains("<p data-line=\"7\">After</p>"))
    }

    @Test func anAuthoredMathFenceIsADisplayBlock() {
        let html = MarkdownRenderer.render("```math\nE = mc^2\n```\n")
        #expect(html == "<div class=\"math-block\" data-line=\"1\">E = mc^2</div>\n")
    }

    /// `$$…$$` that stays inside a paragraph can't be a `div`, so it is a span that still says
    /// "display" — the class is the only thing `preview.js` reads besides the text.
    @Test func displayMathInsideAParagraphIsAMarkedSpan() {
        let html = MarkdownRenderer.render("where $$x^2$$ holds, and $y$")
        #expect(html.contains(#"<span class="math-inline math-display">x^2</span>"#))
        #expect(html.contains(#"<span class="math-inline">y</span>"#))
    }

    @Test func aStandaloneOneLineDisplayParagraphKeepsDisplayMode() {
        let html = MarkdownRenderer.render("$$ x = 1 $$\n")
        #expect(Self.math(in: html).map(\.kind) == ["display"])
    }

    @Test func mathInHeadingsListsQuotesAndCellsRenders() {
        let html = MarkdownRenderer.render("# H $a$\n\n- $b$\n\n> $c$\n\n| $d$ |\n|---|\n| $e$ |\n")
        #expect(Self.math(in: html).map(\.tex) == ["a", "b", "c", "d", "e"])
    }

    // MARK: Escaping

    /// The cases from the plan. Each one is TeX the HTML parser would read as markup if the
    /// renderer put it through unescaped.
    @Test(arguments: [
        "</span><script>alert(1)</script>",
        "a & b",
        #"a"b'c"#,
        "x<y>z",
        "&lt;",
        "&amp;#39;",
    ])
    func texReachesThePageEscaped(tex: String) {
        for source in ["Before $\(tex)$ after", "```math\n\(tex)\n```\n"] {
            let html = MarkdownRenderer.render(source)
            // It is there, and unescaping gives back exactly what was written.
            #expect(Self.math(in: html).map(\.tex) == [tex])
            // Nothing the parser could read as a tag or an entity survived unescaped.
            let elements = Self.math(in: html).isEmpty
            #expect(!elements)
            let inside = html.components(separatedBy: ">").dropFirst().joined(separator: ">")
            #expect(!inside.contains("<script"))
            #expect(!inside.contains("<img"))
        }
    }

    /// The escaping is the shared byte-level `escapeHTML`, so the three entities it writes are
    /// the three that appear, and quotes are left alone (this is element content, not an
    /// attribute — no TeX is ever put in an attribute).
    @Test func escapingUsesTheSharedEscaper() {
        let html = MarkdownRenderer.render(#"$<&>"'$"#)
        #expect(html.contains(#"<span class="math-inline">&lt;&amp;&gt;"'</span>"#))
    }

    // MARK: The TeX is the source between the delimiters

    @Test(arguments: [
        (#"$a\,b$"#, #"a\,b"#),
        (#"$\{x\}$"#, #"\{x\}"#),
        ("$a*b*c$", "a*b*c"),
        ("$x<y>z$", "x<y>z"),
        ("$a `b` c$", "a `b` c"),
        (#"$a\$b$"#, #"a\$b"#),
    ])
    func inlineTeXIsTheSourceBetweenTheDelimiters(source: String, tex: String) {
        let html = MarkdownRenderer.render(source)
        #expect(Self.math(in: html).map(\.tex) == [tex])
        // CommonMark never got at it: no emphasis, no inline HTML, no code span.
        #expect(!html.contains("<em>"))
        #expect(!html.contains("<code>"))
        #expect(!html.contains("<y>"))
    }

    @Test func aMultiLineDisplayBlockKeepsItsLinesVerbatim() {
        let html = MarkdownRenderer.render("$$\na \\\\ b\n$$\n")
        #expect(Self.math(in: html).map(\.tex) == ["\na \\\\ b\n"])
    }

    // MARK: What is not math

    @Test(arguments: [
        #"\$5 costs"#, "$5 and $6", "`$x$`", "    $x$ indented\n", "```\n$x$\n```\n", "[a](x$y$z)",
        "no dollars at all",
    ])
    func nonMathRendersAsItAlwaysDid(source: String) {
        let html = MarkdownRenderer.render(source)
        #expect(Self.math(in: html).isEmpty)
        #expect(!html.contains("math-inline"))
        #expect(!html.contains("math-block"))
    }

    // MARK: data-line

    @Test func lineNumbersAfterADisplayBlockAreUnchanged() {
        let withMath = MarkdownRenderer.render("a\n\n$$\nx\n$$\n\nb\n\n# c\n")
        let withoutMath = MarkdownRenderer.render("a\n\n```\nx\n```\n\nb\n\n# c\n")
        #expect(Self.lines(of: withMath, forClass: "math-block") == ["3"])
        // Everything below the block sits on the same lines as with an ordinary fence there.
        for html in [withMath, withoutMath] {
            #expect(html.contains("<p data-line=\"7\">b</p>"))
            #expect(html.contains("data-line=\"9\">c</h1>"))
        }
    }

    @Test func frontMatterStillOffsetsTheLinesOfMath() {
        let html = MarkdownRenderer.render("---\ntitle: t\n---\n$$\nx\n$$\n")
        #expect(Self.lines(of: html, forClass: "math-block") == ["4"])
    }

    // MARK: The placeholder never leaks

    /// The placeholder carries a per-render nonce. It must never reach the page — not as text,
    /// not in a heading's `id`, not in a link title or an image's alt text.
    @Test func noPlaceholderOrNonceReachesTheOutput() {
        let source = """
        # Head $a$

        ![alt $x$ text](u.png), [link $y$ text](u "title $z$ here"), and $w$.

        $$
        block
        $$
        """
        let html = MarkdownRenderer.render(source)
        #expect(!html.unicodeScalars.contains("\u{E000}"))
        #expect(!html.unicodeScalars.contains("\u{E001}"))
        // Alt text and titles keep the dollars as written: they are never expanded there.
        #expect(html.contains(#"alt="alt $x$ text""#))
        #expect(html.contains(#"title="title $z$ here""#))
    }

    /// The nonce is fresh per render, so a heading's `id` would move on every keystroke if the
    /// slug were taken from the placeholder. It has to be stable.
    @Test func headingSlugsWithMathAreStableAcrossRenders() {
        let source = "# Head $a$\n"
        let first = MarkdownRenderer.render(source)
        let second = MarkdownRenderer.render(source)
        #expect(first == second)
        #expect(first.contains(#"<h1 id="head-""#))
    }

    // MARK: Nothing else moved

    /// Ordinary documents are not just equal to themselves: they go down the same path as
    /// before, because a body with no `$` in it is never scanned. (`RendererDigestTests` is the
    /// wide version of this.)
    @Test func documentsWithoutDollarsAreNotScanned() {
        var generator = SystemRandomNumberGenerator()
        let body = "# Title\n\nSome *text* with `code` and [a link](https://example.com).\n"
        let extraction = MathExtractor.extract(from: body, using: &generator)
        #expect(extraction.markdown == body)
        #expect(extraction.expressionCount == 0)
    }
}

/// `preview.js`'s KaTeX options are frozen (S5-1): a later edit must not be able to turn
/// `trust` on, raise `maxExpand`, or add a shared `macros` object, without this failing.
struct PreviewMathOptionsTests {
    static var previewScript: String {
        get throws {
            let url = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/MarsDawnKit/Resources/Preview/preview.js")
            return try String(contentsOf: url, encoding: .utf8)
        }
    }

    /// The script without its whole-line comments, so "this file must not contain X" is about
    /// the code and not about a comment that names X to say it is not used.
    static func code(_ script: String) -> String {
        script.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// Exactly these options, in this order, and nothing else.
    static let expected = [
        "throwOnError: false,",
        "trust: false,",
        "strict: \"ignore\",",
        "maxExpand: 1000,",
        "maxSize: 50,",
        "output: \"htmlAndMathml\",",
    ]

    @Test func theOptionObjectIsExactlyTheFrozenSet() throws {
        let script = Self.code(try Self.previewScript)
        let start = try #require(script.range(of: "const mathOptions = Object.freeze({\n"))
        let end = try #require(script.range(of: "\n  });", range: start.upperBound..<script.endIndex))
        let body = script[start.upperBound..<end.lowerBound]
        let entries = body.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(entries == Self.expected)
    }

    /// The only call, and the only thing added to the frozen set, is the display mode.
    @Test func theOnlyRenderCallSpreadsTheFrozenSetAndAddsOnlyTheDisplayMode() throws {
        let script = Self.code(try Self.previewScript)
        let calls = script.components(separatedBy: "katex.render(").count - 1
        #expect(calls == 1)
        #expect(script.contains("katex.render(tex, el, { ...mathOptions, displayMode });"))
        // Named twice: where it is frozen, and where it is spread. No second options object,
        // and nothing named `macros`, so no expansion can leak from one expression to the next.
        #expect(script.components(separatedBy: "mathOptions").count - 1 == 2)
        #expect(script.contains("macros") == false)
    }

    /// The display mode comes from the class list, never from an attribute (S5-5), and the TeX
    /// comes from `textContent`, never from `innerHTML`.
    @Test func nothingIsReadFromAnAttributeAndNoInnerHTMLIsSetFromTeX() throws {
        let script = try Self.previewScript
        let math = try #require(script.range(of: "// MARK: Math"))
        let end = try #require(script.range(of: "async function renderMermaid", range: math.upperBound..<script.endIndex))
        let section = Self.code(String(script[math.lowerBound..<end.lowerBound]))
        #expect(section.contains("el.classList.contains(\"math-block\") || el.classList.contains(\"math-display\")"))
        #expect(section.contains("const tex = el.textContent;"))
        #expect(section.contains("getAttribute") == false)
        #expect(section.contains("dataset") == false)
        #expect(section.contains("innerHTML") == false)
    }

    /// The limits from S5-4, as preview.js writes them.
    @Test func theLimitsAreTheOnesTheContractNames() throws {
        let script = try Self.previewScript
        #expect(script.contains("const maxMathLength = 10000;"))
        #expect(script.contains("const maxMathPerUpdate = 2000;"))
    }

    /// `:not()` binds to one compound selector: `".math-inline, .math-block:not(.math-done)"`
    /// leaves every inline expression pending, so each update feeds KaTeX its own output back.
    /// That is what this spelling, and the exporter's copy of it, have to keep saying.
    @Test func thePendingSelectorExcludesDoneElementsOfBothKinds() throws {
        let script = Self.code(try Self.previewScript)
        #expect(script.contains(
            #"const pendingMathSelector = ".math-inline:not(.math-done), .math-block:not(.math-done)";"#
        ))
    }
}
