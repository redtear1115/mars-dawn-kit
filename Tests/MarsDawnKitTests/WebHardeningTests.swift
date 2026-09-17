import Foundation
import Testing
@testable import MarsDawnKit

/// `<link rel=dns-prefetch>` and `rel=preconnect` connect past the CSP and the content rules,
/// so raw HTML must never produce a real `link` element.
struct LinkTagNeutralizationTests {
    private func render(_ markdown: String) -> String {
        MarkdownRenderer.render(markdown)
    }

    private func hasLinkTag(_ html: String) -> Bool {
        html.range(of: #"</?link[\t\n\f\r />]"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    @Test func uppercaseBlockTagIsRenamed() {
        let html = render(#"<LINK rel="preconnect" href="https://tracker.example">"#)
        #expect(html.contains(#"<x-md-link rel="preconnect" href="https://tracker.example">"#))
        #expect(!hasLinkTag(html))
    }

    @Test func slashAfterTagNameIsRenamed() {
        // Inside a raw HTML block, the browser reads `/rel=...` as an attribute.
        let block = render("<div>\n<link/rel=dns-prefetch href=//tracker.example>\n</div>\n")
        #expect(block.contains("<x-md-link/rel=dns-prefetch href=//tracker.example>"))
        #expect(!hasLinkTag(block))

        let selfClosing = render("<link/>\n\nText <link/> here.")
        #expect(selfClosing.contains(#"<div class="html-block" data-line="1"><x-md-link/>"#))
        #expect(selfClosing.contains("Text <x-md-link/> here."))
        #expect(!hasLinkTag(selfClosing))

        // Not HTML to the Markdown parser, so it is escaped text.
        let text = render("<link/rel=dns-prefetch href=//tracker.example>")
        #expect(text.contains("&lt;link/rel=dns-prefetch"))
    }

    @Test func newlineAfterTagNameIsRenamed() {
        let html = render("<link\nrel=\"dns-prefetch\"\nhref=\"https://tracker.example\">\n")
        #expect(html.contains("<x-md-link\nrel=\"dns-prefetch\""))
        #expect(!hasLinkTag(html))
    }

    @Test func tabAndFormFeedAfterTagNameAreRenamed() {
        let html = render("Text <lInK\trel=preconnect href=https://a.example> and <link\u{0C}rel=preconnect href=https://b.example>.")
        #expect(html.contains("<x-md-link\trel=preconnect"))
        #expect(html.contains("<x-md-link\u{0C}rel=preconnect"))
        #expect(!hasLinkTag(html))
    }

    @Test func endTagIsRenamed() {
        let html = render("<link rel=preconnect href=https://tracker.example></link>")
        #expect(html.contains("</x-md-link>"))
        #expect(!hasLinkTag(html))

        let inline = render("before </LINK > after")
        #expect(inline.contains("before </x-md-link > after"))
        #expect(!hasLinkTag(inline))
    }

    @Test func inlineTagIsRenamed() {
        let html = render(#"Some text <link rel="preconnect" href="https://tracker.example"> more text."#)
        #expect(html.contains(#"Some text <x-md-link rel="preconnect" href="https://tracker.example"> more text."#))
        #expect(!hasLinkTag(html))
    }

    @Test func entityEncodedAttributesAreKeptButTheTagIsRenamed() {
        let source = #"<link rel="dns&#45;prefetch" href="&#x68;ttps&#58;//tracker.example">"#
        let html = render(source)
        #expect(html.contains(#"<x-md-link rel="dns&#45;prefetch" href="&#x68;ttps&#58;//tracker.example">"#))
        #expect(!hasLinkTag(html))
    }

    @Test func linkTextInCodeStaysEscaped() {
        let span = render("Use `<link rel=preconnect href=https://x.example>` sparingly.")
        #expect(span.contains("<code>&lt;link rel=preconnect href=https://x.example&gt;</code>"))
        #expect(!span.contains("x-md-link"))

        let fenced = render("```html\n<link rel=\"preconnect\" href=\"https://x.example\">\n</link>\n```\n")
        #expect(fenced.contains("&lt;link rel=\"preconnect\" href=\"https://x.example\"&gt;\n&lt;/link&gt;"))
        #expect(!fenced.contains("x-md-link"))
    }

    @Test func longerTagNamesAreLeftAlone() {
        let inline = render("A <linkfoo> tag and <link-card> too.")
        #expect(inline.contains("A <linkfoo> tag and <link-card> too."))
        #expect(!inline.contains("x-md-link"))

        let block = render("<linkfoo>\n")
        #expect(block.contains("<linkfoo>"))
        #expect(!block.contains("x-md-link"))
    }

    @Test func otherRawHTMLIsUnchanged() {
        let html = render("<div class=\"note\"><a href=\"https://example.com\">link</a> <img src=\"a.png\"></div>\n")
        #expect(html.contains("<div class=\"note\"><a href=\"https://example.com\">link</a> <img src=\"a.png\"></div>"))
    }
}

/// Tags that create nested documents are renamed like `<link`, so an `<iframe srcdoc>` can't
/// hide a preconnect from the rename.
struct FrameTagNeutralizationTests {
    static let frameTags = ["iframe", "frame", "object", "embed", "portal", "fencedframe"]

    private func hasRealTag(_ html: String, _ name: String) -> Bool {
        html.range(of: "</?\(name)[\t\n\u{0C}\r />]", options: [.regularExpression, .caseInsensitive]) != nil
    }

    @Test(arguments: frameTags)
    func blockTagsAreRenamedInAnyCase(_ name: String) {
        for written in [name, name.uppercased()] {
            let html = MarkdownRenderer.render("<\(written) data-x=\"1\"></\(written)>\n")
            #expect(html.contains("<x-md-\(name) data-x=\"1\"></x-md-\(name)>"), "\(html)")
            #expect(!hasRealTag(html, name))
        }
    }

    @Test(arguments: frameTags)
    func slashWhitespaceAndClosingVariantsAreRenamed(_ name: String) {
        let upper = name.uppercased()
        let block = MarkdownRenderer.render("<div>\n<\(name)/src=x>\n<\(upper)\tsrc=y>\n<\(name)\nsrc=z>\n</\(upper) >\n</div>\n")
        #expect(block.contains("<x-md-\(name)/src=x>"))
        #expect(block.contains("<x-md-\(name)\tsrc=y>"))
        #expect(block.contains("<x-md-\(name)\nsrc=z>"))
        #expect(block.contains("</x-md-\(name) >"))
        #expect(!hasRealTag(block, name))

        let inline = MarkdownRenderer.render("Text <\(upper) src=\"a\"/> and </\(name)> end.")
        #expect(inline.contains("Text <x-md-\(name) src=\"a\"/> and </x-md-\(name)> end."))
        #expect(!hasRealTag(inline, name))
    }

    @Test func srcdocFrameIsRenamedAndItsEncodedTextKept() {
        let source = #"<iframe srcdoc="&lt;link rel=preconnect href=&quot;https://tracker.example/&quot;&gt;"></iframe>"#
        let html = MarkdownRenderer.render(source)
        #expect(html.contains(#"<x-md-iframe srcdoc="&lt;link rel=preconnect href=&quot;https://tracker.example/&quot;&gt;"></x-md-iframe>"#))
        #expect(!hasRealTag(html, "iframe"))
    }

    /// Longer tag names aren't these tags: the name must end at whitespace, `/` or `>`.
    @Test func lookalikeTagNamesAreLeftAlone() {
        let inline = MarkdownRenderer.render("A <iframes> <frameset> <objective> <embedded> <portals> <fencedframes> <iframe-card> </frameset> tag.")
        #expect(inline.contains("A <iframes> <frameset> <objective> <embedded> <portals> <fencedframes> <iframe-card> </frameset> tag."))
        #expect(!inline.contains("x-md-"))

        let block = MarkdownRenderer.render("<frameset cols=\"50%\">\n</frameset>\n")
        #expect(block.contains("<frameset cols=\"50%\">"))
        #expect(!block.contains("x-md-"))
    }

    @Test func frameTagsInCodeStayEscaped() {
        let span = MarkdownRenderer.render("Use `<iframe src=x>` or `<OBJECT data=y>`.")
        #expect(span.contains("<code>&lt;iframe src=x&gt;</code>"))
        #expect(span.contains("<code>&lt;OBJECT data=y&gt;</code>"))
        #expect(!span.contains("x-md-"))

        let fenced = MarkdownRenderer.render("```html\n<iframe srcdoc=\"x\"></iframe>\n<embed src=y>\n```\n")
        #expect(fenced.contains("&lt;iframe srcdoc=\"x\"&gt;&lt;/iframe&gt;\n&lt;embed src=y&gt;"))
        #expect(!fenced.contains("x-md-"))
    }

    /// Ordinary Markdown renders exactly as it did before the rename covered frame tags.
    @Test func ordinaryMarkdownIsUnchanged() {
        #expect(MarkdownRenderer.render(Self.sample) == Self.sampleHTML)
    }

    static let sample = #"""
        # Mars Dawn *preview*
        
        A paragraph with **bold**, _emphasis_, ~~strike~~, `inline <code>`, a [link](https://example.com "Title") and an ![image](img/rover.png).
        
        ## Lists
        
        - one
        - two with <kbd>Ctrl</kbd>
          1. nested
          2. items
        
        - [x] done
        - [ ] todo
        
        > A quote with a <abbr title="frame">frame</abbr> word.
        
        | Feature | Frame | Object |
        |:--|:-:|--:|
        | iframe text | `<iframe>` | embedded |
        
        ```swift
        let iframe = "<iframe src=x>"
        ```
        
        ```mermaid
        graph TD
          A-->B
        ```
        
        <details><summary>More</summary>
        
        Hidden <span class="x">text</span>, objective and embedded words.
        
        </details>
        
        <img src="https://example.com/a.png" alt="remote">

        """#

    static let sampleHTML = #"""
        <h1 id="mars-dawn-preview" data-line="1">Mars Dawn <em>preview</em></h1>
        <p data-line="3">A paragraph with <strong>bold</strong>, <em>emphasis</em>, <del>strike</del>, <code>inline &lt;code&gt;</code>, a <a href="https://example.com" title="Title">link</a> and an <img src="img/rover.png" alt="image">.</p>
        <h2 id="lists" data-line="5">Lists</h2>
        <ul class="contains-task-list" data-line="7">
        <li data-line="7">one
        </li>
        <li data-line="8">two with <kbd>Ctrl</kbd>
        <ol data-line="9">
        <li data-line="9">nested
        </li>
        <li data-line="10">items
        </li>
        </ol>
        </li>
        <li class="task-list-item" data-line="12"><input type="checkbox" disabled checked> done
        </li>
        <li class="task-list-item" data-line="13"><input type="checkbox" disabled> todo
        </li>
        </ul>
        <blockquote data-line="15">
        <p data-line="15">A quote with a <abbr title="frame">frame</abbr> word.</p>
        </blockquote>
        <table data-line="17">
        <thead>
        <tr data-line="17"><th style="text-align:left">Feature</th><th style="text-align:center">Frame</th><th style="text-align:right">Object</th></tr>
        </thead>
        <tbody>
        <tr data-line="19"><td style="text-align:left">iframe text</td><td style="text-align:center"><code>&lt;iframe&gt;</code></td><td style="text-align:right">embedded</td></tr>
        </tbody>
        </table>
        <pre data-line="21"><code class="language-swift">let iframe = "&lt;iframe src=x&gt;"
        </code></pre>
        <div class="mermaid-block" data-line="25"><pre class="mermaid-source">graph TD
          A--&gt;B
        </pre></div>
        <div class="html-block" data-line="30"><details><summary>More</summary>
        </div>
        <p data-line="32">Hidden <span class="x">text</span>, objective and embedded words.</p>
        <div class="html-block" data-line="34"></details>
        </div>
        <div class="html-block" data-line="36"><img src="https://example.com/a.png" alt="remote">
        </div>

        """#
}

struct PreviewContentRulesTests {
    private func rules(allowRemoteImages: Bool) throws -> [[String: Any]] {
        let json = PreviewContentRules.encodedRules(allowRemoteImages: allowRemoteImages)
        return try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
    }

    private static func block(_ filter: String) -> NSDictionary {
        ["trigger": ["url-filter": filter], "action": ["type": "block"]]
    }

    private static func allowImages(_ filter: String) -> NSDictionary {
        ["trigger": ["url-filter": filter, "resource-type": ["image"]], "action": ["type": "ignore-previous-rules"]]
    }

    @Test func blockedStateBlocksEveryWebRequest() throws {
        let rules = try rules(allowRemoteImages: false).map { $0 as NSDictionary }
        #expect(rules == [Self.block("^https?:"), Self.block("^wss?:")])
    }

    @Test func allowedStateBlocksEveryWebRequestExceptImages() throws {
        // Order matters: the image exceptions must come after the blocks they lift.
        let rules = try rules(allowRemoteImages: true).map { $0 as NSDictionary }
        #expect(rules == [
            Self.block("^https?:"), Self.block("^wss?:"),
            Self.allowImages("^https?:"), Self.allowImages("^wss?:"),
        ])
    }

    @Test func identifiersAreVersionedAndDistinct() {
        let blocked = PreviewContentRules.identifier(allowRemoteImages: false)
        let allowed = PreviewContentRules.identifier(allowRemoteImages: true)
        #expect(blocked != allowed)
        #expect(blocked.contains(".v\(PreviewContentRules.version)."))
        #expect(allowed.contains(".v\(PreviewContentRules.version)."))
    }
}

import WebKit

@MainActor
struct PreviewContentRuleCompileTests {
    @Test func bothListsCompile() async throws {
        for allowRemoteImages in [false, true] {
            let list = try await PreviewContentRules.ruleList(allowRemoteImages: allowRemoteImages)
            #expect(list.identifier == PreviewContentRules.identifier(allowRemoteImages: allowRemoteImages))
            // Cached after the first compile.
            #expect(try await PreviewContentRules.ruleList(allowRemoteImages: allowRemoteImages) === list)
        }
    }
}
