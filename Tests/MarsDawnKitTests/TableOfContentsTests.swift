import Testing
@testable import MarsDawnKit

/// HackMD's `[TOC]` (#132).
struct TableOfContentsTests {
    private func render(_ markdown: String) -> String {
        MarkdownRenderer.render(markdown)
    }

    @Test func nestsByLevel() {
        let html = render("[TOC]\n\n# A\n\n## B\n\n## C\n\n# D\n")
        #expect(html.hasPrefix("""
        <div class="toc" data-line="1">
        <ul>
        <li><a href="#a">A</a>
        <ul>
        <li><a href="#b">B</a></li>
        <li><a href="#c">C</a></li>
        </ul>
        </li>
        <li><a href="#d">D</a></li>
        </ul>
        </div>

        """))
    }

    @Test func aSkippedLevelNestsOnce() {
        let html = render("[toc]\n\n# A\n\n### C\n\n## B\n\n#### D\n")
        #expect(html.hasPrefix("""
        <div class="toc" data-line="1">
        <ul>
        <li><a href="#a">A</a>
        <ul>
        <li><a href="#c">C</a></li>
        </ul>
        <ul>
        <li><a href="#b">B</a>
        <ul>
        <li><a href="#d">D</a></li>
        </ul>
        </li>
        </ul>
        </li>
        </ul>
        </div>

        """))
    }

    @Test func aFirstHeadingDeeperThanTheRestIsFine() {
        let html = render("[TOC]\n\n### A\n\n# B\n")
        #expect(html.contains("<li><a href=\"#a\">A</a></li>\n<li><a href=\"#b\">B</a></li>\n</ul>\n</div>"))
    }

    @Test func linksUseTheIDsTheHeadingsHave() {
        let html = render("[TOC]\n\n# Same\n\n# Same\n\n## Same\n")
        #expect(html.contains(##"<a href="#same">Same</a>"##))
        #expect(html.contains(##"<a href="#same-1">Same</a>"##))
        #expect(html.contains(##"<a href="#same-2">Same</a>"##))
        #expect(html.contains(#"<h1 id="same-1""#))
    }

    @Test func titlesAreEscapedPlainText() {
        let html = render("[TOC]\n\n# 1 < 2 & *b* \"q\" `<d>`\n")
        #expect(html.contains(##">1 &lt; 2 &amp; b “q” &lt;d&gt;</a>"##))
    }

    @Test func aDocumentWithNoHeadingsGetsAnEmptyContainer() {
        #expect(render("[TOC]\n") == "<div class=\"toc\" data-line=\"1\">\n</div>\n")
    }

    @Test func frontMatterIsNotInTheContents() {
        let html = render("---\ntitle: T\n# not: heading\n---\n\n[TOC]\n\n# Real\n")
        #expect(html.contains(##"<a href="#real">Real</a>"##))
        #expect(!html.contains(##"href="#not"##))
    }

    @Test func otherUsesStayAsTheyWere() {
        for source in ["see [TOC] here", "`[TOC]`", "[TOC](x)", "**[TOC]**", "> quoted\n\n    [TOC]", "```\n[TOC]\n```", "[TOC]: /url\n\n[TOC]"] {
            #expect(!render(source + "\n\n# H\n").contains("class=\"toc\""), "\(source)")
        }
        #expect(render("see [TOC] here\n").contains("see [TOC] here"))
    }

    @Test func onlyTheFirstMarkerIsExpanded() {
        let html = render("[TOC]\n\n[TOC]\n\n# H\n")
        #expect(html.components(separatedBy: "class=\"toc\"").count == 2)
        #expect(html.contains("<p data-line=\"3\">[TOC]</p>"))
    }
}
