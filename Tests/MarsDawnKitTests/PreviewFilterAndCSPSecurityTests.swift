import Foundation
import Testing
@testable import MarsDawnKit

// kit #157 S3 (D-157): `script` and `noscript` join the page's element filter. Source-level check
// that the list carries them, alongside the existing superset check in PreviewScriptFilterListTests.
struct PreviewScriptNoscriptFilterListTests {
    @Test func blockedElementsListIncludesScriptAndNoscript() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MarsDawnKit/Resources/Preview/preview.js")
        let script = try String(contentsOf: url, encoding: .utf8)
        let line = try #require(script.split(separator: "\n").first { $0.contains("const blockedElements = ") })
        let list = try #require(line.split(separator: "\"").dropFirst().first)
        let names = Set(list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        #expect(names.contains("script"))
        #expect(names.contains("noscript"))
    }
}

#if os(macOS)
import AppKit
import WebKit

@MainActor
@Suite(.serialized, .timeLimit(.minutes(3)))
struct PreviewFilterAndCSPSecurityTests {
    /// A document carrying HTML and SVG `<script>` and a `<noscript>`.
    static let scriptMarkup = """
    <p data-line="1">before</p>\
    <script>window.__md157 = 1;</script>\
    <noscript><span>n</span></noscript>\
    <svg><script>window.__md157 = 1;</script></svg>\
    <p data-line="2">after</p>
    """

    static func scriptAndNoscriptCount(in webView: WKWebView) async throws -> Int {
        try await previewInt(webView, "document.getElementById('content').querySelectorAll('script, noscript').length")
    }

    // MARK: S3 — the shipping page drops both from the content.

    @Test func contentHasNoScriptOrNoscriptAfterUpdate() async throws {
        let webView = try await loadSecurityPreview(configuration: PreviewWebView.makeConfiguration())
        try await previewUpdate(Self.scriptMarkup, in: webView)
        #expect(try await Self.scriptAndNoscriptCount(in: webView) == 0)
        // Ordinary content still lands.
        #expect(try await previewInt(webView, "document.getElementById('content').querySelectorAll('p').length") == 2)
        // And nothing executed (CSP would have blocked an inline script anyway; the element is gone too).
        #expect(try await sentinel(webView) == 0)
    }

    /// Control: removing `script`/`noscript` from the filter leaves them in the content.
    @Test func removingThemFromTheFilterIsRed() async throws {
        let copy = try PreviewPageCopy(); defer { copy.cleanUp() }
        try copy.revertScriptNoscriptFilter()
        let webView = try await loadSecurityPreview(configuration: copy.makeConfiguration())
        try await previewUpdate(Self.scriptMarkup, in: webView)
        #expect(try await Self.scriptAndNoscriptCount(in: webView) >= 1)
    }

    // MARK: S4 (F10) — the CSP is exactly the expected string for each remote-image state, and it
    // is enforced.

    /// The two expected CSP strings. Hardcoded (not derived from the template) so a change to the
    /// template is caught here rather than passing against itself. They differ only in `img-src`.
    static let expectedCSPBlocked =
        "default-src 'none'; script-src marsdawn-app:; style-src marsdawn-app: 'unsafe-inline'; img-src marsdawn-app: marsdawn-asset: data: ; font-src marsdawn-app: data:; base-uri 'none'; form-action 'none'"
    static let expectedCSPRemoteAllowed =
        "default-src 'none'; script-src marsdawn-app:; style-src marsdawn-app: 'unsafe-inline'; img-src marsdawn-app: marsdawn-asset: data: https:; font-src marsdawn-app: data:; base-uri 'none'; form-action 'none'"

    static func servedCSP(allowRemoteImages: Bool) async throws -> String {
        let webView = PreviewWKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 400),
                                       configuration: PreviewWebView.makeConfiguration())
        webView.applyContentRuleList(try await PreviewContentRules.ruleList(allowRemoteImages: allowRemoteImages))
        guard webView.load(URLRequest(url: PreviewSchemeHandler.pageURL(theme: .dawn, allowRemoteImages: allowRemoteImages))) != nil else {
            throw URLError(.cancelled)
        }
        let deadline = ContinuousClock.now + .seconds(20)
        while webView.isLoading, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        return try await previewString(webView,
            "document.querySelector('meta[http-equiv=\"Content-Security-Policy\"]').getAttribute('content')")
    }

    @Test func cspMatchesExpectedForBothRemoteStates() async throws {
        #expect(try await Self.servedCSP(allowRemoteImages: false) == Self.expectedCSPBlocked)
        #expect(try await Self.servedCSP(allowRemoteImages: true) == Self.expectedCSPRemoteAllowed)
        // Only img-src differs.
        let a = Self.expectedCSPBlocked.components(separatedBy: "; ")
        let b = Self.expectedCSPRemoteAllowed.components(separatedBy: "; ")
        let differing = zip(a, b).filter { $0 != $1 }.map(\.0)
        #expect(differing.count == 1)
        #expect(differing.first?.hasPrefix("img-src") == true)
    }

    @Test func inlineHandlerIsBlockedByTheEnforcedCSP() async throws {
        let webView = try await loadSecurityPreview(configuration: PreviewWebView.makeConfiguration())
        try await previewUpdate(#"<img src="data:," onerror="window.__md157 = 1;"><p data-line="1">x</p>"#, in: webView)
        try await settleRender(webView)
        #expect(try await sentinel(webView) == 0)
    }
}
#endif
