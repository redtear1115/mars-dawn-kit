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
