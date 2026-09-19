import Testing
@testable import MarsDawnKit

struct MarkdownRendererTests {
    @Test func headingsGetSlugIDsAndLineNumbers() {
        let html = MarkdownRenderer.render("# Hello World\n\n## Hello World\n")
        #expect(html.contains(#"<h1 id="hello-world" data-line="1">Hello World</h1>"#))
        #expect(html.contains(#"<h2 id="hello-world-1" data-line="3">Hello World</h2>"#))
    }

    /// The `id`s of every heading in `html`, in order.
    private func headingIDs(_ html: String) -> [String] {
        html.matches(of: /<h[1-6] id="([^"]*)"/).map { String($0.output.1) }
    }

    /// A heading with no character that survives slugging (`# $$`, `# !!!`) gets an `id`
    /// anyway (#14): Pandoc's `section`, numbered like any other repeated slug. An empty `id` is
    /// an anchor nothing can link to.
    @Test func aHeadingWithNothingToSlugGetsSection() {
        let html = MarkdownRenderer.render("# $$\n\n## !!!\n\n# Hello\n\n### …\n")
        #expect(headingIDs(html) == ["section", "section-1", "hello", "section-2"])
        #expect(!html.contains(#"id="""#))
    }

    /// The fallback numbers count headings that fell back (and any heading titled "Section"),
    /// so editing other named headings doesn't move them.
    @Test func sectionIDsDontMoveWhenANamedHeadingChanges() {
        let before = headingIDs(MarkdownRenderer.render("# $$\n\n# Intro\n\n# !!!\n"))
        let after = headingIDs(MarkdownRenderer.render("# $$\n\n# Introduction, rewritten\n\n# !!!\n"))
        #expect(before == ["section", "intro", "section-1"])
        #expect(after == ["section", "introduction-rewritten", "section-1"])
    }

    /// Every `id` is unique, even where a numbered slug meets a heading that already has that
    /// name: `Section 1` slugs to `section-1`, which a second fallback would also produce, and
    /// `a-1` is what a second `a` becomes.
    @Test func headingIDsStayUniqueWhenNumberedSlugsCollide() {
        let fallback = headingIDs(MarkdownRenderer.render("# $$\n\n# Section 1\n\n# !!!\n"))
        #expect(Set(fallback).count == fallback.count, "\(fallback)")
        #expect(fallback.allSatisfy { !$0.isEmpty })
        let named = headingIDs(MarkdownRenderer.render("# a\n\n# a-1\n\n# a\n"))
        #expect(Set(named).count == named.count, "\(named)")
        #expect(named.prefix(2) == ["a", "a-1"], "the first of each keeps its plain slug")
    }

    @Test func mermaidBlocksAreMarkedForTheDiagramRenderer() {
        let html = MarkdownRenderer.render("```mermaid\ngraph TD\n  A-->B\n```\n")
        #expect(html.contains(#"<div class="mermaid-block" data-line="1">"#))
        #expect(html.contains("A--&gt;B"))
        #expect(!html.contains("<code"))
    }

    @Test func codeBlocksCarryTheirLanguage() {
        let html = MarkdownRenderer.render("```swift\nlet a = 1 < 2\n```\n")
        #expect(html.contains(#"<pre data-line="1"><code class="language-swift">let a = 1 &lt; 2"#))
    }

    @Test func tightListsOmitParagraphs() {
        let html = MarkdownRenderer.render("- one\n- two\n")
        #expect(html.contains(#"<li data-line="1">one"#))
        #expect(!html.contains("<p"))
    }

    @Test func looseListsKeepParagraphs() {
        let html = MarkdownRenderer.render("- one\n\n- two\n")
        #expect(html.contains("<p data-line=\"1\">one</p>"))
    }

    @Test func taskListsRenderCheckboxes() {
        let html = MarkdownRenderer.render("- [x] done\n- [ ] todo\n")
        #expect(html.contains(#"class="contains-task-list""#))
        #expect(html.contains(#"<input type="checkbox" disabled checked>"#))
        #expect(html.contains(#"<input type="checkbox" disabled>"#))
    }

    @Test func tablesRenderWithAlignment() {
        let html = MarkdownRenderer.render("| a | b |\n|:--|--:|\n| 1 | 2 |\n")
        #expect(html.contains(#"<th style="text-align:left">a</th>"#))
        #expect(html.contains(#"<td style="text-align:right">2</td>"#))
        #expect(html.contains(#"<tr data-line="3">"#))
    }

    @Test func gfmInlines() {
        let html = MarkdownRenderer.render("~~old~~ **bold** *em* `x<y`\n")
        #expect(html.contains("<del>old</del>"))
        #expect(html.contains("<strong>bold</strong>"))
        #expect(html.contains("<em>em</em>"))
        #expect(html.contains("<code>x&lt;y</code>"))
    }

    @Test func scriptURLsAreNeutralised() {
        let html = MarkdownRenderer.render("[x](javascript:alert(1)) ![y](data:image/svg+xml,abc) ![z](data:image/png;base64,AA)")
        #expect(html.contains(##"<a href="#">x</a>"##))
        #expect(html.contains(##"<img src="#" alt="y">"##))
        #expect(html.contains(#"<img src="data:image/png;base64,AA" alt="z">"#))
    }

    @Test func unknownAndObfuscatedSchemesAreNeutralised() {
        #expect(sanitizedURL("java\tscript:alert(1)", allowData: false) == "#")
        #expect(sanitizedURL("JAVA\nSCRIPT:alert(1)", allowData: false) == "#")
        #expect(sanitizedURL("file:///etc/passwd", allowData: true) == "#")
        #expect(sanitizedURL("x-custom:thing", allowData: false) == "#")
        #expect(sanitizedURL("mailto:a@b.c", allowData: false) == "mailto:a@b.c")
        #expect(sanitizedURL("#heading", allowData: false) == "#heading")
    }

    @Test func relativeLinksWithColonsInPathAreKept() {
        #expect(sanitizedURL("docs/a:b.md", allowData: false) == "docs/a:b.md")
    }

    @Test func imageSourcesGoThroughResolver() {
        let options = MarkdownRenderer.Options(resolveImageSource: { "marsdawn-asset://doc/" + $0 })
        let html = MarkdownRenderer.render("![alt](img/a.png)", options: options)
        #expect(html.contains(#"<img src="marsdawn-asset://doc/img/a.png" alt="alt">"#))
    }

    @Test func updateScriptEscapesContent() {
        let script = PreviewWebView.updateScript(html: "</script>\"\n")
        #expect(script.hasPrefix("window.MarsDawn && MarsDawn.update(\""))
        #expect(!script.contains("\n"))
    }
}

struct LineIndexTests {
    @Test func mapsOffsetsAndLines() {
        let index = LineIndex("ab\ncd\n\nef")
        #expect(index.lineCount == 4)
        #expect(index.line(containing: 0) == 1)
        #expect(index.line(containing: 2) == 1)
        #expect(index.line(containing: 3) == 2)
        #expect(index.line(containing: 6) == 3)
        #expect(index.line(containing: 7) == 4)
        #expect(index.offset(ofLine: 3) == 6)
        #expect(index.offset(ofLine: 99) == 7)
        #expect(index.offset(ofLine: 0) == 0)
    }

    @Test func scrollScriptIsSafe() {
        #expect(PreviewWebView.scrollScript(line: .nan, atEnd: false) == "window.MarsDawn && MarsDawn.scrollToLine(1.0, false);")
        #expect(PreviewWebView.updateScript(html: "x", lineCount: 3).hasSuffix(", 3);"))
    }
}
