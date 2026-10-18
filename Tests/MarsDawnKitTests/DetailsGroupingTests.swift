import Foundation
import Testing
@testable import MarsDawnKit

/// GitHub's `<details>` form (blank lines between the tags and the Markdown) renders as one
/// element (redtear1115/mars-dawn#414). These are the renderer's side of it; the DOM it makes
/// in a real page is `DetailsPageTests` and `DetailsExportPageTests`.
private func hasRealTag(_ html: String, _ name: String) -> Bool {
    html.range(of: "</?\(name)[\t\n\u{0C}\r />]", options: [.regularExpression, .caseInsensitive]) != nil
}

private func occurrences(of needle: String, in text: String) -> Int {
    text.components(separatedBy: needle).count - 1
}

/// Every `data-line` value, in document order.
private func dataLines(_ html: String) -> [Int] {
    let pattern = try! NSRegularExpression(pattern: #"data-line="(\d+)""#)
    let range = NSRange(html.startIndex..., in: html)
    return pattern.matches(in: html, range: range).compactMap {
        Range($0.range(at: 1), in: html).flatMap { Int(html[$0]) }
    }
}

// MARK: - A1/A2/A3/A4/A5/A6 (string level)

struct DetailsGroupingRenderTests {
    /// The fixture's `data-line` values at the base, minus the inner HTML blocks (A: 19, C: 30,
    /// G: 39, 44 and 46).
    static let expectedLines = [1, 3, 5, 7, 10, 12, 12, 13, 15, 21, 23, 25, 28, 32, 34, 37, 42, 48]

    /// A1, A2, A3 and A6: three groups, each one `div.html-block` from the opening block's line,
    /// and nothing else of the fixture touched.
    @Test func theFixtureIsThreeSingleBlocks() {
        let html = MarkdownRenderer.render(DetailsFixture.markdown)
        #expect(occurrences(of: "<div class=\"html-block\"", in: html) == 3)
        #expect(html.contains(#"<div class="html-block" data-line="7"><details>"#))
        #expect(html.contains(#"<div class="html-block" data-line="25"><details open>"#))
        #expect(html.contains(#"<div class="html-block" data-line="34"><details>"#))
        #expect(occurrences(of: "<details", in: html) == 4)
        #expect(occurrences(of: "</details>", in: html) == 4)
        // The inner Markdown is inside, in order; the paragraph after A is outside.
        let a = html.range(of: #"data-line="7">"#)!.upperBound
        let aEnd = html.range(of: "</details>\n</div>\n<p data-line=\"21\">")!
        let aBody = String(html[a..<aEnd.lowerBound])
        #expect(aBody.contains("<summary>A 補充細節</summary>"))
        for part in ["<strong>粗體</strong>", "<code>code</code>", "<ul data-line=\"12\">", "<pre data-line=\"15\">"] {
            #expect(aBody.contains(part), "\(part)")
        }
        #expect(!html.contains("&lt;/details"))
        #expect(dataLines(html) == Self.expectedLines)
    }

    /// A6: with front matter every number shifts by its length, the front matter itself is
    /// line 1, and the set is the base's minus the inner HTML blocks.
    @Test func lineNumbersWithFrontMatter() {
        let frontMatter = "---\ntitle: T\n---\n"
        let html = MarkdownRenderer.render(frontMatter + DetailsFixture.markdown)
        #expect(dataLines(html) == [1] + Self.expectedLines.map { $0 + 3 })
        #expect(html.contains("<details class=\"front-matter\""))
        #expect(occurrences(of: "<div class=\"html-block\"", in: html) == 3)
    }

    /// A6: everything outside the three groups is byte-identical to the base's output. The
    /// groups are cut out of both (the base's are the HTML blocks from each opening to its
    /// closing one) and what is left must be equal.
    @Test func outputOutsideTheGroupsIsTheBases() throws {
        let after = MarkdownRenderer.render(DetailsFixture.markdown)
        let cutAfter = try NSRegularExpression(
            pattern: #"<div class="html-block" data-line="\d+"><details.*?</details>\n</div>\n"#,
            options: [.dotMatchesLineSeparators]
        )
        let cutBase = try NSRegularExpression(
            pattern: #"<div class="html-block" data-line="(?:7|25|34)">.*?<div class="html-block" data-line="(?:19|30|46)">.*?</div>\n"#,
            options: [.dotMatchesLineSeparators]
        )
        func cut(_ regex: NSRegularExpression, _ text: String) -> String {
            regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        }
        let outsideAfter = cut(cutAfter, after)
        let outsideBase = cut(cutBase, DetailsFixture.baseHTML)
        #expect(outsideAfter == outsideBase)
        #expect(outsideAfter.contains("END-OF-FIXTURE"))
        #expect(!outsideAfter.contains("html-block"), "positive fixture: all three groups were cut out")
    }

    /// A4: no `</details>` anywhere: byte-identical to the base, and nothing after it swallowed.
    @Test func anUnclosedDetailsRendersAsBefore() {
        let html = MarkdownRenderer.render("<details>\n<summary>U</summary>\n\nU inner **bold**\n\nAfter unclosed.\n")
        #expect(html == """
            <div class="html-block" data-line="1"><details>
            <summary>U</summary>
            </div>
            <p data-line="4">U inner <strong>bold</strong></p>
            <p data-line="6">After unclosed.</p>

            """)
    }

    /// C2's wider limitation: one unclosed opening keeps the depth above zero, so a later,
    /// complete pair in the same container also renders as before.
    @Test func anUnclosedOpeningLeavesLaterPairsAsBefore() {
        let source = "<details>\n<summary>U</summary>\n\nmid\n\n<details>\n<summary>V</summary>\n\nin\n\n</details>\n\nend\n"
        let html = MarkdownRenderer.render(source)
        #expect(occurrences(of: "<div class=\"html-block\"", in: html) == 3)
        #expect(html.contains("<div class=\"html-block\" data-line=\"11\"></details>\n</div>"))
    }

    /// A5: a group inside a block quote and inside a list item.
    @Test func groupsInsideContainers() {
        let quote = MarkdownRenderer.render("> <details>\n> <summary>Q</summary>\n>\n> Quote **body**\n>\n> </details>\n\nafter\n")
        #expect(quote.contains("<blockquote data-line=\"1\">\n<div class=\"html-block\" data-line=\"1\"><details>\n<summary>Q</summary>\n<p data-line=\"4\">Quote <strong>body</strong></p>\n</details>\n</div>\n</blockquote>"))
        #expect(occurrences(of: "<div class=\"html-block\"", in: quote) == 1)

        let item = MarkdownRenderer.render("- <details>\n  <summary>L</summary>\n\n  Item **body**\n\n  </details>\n\n- next\n")
        #expect(item.contains("<li data-line=\"1\"><div class=\"html-block\" data-line=\"1\"><details>\n<summary>L</summary>\n<p data-line=\"4\">Item <strong>body</strong></p>\n</details>\n</div>\n</li>"))
        #expect(occurrences(of: "<div class=\"html-block\"", in: item) == 1)
    }

    /// A pair that opens and closes inside one block is not a group.
    @Test func aSelfContainedPairRendersAsBefore() {
        let html = MarkdownRenderer.render("<details><summary>S</summary>body</details>\n\nafter\n")
        #expect(html == "<div class=\"html-block\" data-line=\"1\"><details><summary>S</summary>body</details>\n</div>\n<p data-line=\"3\">after</p>\n")
    }

    /// A GitHub-style block with a fenced code block and a table in the middle.
    @Test func anyBlockKindFitsInTheMiddle() {
        let html = MarkdownRenderer.render("<details>\n<summary>S</summary>\n\n```swift\nlet a = 1\n```\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n> quote\n\n---\n\n# Head\n\n</details>\n")
        #expect(occurrences(of: "<div class=\"html-block\"", in: html) == 1)
        for part in ["<pre data-line=\"4\">", "<table data-line=\"8\">", "<blockquote data-line=\"12\">", "<hr data-line=\"14\">", "<h1 id=\"head\" data-line=\"16\">"] {
            #expect(html.contains(part), "\(part)")
        }
    }
}

// MARK: - A7 hardening

struct DetailsGroupingHardeningTests {
    static let tags = neutralizedRawHTMLTags
    static func mixed(_ name: String) -> String {
        name.enumerated().map { $0.offset % 2 == 0 ? $0.element.uppercased() : String($0.element) }.joined()
    }

    /// The tag in the opening block, a middle bare piece and the closing block.
    static func source(_ tag: String, wrapping prefix: (first: String, rest: String)) -> String {
        let t = mixed(tag)
        let lines = [
            "<details>", "<\(t) data-open=1>", "<summary>S</summary>", "",
            "text", "",
            "<div>", "<\(t.uppercased()) data-mid=2>", "</\(t)>", "</div>", "",
            "</details>", "</\(t.lowercased()) data-close=3>", "",
            "after",
        ]
        return lines.enumerated().map { index, line in
            (index == 0 ? prefix.first : prefix.rest) + line
        }.joined(separator: "\n") + "\n"
    }

    static let shapes: [(String, (String, String))] = [
        ("document", ("", "")), ("quote", ("> ", "> ")), ("list item", ("- ", "  ")),
    ]

    @Test(arguments: neutralizedRawHTMLTags, [0, 1, 2])
    func everyPieceIsNeutralized(_ tag: String, _ shape: Int) {
        let (label, prefix) = Self.shapes[shape]
        let html = MarkdownRenderer.render(Self.source(tag, wrapping: prefix))
        #expect(occurrences(of: "<div class=\"html-block\"", in: html) == 1, "\(label): one group\n\(html)")
        #expect(!hasRealTag(html, tag), "\(label) \(tag): \(html)")
        #expect(occurrences(of: "x-md-\(tag)", in: html.lowercased()) == 4, "\(label) \(tag): positive control\n\(html)")
    }

    /// A lookalike name is not one of the seven, inside a group as anywhere.
    @Test func lookalikeNamesAreLeftAloneInsideAGroup() {
        let html = MarkdownRenderer.render("<details>\n<iframes> <frameset>\n\n<div>\n<objective> <embedded> <portals> <fencedframes> <iframe-card>\n</div>\n\n</details>\n")
        #expect(occurrences(of: "<div class=\"html-block\"", in: html) == 1)
        #expect(html.contains("<iframes> <frameset>"))
        #expect(html.contains("<objective> <embedded> <portals> <fencedframes> <iframe-card>"))
        #expect(!html.contains("x-md-"))
    }

    @Test func tagsInCodeInsideAGroupStayEscaped() {
        let html = MarkdownRenderer.render("<details>\n<summary>S</summary>\n\nUse `<iframe src=x>` here.\n\n```html\n<object data=y></object>\n```\n\n</details>\n")
        #expect(occurrences(of: "<div class=\"html-block\"", in: html) == 1)
        #expect(html.contains("<code>&lt;iframe src=x&gt;</code>"))
        #expect(html.contains("&lt;object data=y&gt;&lt;/object&gt;"))
        #expect(!html.contains("x-md-"))
    }

    /// An inline tag in a paragraph inside a group goes through the inline path as before.
    @Test func inlineTagsInsideAGroupAreNeutralized() {
        let html = MarkdownRenderer.render("<details>\n<summary>S</summary>\n\nText <IFRAME src=a/> end.\n\n</details>\n")
        #expect(html.contains("Text <x-md-iframe src=a/> end."))
        #expect(!hasRealTag(html, "iframe"))
    }
}

// MARK: - A15 matching

struct DetailsScannerTests {
    private func depth(_ html: String, from start: Int = 0) -> Int { DetailsScanner.depth(after: html, from: start) }

    @Test(arguments: [
        "<details-card>\n",
        "<!-- <details> -->\n",
        "<!--- <details> -->\n",
        "<!-- a --> <!-- <details> -->\n",
        "<img alt=\"<details>\">\n",
        "<img alt='<details>'>\n",
        "<a title=\"x>\" data=<details>>\n",
        "<script>\"<details>\"</script>\n",
        "<STYLE>a::before { content: \"<details>\" }</style>\n",
        "<textarea><details></textarea>\n",
        "<title><details></title>\n",
        "<xmp><details></xmp>\n",
        "<noembed><details></noembed>\n",
        "<noframes><details></noframes>\n",
        "<noscript><details></noscript>\n",
        "<plaintext><details>\n",
        "<!doctype <details>>\n",
        "<?php <details> ?>\n",
        "</ <details>>\n",
        "a < details> b\n",
        "<detail>\n",
        "<detailss>\n",
    ])
    func notCounted(_ html: String) {
        #expect(depth(html) == 0, "\(html)")
    }

    @Test(arguments: [
        "<details>\n", "<DETAILS open>\n", "<details/>\n", "<details\topen=\"\">\n", "<details\nname=x>\n",
        "<pre><details></pre>\n", "<!-- c --><details>\n", "<script>x</script><details>\n",
        "<a title=\"a\"><details>\n", "<textarea></textarea ><details>\n",
        "<!-- --!><details>\n", "<!----><details>\n", "<!--> <details> -->\n", "<!---> <details>\n",
        "<!-- a --!> <details>\n", "<!-- a -- > --><details>\n",
    ])
    func counted(_ html: String) {
        #expect(depth(html) == 1, "\(html)")
    }

    @Test func closesAreCountedWhateverFollowsTheName() {
        #expect(depth("</details foo>\n", from: 1) == 0)
        #expect(depth("</details/>\n", from: 1) == 0)
        #expect(depth("</DETAILS>\n", from: 1) == 0)
        #expect(depth("</details\n>", from: 2) == 1)
        #expect(depth("</details-card>\n", from: 1) == 1)
        #expect(depth("</details x=\">\">", from: 1) == 0)
    }

    @Test func theDepthNeverGoesBelowZero() {
        #expect(depth("</details></details></details>", from: 0) == 0)
        #expect(depth("</details></details><details>", from: 0) == 1)
        #expect(depth("<details></details></details><details>", from: 0) == 1)
    }

    @Test func aBlockThatClosesAndOpensKeepsTheDepth() {
        #expect(depth("</details>\n<details>\n", from: 1) == 1)
        #expect(depth("</details>\n<details>\n<details>\n", from: 1) == 2)
    }

    @Test func rawTextEndsAtItsOwnCloseOnly() {
        #expect(depth("<script></scripts><details></script><details>", from: 0) == 1)
        #expect(depth("<script></script/><details>", from: 0) == 1)
        #expect(depth("<script>unterminated <details>", from: 0) == 0)
        #expect(depth("<style><details></STYLE\t><details>", from: 0) == 1)
    }

    @Test func truncatedInputNeverCrashes() {
        for html in ["<", "</", "<!", "<!-", "<!--", "<!---", "<details", "<details ", "<details a=", "<details a=\"", "<details a='x",
                     "<script", "<script>", "<script></", "<!--->", "<?", "</details", "<a b c d", "<a =", "<a = >"] {
            _ = depth(html)
        }
        #expect(depth("<details a=\"x") == 1, "an unterminated tag still opened it")
    }

    // MARK: Through the renderer

    private func groupCount(_ markdown: String) -> Int {
        occurrences(of: "<div class=\"html-block\"", in: MarkdownRenderer.render(markdown))
    }

    @Test func lookalikesAndHiddenOnesFormNoGroup() {
        for open in ["<details-card>", "<!-- <details> -->", "<img alt=\"<details>\">", "<script>\"<details>\"</script>"] {
            let html = MarkdownRenderer.render("\(open)\n\nmiddle\n\n</details>\n")
            #expect(occurrences(of: "<div class=\"html-block\"", in: html) == 2, "\(open): the close stands alone\n\(html)")
        }
        // A code span or fence is never HTML.
        let html = MarkdownRenderer.render("Text with `<details>` code.\n\n```\n<details>\n```\n\nmiddle\n\n</details>\n")
        #expect(occurrences(of: "<div class=\"html-block\"", in: html) == 1)
    }

    @Test func detailsInsideAPreBlockCounts() {
        #expect(groupCount("<pre><details></pre>\n\nmiddle\n\n</details>\n") == 1)
        #expect(groupCount("<details>\n<summary>S</summary>\n\nmiddle\n\n</details foo>\n") == 1)
        #expect(groupCount("<details>\n<summary>S</summary>\n\nmiddle\n\n</details/>\n") == 1)
    }

    @Test func aCloseWithNoOpeningThenAValidPair() {
        let html = MarkdownRenderer.render("</details>\n\n<details>\n<summary>S</summary>\n\nin\n\n</details>\n\nafter\n")
        #expect(occurrences(of: "<div class=\"html-block\"", in: html) == 2)
        #expect(html.hasPrefix("<div class=\"html-block\" data-line=\"1\"></details>\n</div>\n<div class=\"html-block\" data-line=\"3\"><details>\n<summary>S</summary>\n<p data-line=\"6\">in</p>\n</details>\n</div>\n"))
    }

    /// A block that closes one and opens the next continues the group, so two chained details
    /// are one wrapper (the DOM it makes is asserted in `DetailsPageTests`).
    @Test func chainedDetailsAreOneGroup() {
        let html = MarkdownRenderer.render("<details>\n<summary>One</summary>\n\nfirst\n\n</details>\n<details>\n<summary>Two</summary>\n\nsecond\n\n</details>\n\nafter\n")
        #expect(occurrences(of: "<div class=\"html-block\"", in: html) == 1)
        #expect(html.contains("</details>\n<details>\n<summary>Two</summary>"))
        #expect(html.hasSuffix("</details>\n</div>\n<p data-line=\"14\">after</p>\n"))
    }

    /// The same chain with the second never closed: everything as before.
    @Test func anUnclosedChainRendersAsBefore() {
        let html = MarkdownRenderer.render("<details>\n<summary>One</summary>\n\nfirst\n\n</details>\n<details>\n<summary>Two</summary>\n\nsecond\n\nafter\n")
        #expect(html == """
            <div class="html-block" data-line="1"><details>
            <summary>One</summary>
            </div>
            <p data-line="4">first</p>
            <div class="html-block" data-line="6"></details>
            <details>
            <summary>Two</summary>
            </div>
            <p data-line="10">second</p>
            <p data-line="12">after</p>

            """)
    }
}

// MARK: - A15 property

struct DetailsGroupingPropertyTests {
    static let pieces = [
        "<details>\n<summary>S</summary>", "<details open>", "</details>", "</details foo>", "</details>\n<details>",
        "</details><details>", "<details-card>", "<!-- <details> -->", "<img alt=\"</details>\">",
        "<script>\"<details>\"</script>", "<pre><details></pre>", "<pre>x</pre>", "<span>raw</span>", "<p>raw</p>",
        "<IFRAME src=x>", "<OBJECT data=y>", "<link rel=preconnect href=x>", "<embed src=z>",
        "text paragraph", "# heading", "- list item", "1. ordered", "> quote", "```\ncode </details>\n```",
        "| a | b |\n|---|---|\n| 1 | 2 |", "---", "    indented code", "`<details>` span", "<details>\n\n</details>",
    ]

    /// The renderer's output with wrappers removed. Pieces hold no `div`, so every `</div>\n` is
    /// the end of an HTML block's wrapper.
    static func stripped(_ html: String) -> String {
        var text = html.replacingOccurrences(of: #"<div class="html-block"( data-line="\d+")?>"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "</div>\n", with: "")
        return text.replacingOccurrences(of: #" data-line="\d+""#, with: "", options: .regularExpression)
    }

    /// Turns the ungroupable stand-in back into `details`, escaped or not.
    static func restored(_ html: String) -> String {
        html.replacingOccurrences(of: "<section", with: "<details").replacingOccurrences(of: "</section", with: "</details")
            .replacingOccurrences(of: "&lt;section", with: "&lt;details").replacingOccurrences(of: "&lt;/section", with: "&lt;/details")
    }

    /// `details` swapped for another type-6 HTML block name, which can neither group nor change
    /// how the document is cut into blocks.
    static func ungroupable(_ markdown: String) -> String {
        markdown.replacingOccurrences(of: "<details", with: "<section").replacingOccurrences(of: "</details", with: "</section")
    }

    @Test(arguments: 0..<40)
    func groupingOnlyMovesWrappers(_ seed: Int) {
        var random = RendererDigestTests.SplitMix64(state: UInt64(seed) &* 7919 &+ 1)
        var markdown = ""
        for _ in 0..<(8 + Int.random(in: 0..<24, using: &random)) {
            let piece = Self.pieces.randomElement(using: &random)!
            let prefix = Int.random(in: 0..<6, using: &random) == 0 ? "> " : (Int.random(in: 0..<8, using: &random) == 0 ? "- " : "")
            let body = prefix.isEmpty ? piece : piece.split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated().map { ($0.offset == 0 ? prefix : String(repeating: " ", count: prefix.count)) + $0.element }.joined(separator: "\n")
            markdown += body + (Bool.random(using: &random) ? "\n\n" : "\n")
        }
        let grouped = MarkdownRenderer.render(markdown)
        let plain = MarkdownRenderer.render(Self.ungroupable(markdown))
        let lhs = Self.stripped(grouped)
        let rhs = Self.restored(Self.stripped(plain))
        #expect(lhs == rhs, "seed \(seed)\n\(markdown)")
        for name in neutralizedRawHTMLTags { #expect(!hasRealTag(grouped, name), "seed \(seed) \(name)") }
    }

    /// The property above must be able to fail: a document that does group differs from the
    /// plain rendering by its wrappers, so the strip is what makes them equal.
    @Test func theGeneratorReachesGroups() {
        var grouped = 0
        for seed in 0..<40 {
            var random = RendererDigestTests.SplitMix64(state: UInt64(seed) &* 7919 &+ 1)
            var markdown = ""
            for _ in 0..<(8 + Int.random(in: 0..<24, using: &random)) {
                markdown += Self.pieces.randomElement(using: &random)! + (Bool.random(using: &random) ? "\n\n" : "\n")
            }
            if MarkdownRenderer.render(markdown) != Self.restored(MarkdownRenderer.render(Self.ungroupable(markdown))) {
                grouped += 1
            }
        }
        #expect(grouped >= 5, "positive control: \(grouped) of 40 random documents group")
    }
}
