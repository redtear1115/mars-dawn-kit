import Foundation
import Testing
@testable import MarsDawnKit

/// The page's filter must cover everything the renderer renames, and the two tags the renderer
/// leaves alone but the page must not hold.
struct PreviewScriptFilterListTests {
    @Test func previewScriptRemovesEveryNeutralizedTag() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MarsDawnKit/Resources/Preview/preview.js")
        let script = try String(contentsOf: url, encoding: .utf8)
        let line = try #require(script.split(separator: "\n").first { $0.contains("const blockedElements = ") })
        let list = try #require(line.split(separator: "\"").dropFirst().first)
        let names = Set(list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        #expect(names.isSuperset(of: neutralizedRawHTMLTags))
        #expect(names.isSuperset(of: ["meta", "base"]))
    }
}

#if os(macOS)
import AppKit
import WebKit

/// `preview.js` drops connection- and document-creating elements from the fragment before it
/// reaches the page, whatever the renderer produced. Run against the real preview page.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct PreviewDOMFilterTests {
    /// Elements the page must never hold outside its own `<head>`.
    static let blockedSelector = "link, meta, base, iframe, frame, object, embed, portal, fencedframe"

    /// The page's own stylesheets (themes.css and preview.css) and meta tags.
    static let pageStylesheets = 2
    static let pageMetaTags = 3

    private func loadedPreview() async throws -> PreviewWKWebView {
        let webView = PreviewWKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 400),
                                       configuration: PreviewWebView.makeConfiguration())
        webView.applyContentRuleList(try await PreviewContentRules.ruleList(allowRemoteImages: false))
        #expect(webView.load(URLRequest(url: PreviewSchemeHandler.pageURL(theme: .dawn))) != nil)
        let deadline = ContinuousClock.now + .seconds(20)
        while webView.isLoading, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!webView.isLoading)
        // The page starts with only its own stylesheets and meta tags.
        #expect(try await count(of: "link", in: webView) == Self.pageStylesheets)
        #expect(try await count(of: "meta", in: webView) == Self.pageMetaTags)
        return webView
    }

    private func count(of selector: String, in webView: WKWebView, root: String = "document") async throws -> Int {
        let value = try await webView.callAsyncJavaScript(
            "return \(root).querySelectorAll(selector).length;",
            arguments: ["selector": selector], contentWorld: .page
        )
        return value as? Int ?? -1
    }

    private func update(_ html: String, in webView: PreviewWKWebView) async throws {
        _ = try await webView.evaluateJavaScript(PreviewWebView.updateScript(html: html, lineCount: 40))
        _ = try? await webView.callAsyncJavaScript("return await MarsDawn.idle();", contentWorld: .page)
    }

    /// Raw HTML that would create every element the page bans, plus the code-span vector from the
    /// bug report.
    static let hostileMarkdown = """
    <link rel=dns-prefetch href=//tracker.example>

    <iframe src="https://tracker.example"></iframe>

    <meta http-equiv="refresh" content="0;url=https://tracker.example">

    <base href="https://tracker.example/">

    <object data="https://tracker.example"></object><embed src="https://tracker.example"><frame src="x"><portal src="y"><fencedframe src="z">

    Text with `\u{0600}<link rel=dns-prefetch href=//x.tld>` in a code span.

    ## A heading

    Ordinary text.
    """

    /// A fragment as if the renderer had been bypassed: real elements, including inside an
    /// `<svg>` and below the top level.
    static let bypassFragment = """
    <link rel="dns-prefetch" href="//tracker.example">
    <div class="html-block"><meta http-equiv="refresh" content="0;url=https://tracker.example">\
    <base href="https://tracker.example/"><iframe src="https://tracker.example"></iframe>\
    <object data="https://tracker.example"></object><embed src="https://tracker.example">\
    <frame src="x"><portal src="y"><fencedframe src="z">\
    <svg><foreignObject><link rel="stylesheet" href="https://tracker.example/x.css"></foreignObject></svg></div>
    <p data-line="9">kept</p>
    """

    @Test func renderedHostileMarkdownAddsNoBlockedElement() async throws {
        let webView = try await loadedPreview()
        let html = MarkdownRenderer.render(Self.hostileMarkdown)
        // The renderer already renamed the tags; the page must agree.
        #expect(html.contains("<x-md-link"))
        #expect(html.contains("<x-md-iframe"))
        // (Checked on bytes: the Prepend scalar and the '&' are one Character, so `contains`
        // would not find this substring — the very reason this hotfix exists.)
        #expect(Array(html.utf8).firstRange(of: Array("\u{0600}&lt;link rel=dns-prefetch href=//x.tld&gt;".utf8)) != nil)
        try await update(html, in: webView)

        #expect(try await count(of: "link", in: webView) == Self.pageStylesheets)
        #expect(try await count(of: "meta", in: webView) == Self.pageMetaTags)
        #expect(try await count(of: Self.blockedSelector, in: webView, root: "document.getElementById('content')") == 0)
        // The renames survive into the page, and ordinary content still renders.
        #expect(try await count(of: "x-md-link, x-md-iframe, x-md-object, x-md-embed", in: webView) > 0)
        #expect(try await count(of: "h2", in: webView) == 1)
    }

    @Test func realElementsInTheFragmentAreRemovedBeforeInsertion() async throws {
        let webView = try await loadedPreview()
        try await update(Self.bypassFragment, in: webView)

        #expect(try await count(of: "link", in: webView) == Self.pageStylesheets)
        #expect(try await count(of: "meta", in: webView) == Self.pageMetaTags)
        #expect(try await count(of: "base", in: webView) == 0)
        #expect(try await count(of: Self.blockedSelector, in: webView, root: "document.getElementById('content')") == 0)
        // Only the banned elements go; the rest of the fragment is inserted as usual.
        let kept = try await webView.callAsyncJavaScript(
            "return document.getElementById('content').textContent.trim();", contentWorld: .page
        ) as? String
        #expect(kept == "kept")
        // The page's own base URL is untouched, so relative URLs still resolve to the app scheme.
        let base = try await webView.evaluateJavaScript("document.baseURI") as? String
        #expect(base?.hasPrefix("\(PreviewSchemeHandler.scheme)://") == true)
    }
}
#endif
