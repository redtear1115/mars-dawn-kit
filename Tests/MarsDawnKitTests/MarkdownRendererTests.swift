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

    /// The fallback numbers skip every slug a heading has as its own, so editing a named
    /// heading doesn't move them, unless its new slug is itself `section` or `section-N`.
    @Test func sectionIDsDontMoveWhenANamedHeadingChanges() {
        let before = headingIDs(MarkdownRenderer.render("# $$\n\n# Intro\n\n# !!!\n"))
        let after = headingIDs(MarkdownRenderer.render("# $$\n\n# Introduction, rewritten\n\n# !!!\n"))
        #expect(before == ["section", "intro", "section-1"])
        #expect(after == ["section", "introduction-rewritten", "section-1"])
    }

    /// A heading with a real slug is never displaced by one without, before it or after it: an
    /// existing `#section` or `#section-1` link still lands on the heading it named (found by
    /// the verifier on #48, round 1).
    @Test func aNamedHeadingKeepsItsSlugWhateverFallsBack() {
        #expect(headingIDs(MarkdownRenderer.render("# $$\n\n# section\n\n# section-1\n"))
            == ["section-2", "section", "section-1"])
        #expect(headingIDs(MarkdownRenderer.render("# !!!\n\n# Section\n")) == ["section-1", "section"])
        #expect(headingIDs(MarkdownRenderer.render("# Section\n\n# $$\n\n# !!!\n")) == ["section", "section-1", "section-2"])
    }

    /// A repeat of a real `Section` keeps the number it had, even with empty-slug headings in
    /// between taking `section-N` (found by the verifier on #48, round 2): main gave the second
    /// "Section" `section-1`, and a link to it still lands there.
    @Test func aRepeatedRealSectionKeepsItsNumberAroundFallbacks() {
        #expect(headingIDs(MarkdownRenderer.render("# Section\n\n# $$\n\n# Section\n"))
            == ["section", "section-2", "section-1"])
        #expect(headingIDs(MarkdownRenderer.render("# !!!\n\n# a-1\n\n# !!!\n\n# Section\n\n# a\n\n# Section\n"))
            == ["section-2", "a-1", "section-3", "section", "a", "section-1"])
    }

    /// Every `id` is unique. Where main gave two headings one `id`, the heading whose own slug
    /// it is keeps it and the other repeat takes its slug's next free number: `# a`, `# a`,
    /// `# a-1` was `a`, `a-1`, `a-1` and is `a`, `a-2`, `a-1`. Every `id` main gave only once
    /// stays: `# a-1`, `# a`, `# a`, `# a` was `a-1`, `a`, `a-1`, `a-2` and is `a-1`, `a`, `a-3`,
    /// `a-2` (only the third, whose `a-1` was shared, moves).
    @Test func headingIDsStayUniqueWhenNumberedSlugsCollide() {
        #expect(headingIDs(MarkdownRenderer.render("# a\n\n# a\n\n# a-1\n")) == ["a", "a-2", "a-1"])
        #expect(headingIDs(MarkdownRenderer.render("# a-1\n\n# a\n\n# a\n\n# a\n")) == ["a-1", "a", "a-3", "a-2"])
        #expect(headingIDs(MarkdownRenderer.render("# a\n\n# a-1\n\n# a\n")) == ["a", "a-1", "a-2"])
        #expect(headingIDs(MarkdownRenderer.render("# $$\n\n# Section 1\n\n# !!!\n")) == ["section", "section-1", "section-2"])
    }

    /// The rule as properties, over 3,000 seeded random heading-only documents built the way
    /// the verifier's checker on #48 builds them. `main` is main's numbering, re-derived here:
    /// each slug numbered by occurrence, unchecked.
    /// - no `id` is empty and no two are the same;
    /// - a heading with a real slug whose `id` on main was unique has that `id`;
    /// - where main's `id` was shared, the heading whose own slug it is has it.
    @Test func headingIDsKeepEveryIDMainGaveOnlyOnce() {
        let texts: [(text: String, slug: String)] = [
            ("a", "a"), ("a-1", "a-1"), ("a-2", "a-2"), ("a-1-1", "a-1-1"), ("A!", "a"), ("section", "section"),
            ("Section 1", "section-1"), ("section-1", "section-1"), ("$$", ""), ("!!!", ""), ("b", "b"), ("*a*", "a"),
        ]
        let wraps: [(String) -> String] = [
            { "# \($0)" }, { "## \($0)" }, { "> # \($0)" }, { "- # \($0)" }, { "\($0)\n===" }, { "> > ### \($0)" },
        ]
        var generator = RendererDigestTests.SplitMix64(state: 48)
        var violations: [String] = []
        for _ in 0..<3000 {
            let picks = (0..<Int.random(in: 1...8, using: &generator)).map { _ in
                (texts.randomElement(using: &generator)!, wraps.randomElement(using: &generator)!)
            }
            let markdown = picks.map { $0.1($0.0.text) }.joined(separator: "\n\n") + "\n"
            let ids = headingIDs(MarkdownRenderer.render(markdown))
            let slugs = picks.map(\.0.slug)
            guard ids.count == slugs.count else { violations.append("count: \(markdown.debugDescription)"); continue }
            var seen: [String: Int] = [:]
            let main = slugs.map { slug -> String in
                let count = seen[slug, default: 0]
                seen[slug] = count + 1
                return count == 0 ? slug : "\(slug)-\(count)"
            }
            if ids.contains("") || Set(ids).count != ids.count { violations.append("unique: \(ids)") }
            for (index, slug) in slugs.enumerated() where !slug.isEmpty {
                let mainCount = main.filter { $0 == main[index] }.count
                if mainCount == 1, ids[index] != main[index] { violations.append("kept: \(main) → \(ids)") }
                if mainCount > 1, main[index] == slug, slugs.firstIndex(of: slug) == index, ids[index] != slug {
                    violations.append("owner: \(main) → \(ids)")
                }
            }
        }
        #expect(violations.isEmpty, "\(violations.count) violations, e.g. \(violations.prefix(3))")
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
