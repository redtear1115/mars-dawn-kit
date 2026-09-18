#if os(macOS)
import AppKit
import Testing
import WebKit
@testable import MarsDawnKit

/// Loads the real preview page with separate light and dark themes and flips the web view's
/// appearance, exercising `theme-boot.js` and preview.js's `setThemes`/`darkQuery` listener
/// end to end (S2).
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct PreviewThemeSwitchTests {
    final class NavigationWaiter: NSObject, WKNavigationDelegate {
        var continuation: CheckedContinuation<Void, Error>?

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            continuation?.resume()
            continuation = nil
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }

    private func load(_ webView: PreviewWKWebView, url: URL, delegate: NavigationWaiter) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            delegate.continuation = continuation
            if webView.load(URLRequest(url: url)) == nil {
                continuation.resume(throwing: URLError(.cancelled))
            }
        }
    }

    private func dataTheme(_ webView: WKWebView) async throws -> String {
        (try await webView.evaluateJavaScript("document.documentElement.dataset.theme")) as? String ?? ""
    }

    @Test func loadingWithBothThemesAppliesTheLightOneUnderALightAppearance() async throws {
        let webView = PreviewWKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 400), configuration: PreviewWebView.makeConfiguration())
        webView.appearance = NSAppearance(named: .aqua)
        let delegate = NavigationWaiter()
        webView.navigationDelegate = delegate
        webView.applyContentRuleList(try await PreviewContentRules.ruleList(allowRemoteImages: false))

        try await load(webView, url: PreviewSchemeHandler.pageURL(lightTheme: .classic, darkTheme: .vivid), delegate: delegate)

        #expect(try await dataTheme(webView) == "classic")
    }

    @Test func schemeChangeFlipsBetweenLightAndDarkThemes() async throws {
        let webView = PreviewWKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 400), configuration: PreviewWebView.makeConfiguration())
        webView.appearance = NSAppearance(named: .aqua)
        let delegate = NavigationWaiter()
        webView.navigationDelegate = delegate
        webView.applyContentRuleList(try await PreviewContentRules.ruleList(allowRemoteImages: false))

        try await load(webView, url: PreviewSchemeHandler.pageURL(lightTheme: .classic, darkTheme: .vivid), delegate: delegate)
        #expect(try await dataTheme(webView) == "classic")

        // Flip the view's effective appearance; the page's own `prefers-color-scheme` media
        // query change listener (not this test) is what re-picks the dark theme.
        webView.appearance = NSAppearance(named: .darkAqua)
        let deadline = ContinuousClock.now + .seconds(5)
        var theme = try await dataTheme(webView)
        while theme != "vivid", ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
            theme = try await dataTheme(webView)
        }
        #expect(theme == "vivid")

        // And back, exercising the fallback direction of the same listener.
        webView.appearance = NSAppearance(named: .aqua)
        let backDeadline = ContinuousClock.now + .seconds(5)
        theme = try await dataTheme(webView)
        while theme != "classic", ContinuousClock.now < backDeadline {
            try await Task.sleep(for: .milliseconds(50))
            theme = try await dataTheme(webView)
        }
        #expect(theme == "classic")
    }

    @Test func setThemesCallScriptSwitchesTheme() async throws {
        let webView = PreviewWKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 400), configuration: PreviewWebView.makeConfiguration())
        webView.appearance = NSAppearance(named: .darkAqua)
        let delegate = NavigationWaiter()
        webView.navigationDelegate = delegate
        webView.applyContentRuleList(try await PreviewContentRules.ruleList(allowRemoteImages: false))

        // A single-id load (Quick Look style): no darkTheme query item.
        try await load(webView, url: PreviewSchemeHandler.pageURL(theme: .dawn), delegate: delegate)
        #expect(try await dataTheme(webView) == "dawn")

        _ = try await webView.evaluateJavaScript(PreviewWebView.themeScript(light: .classic, dark: .vivid))
        #expect(try await dataTheme(webView) == "vivid")
    }
}
#endif
