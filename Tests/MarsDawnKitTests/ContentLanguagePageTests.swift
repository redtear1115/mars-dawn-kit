#if os(macOS)
import AppKit
import Foundation
import Testing
import WebKit
@testable import MarsDawnKit

/// kit #164 G2, G5b: the page takes the renderer's marker out, sets `#content.lang` from it and
/// from nothing else, and a Japanese render loads nothing and violates no CSP directive.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(5)))
struct ContentLanguagePageTests {
    static let japanese = "# 見出し\n\n本文はひらがなとカタカナです。\n\n| 表 | 値 |\n|---|---|\n| 直骨次 | 1 |\n"
    static let english = "# Heading\n\nPlain English text.\n"

    /// The page's own scheme handler, recording every request it is asked for.
    final class CountingPreviewHandler: NSObject, WKURLSchemeHandler {
        let inner = PreviewSchemeHandler()
        private(set) var requests: [String] = []
        func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
            requests.append(urlSchemeTask.request.url?.absoluteString ?? "?")
            inner.webView(webView, start: urlSchemeTask)
        }
        func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
            inner.webView(webView, stop: urlSchemeTask)
        }
    }

    private func loadedPreview(theme: PreviewTheme = .dawn, configuration: WKWebViewConfiguration? = nil) async throws -> PreviewWKWebView {
        let webView = PreviewWKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 800),
                                       configuration: configuration ?? PreviewWebView.makeConfiguration())
        webView.applyContentRuleList(try await PreviewContentRules.ruleList(allowRemoteImages: false))
        #expect(webView.load(URLRequest(url: PreviewSchemeHandler.pageURL(theme: theme))) != nil)
        let deadline = ContinuousClock.now + .seconds(20)
        while webView.isLoading, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!webView.isLoading)
        return webView
    }

    private func push(html: String, to webView: PreviewWKWebView) async throws {
        _ = try await webView.evaluateJavaScript(PreviewWebView.updateScript(html: html, lineCount: 10))
        _ = try? await webView.callAsyncJavaScript("return await MarsDawn.idle();", contentWorld: .page)
    }

    private func push(_ markdown: String, to webView: PreviewWKWebView) async throws {
        try await push(html: MarkdownRenderer.render(markdown), to: webView)
    }

    private func js(_ webView: WKWebView, _ body: String) async throws -> Any? {
        try await webView.callAsyncJavaScript(body, contentWorld: .page)
    }

    /// `#content`'s `lang` attribute, or nil when it has none.
    private func lang(_ webView: WKWebView) async throws -> String? {
        try await js(webView, "const c = document.getElementById('content'); return c.hasAttribute('lang') ? c.lang : null;") as? String
    }

    // MARK: G2 — set from the marker, cleared by the next update

    @Test func aJapaneseUpdateSetsLangAndTheNextOneClearsIt() async throws {
        let webView = try await loadedPreview()
        try await push(Self.japanese, to: webView)
        #expect(try await lang(webView) == "ja")
        try await push(Self.english, to: webView)
        #expect(try await lang(webView) == nil, "an English document clears it")
        try await push("---\nlang: ja-JP\n---\nEnglish body.\n", to: webView)
        #expect(try await lang(webView) == "ja-JP")
        try await push("---\nlang: zh-Hant\n---\nかなかな\n", to: webView)
        #expect(try await lang(webView) == nil, "another declared language clears it")
    }

    /// The fragment that lands is the same as the document's without a marker: same children,
    /// same first-child margin, and no trace of the marker.
    @Test func theMarkerLeavesNoTrace() async throws {
        let html = MarkdownRenderer.render(Self.japanese)
        let marker = ContentLanguageTests.marker
        #expect(html.hasPrefix(marker), "fixture: a Japanese document")
        let withMarker = try await loadedPreview()
        try await push(html: html, to: withMarker)
        let without = try await loadedPreview()
        try await push(html: String(html.dropFirst(marker.count)), to: without)
        let read = "const c = document.getElementById('content'); return c.innerHTML;"
        let a = try await js(withMarker, read) as? String
        let b = try await js(without, read) as? String
        #expect(a != nil && a == b, "children")
        let outer = try await js(withMarker, "return document.getElementById('content').outerHTML;") as? String ?? ""
        #expect(!outer.contains("md-content-lang"), "marker absent")
        #expect(outer.contains("<h1"), "positive fixture: the content landed")
        // The document's first block is still `#content`'s first child: no margin above it.
        let margin = try await js(withMarker, "return getComputedStyle(document.querySelector('#content > h1')).marginTop;") as? String
        #expect(margin == "0px", "the first block's margin-top: \(String(describing: margin))")
        // The instrument: an h1 that is not the first child does have a margin above it.
        let later = try await js(withMarker, """
            const h = document.createElement('h1'); h.textContent = 'x';
            document.getElementById('content').appendChild(h);
            const m = getComputedStyle(h).marginTop; h.remove(); return m;
            """) as? String
        #expect(later != nil && later != "0px", "instrument: a later h1's margin-top is \(String(describing: later))")
        let first = try await js(withMarker, "return document.getElementById('content').firstElementChild.tagName;") as? String
        #expect(first == "H1")
    }

    // MARK: G2 — imitations are content, never the marker

    static let imitation = "<md-content-lang data-lang=\"ja\"></md-content-lang>"
    static let imitations: [(name: String, markdown: String)] = [
        ("closes the html-block wrapper early", "</div>\(imitation)\n\nEnglish text.\n"),
        ("after a link reference definition", "[a]: https://example.com\n\n\(imitation)\n\nEnglish text.\n"),
        ("after front matter", "---\ntitle: x\n---\n\(imitation)\n\nEnglish text.\n"),
        ("inside a footnote", "English text.[^1]\n\n[^1]: \(imitation) note\n"),
    ]

    @Test func imitationsAreNotRecognised() async throws {
        let webView = try await loadedPreview()
        for (name, markdown) in Self.imitations {
            let html = MarkdownRenderer.render(markdown)
            #expect(!html.hasPrefix("<md-content-lang"), "\(name): the renderer's first node is its own: \(html.prefix(60))")
            #expect(html.contains(Self.imitation), "positive fixture (\(name)): the imitation reaches the page")
            // Start from a page that had a Japanese document, so a stale value would show too.
            try await push(Self.japanese, to: webView)
            #expect(try await lang(webView) == "ja", "\(name): precondition")
            try await push(html: html, to: webView)
            #expect(try await lang(webView) == nil, "\(name): lang stays unset")
            let count = try await js(webView, "return document.querySelectorAll('#content md-content-lang').length;") as? Int
            #expect(count == 1, "\(name): the imitation is left as content (\(String(describing: count)))")
        }
    }

    /// Hand-made fragments: only the exact shape, first, counts.
    @Test func onlyTheExactShapeAtTheVeryStartCounts() async throws {
        let webView = try await loadedPreview()
        let cases: [(String, String?)] = [
            ("<md-content-lang data-lang=\"ja\"></md-content-lang><p>x</p>", "ja"),
            (" <md-content-lang data-lang=\"ja\"></md-content-lang><p>x</p>", nil),
            ("<!--c--><md-content-lang data-lang=\"ja\"></md-content-lang><p>x</p>", nil),
            ("<md-content-lang data-lang=\"ja\" title=\"t\"></md-content-lang><p>x</p>", nil),
            ("<md-content-lang data-lang=\"ja\">x</md-content-lang><p>x</p>", nil),
            ("<md-content-lang lang=\"ja\"></md-content-lang><p>x</p>", nil),
            ("<md-content-lang data-lang=\"en\"></md-content-lang><p>x</p>", nil),
            ("<md-content-lang data-lang=\"ja&quot;x\"></md-content-lang><p>x</p>", nil),
            ("<md-content-lang data-lang=\"ja-\"></md-content-lang><p>x</p>", nil),
            ("<md-content-lang data-lang=\"ja-aaaaaaaa-bbbbbbbb-cccccccc-dddddd\"></md-content-lang><p>x</p>", nil),  // 36
            ("<md-content-lang data-lang=\"ja-aaaaaaaa-bbbbbbbb-cccccccc-ddddd\"></md-content-lang><p>x</p>",
             "ja-aaaaaaaa-bbbbbbbb-cccccccc-ddddd"),  // 35: the longest accepted
        ]
        for (html, expected) in cases {
            try await push(Self.japanese, to: webView)
            try await push(html: html, to: webView)
            #expect(try await lang(webView) == expected, "\(html)")
            let paragraphs = try await js(webView, "return document.querySelectorAll('#content > p').length;") as? Int
            #expect(paragraphs == 1, "\(html): the rest landed")
        }
    }

    /// A marker with a value the page rejects is still taken out.
    @Test func aRejectedMarkerIsStillRemoved() async throws {
        let webView = try await loadedPreview()
        try await push(html: "<md-content-lang data-lang=\"en\"></md-content-lang><p>x</p>", to: webView)
        let count = try await js(webView, "return document.querySelectorAll('md-content-lang').length;") as? Int
        #expect(count == 0)
        #expect(try await lang(webView) == nil)
    }

    // MARK: G5b — no CSP violation, no request

    @Test func aJapaneseRenderLoadsNothingAndViolatesNothing() async throws {
        for theme in [PreviewTheme.dawn, .classic, .vivid] {
            // The shipping configuration, with every request to the page's scheme and to the
            // document-asset scheme recorded. Anything else (the web) is a CSP violation.
            let pageRequests = CountingPreviewHandler(), assetRequests = RecordingSchemeHandler()
            // `makeConfiguration`'s settings, with the recording handlers in place of its own (a
            // scheme can't be given a second handler).
            let configuration = WKWebViewConfiguration()
            configuration.setURLSchemeHandler(pageRequests, forURLScheme: PreviewSchemeHandler.scheme)
            configuration.setURLSchemeHandler(assetRequests, forURLScheme: DocumentAssetSchemeHandler.scheme)
            configuration.websiteDataStore = .nonPersistent()
            configuration.defaultWebpagePreferences.allowsContentJavaScript = true
            configuration.mediaTypesRequiringUserActionForPlayback = .all
            let webView = try await loadedPreview(theme: theme, configuration: configuration)
            _ = try await js(webView, """
                window.__violations = [];
                document.addEventListener('securitypolicyviolation', (e) => window.__violations.push(e.violatedDirective + ' ' + e.blockedURI));
                return true;
                """)
            let requestsBefore = pageRequests.requests.count
            try await push(Self.japanese, to: webView)
            // Paint (a snapshot draws the page, which is when WebKit asks for the fonts the text
            // uses), let every font load start and settle, and give a violation report time to arrive.
            _ = try await webView.takeSnapshot(configuration: nil)
            _ = try await js(webView, """
                document.body.getBoundingClientRect();
                await document.fonts.ready; await new Promise((r) => setTimeout(r, 600)); await document.fonts.ready;
                await new Promise((r) => setTimeout(r, 300)); return true;
                """)
            #expect(try await lang(webView) == "ja")
            // The text was laid out with its fonts (system fallback included) before this point.
            let rendered = try await js(webView, "return document.fonts.status;") as? String
            #expect(rendered == "loaded", "\(theme.id): fonts settled: \(String(describing: rendered))")
            let violations = try await js(webView, "return window.__violations;") as? [String]
            let family = try await js(webView, "return getComputedStyle(document.querySelector('#content p')).fontFamily;") as? String
            print("G5b \(theme.id): violations \(String(describing: violations)), requests \(pageRequests.requests.dropFirst(requestsBefore)), font-family \(family ?? "?")")
            #expect(violations == [], "\(theme.id): \(String(describing: violations))")
            let added = Array(pageRequests.requests.dropFirst(requestsBefore))
            #expect(added == [], "\(theme.id): \(added)")
            #expect(assetRequests.requests.isEmpty, "\(theme.id): \(assetRequests.paths)")

            // The instruments: a font from the web is a violation, and a fetched resource is an entry.
            _ = try await js(webView, """
                const style = document.createElement('style');
                style.textContent = '@font-face { font-family: Probe; src: url(https://example.invalid/probe.woff); } #probe { font-family: Probe; }';
                document.head.appendChild(style);
                const span = document.createElement('span'); span.id = 'probe'; span.textContent = 'x';
                document.body.appendChild(span);
                await new Promise((r) => setTimeout(r, 300));
                const link = document.createElement('link'); link.rel = 'stylesheet';
                link.href = 'vendor/katex.min.css?probe=' + Date.now();
                await new Promise((r) => { link.onload = link.onerror = r; document.head.appendChild(link); setTimeout(r, 1000); });
                await new Promise((r) => setTimeout(r, 100));
                return true;
                """)
            let probeViolations = try await js(webView, "return window.__violations;") as? [String] ?? []
            #expect(probeViolations.contains { $0.contains("font-src") }, "instrument: \(probeViolations)")
            #expect(pageRequests.requests.count > requestsBefore, "instrument: a request is recorded")
        }
    }
}
#endif
