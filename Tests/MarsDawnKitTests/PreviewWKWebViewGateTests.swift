#if os(macOS)
import AppKit
import Foundation
import Testing
import WebKit
@testable import MarsDawnKit

/// Every loading entry point of `PreviewWKWebView` refuses to start without content rules.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct PreviewWKWebViewGateTests {
    final class NavigationRecorder: NSObject, WKNavigationDelegate {
        var decisions = 0
        var starts = 0
        var finishes = 0

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            decisions += 1
            return .allow
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            starts += 1
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            finishes += 1
        }
    }

    /// Serves a small page at any `gate-test://` URL.
    final class PageSchemeHandler: NSObject, WKURLSchemeHandler {
        static let scheme = "gate-test"

        func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
            let data = Data("<p>\(urlSchemeTask.request.url?.path ?? "")</p>".utf8)
            urlSchemeTask.didReceive(URLResponse(
                url: urlSchemeTask.request.url!, mimeType: "text/html",
                expectedContentLength: data.count, textEncodingName: "utf-8"
            ))
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        }

        func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
    }

    private func makeWebView() -> (PreviewWKWebView, NavigationRecorder) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(PageSchemeHandler(), forURLScheme: PageSchemeHandler.scheme)
        let webView = PreviewWKWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 200), configuration: configuration)
        let recorder = NavigationRecorder()
        webView.navigationDelegate = recorder
        return (webView, recorder)
    }

    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(300))
    }

    private func waitForFinishes(_ count: Int, _ recorder: NavigationRecorder, _ webView: WKWebView) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while recorder.finishes < count || webView.isLoading, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(recorder.finishes >= count)
    }

    private func expectNoNavigation(_ webView: PreviewWKWebView, _ recorder: NavigationRecorder) async throws {
        try await settle()
        #expect(recorder.decisions == 0)
        #expect(recorder.starts == 0)
        #expect(!webView.isLoading)
        #expect(webView.url == nil)
        #expect(webView.firstLoad == nil)
    }

    private static let simulatedURL = URL(string: "https://example.invalid/page.html")!

    private static func temporaryPage() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gate-\(UUID().uuidString).html")
        try Data("<p>file</p>".utf8).write(to: url)
        return url
    }

    @Test func loadRequestRefusesWithoutRules() async throws {
        let (webView, recorder) = makeWebView()
        #expect(webView.load(URLRequest(url: Self.simulatedURL)) == nil)
        try await expectNoNavigation(webView, recorder)
    }

    #if compiler(>=6.4)
    @Test func loadURLRefusesWithoutRules() async throws {
        guard #available(macOS 27.0, *) else { return }
        let (webView, recorder) = makeWebView()
        #expect(webView.load(Self.simulatedURL) == nil)
        try await expectNoNavigation(webView, recorder)
    }
    #endif

    @Test func loadHTMLStringRefusesWithoutRules() async throws {
        let (webView, recorder) = makeWebView()
        #expect(webView.loadHTMLString("<p>html</p>", baseURL: nil) == nil)
        try await expectNoNavigation(webView, recorder)
    }

    @Test func loadFileURLRefusesWithoutRules() async throws {
        let file = try Self.temporaryPage()
        defer { try? FileManager.default.removeItem(at: file) }
        let (webView, recorder) = makeWebView()
        #expect(webView.loadFileURL(file, allowingReadAccessTo: file) == nil)
        try await expectNoNavigation(webView, recorder)
    }

    @Test func loadDataRefusesWithoutRules() async throws {
        let (webView, recorder) = makeWebView()
        let navigation = webView.load(Data("<p>data</p>".utf8), mimeType: "text/html", characterEncodingName: "utf-8", baseURL: Self.simulatedURL)
        #expect(navigation == nil)
        try await expectNoNavigation(webView, recorder)
    }

    // These return a non-optional navigation in Swift, so the refusal returns an inert one.
    @Test func loadFileRequestRefusesWithoutRules() async throws {
        let file = try Self.temporaryPage()
        defer { try? FileManager.default.removeItem(at: file) }
        let (webView, recorder) = makeWebView()
        _ = webView.loadFileRequest(URLRequest(url: file), allowingReadAccessTo: file)
        try await expectNoNavigation(webView, recorder)
    }

    @Test func simulatedLoadsRefuseWithoutRules() async throws {
        let (webView, recorder) = makeWebView()
        let request = URLRequest(url: Self.simulatedURL)
        let response = HTTPURLResponse(url: Self.simulatedURL, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/html"])!
        _ = webView.loadSimulatedRequest(request, response: response, responseData: Data("<p>sim</p>".utf8))
        _ = webView.loadSimulatedRequest(request, responseHTML: "<p>sim</p>")
        try await expectNoNavigation(webView, recorder)
    }

    @available(macOS, deprecated: 12.0)
    @Test func deprecatedSimulatedLoadsRefuseWithoutRules() async throws {
        let (webView, recorder) = makeWebView()
        let request = URLRequest(url: Self.simulatedURL)
        let response = URLResponse(url: Self.simulatedURL, mimeType: "text/html", expectedContentLength: -1, textEncodingName: "utf-8")
        _ = webView.loadSimulatedRequest(request, with: response, responseData: Data("<p>sim</p>".utf8))
        _ = webView.loadSimulatedRequest(request, withResponseHTML: "<p>sim</p>")
        try await expectNoNavigation(webView, recorder)
    }

    /// Loads two pages with rules attached, then detaches them: reloads and history moves,
    /// which worked a moment earlier, must now start nothing.
    @Test func reloadsAndHistoryMovesRefuseWithoutRules() async throws {
        let (webView, recorder) = makeWebView()
        webView.applyContentRuleList(try await PreviewContentRules.ruleList(allowRemoteImages: false))
        #expect(webView.load(URLRequest(url: URL(string: "gate-test://pages/one")!)) != nil)
        try await waitForFinishes(1, recorder, webView)
        #expect(webView.load(URLRequest(url: URL(string: "gate-test://pages/two")!)) != nil)
        try await waitForFinishes(2, recorder, webView)
        // Control: with rules attached, a reload does start.
        #expect(webView.reload() != nil)
        try await waitForFinishes(3, recorder, webView)
        let backItem = try #require(webView.backForwardList.backItem)

        webView.removeContentRuleLists()
        let decisions = recorder.decisions
        let starts = recorder.starts
        let url = webView.url

        #expect(webView.reload() == nil)
        #expect(webView.reloadFromOrigin() == nil)
        #expect(webView.goBack() == nil)
        #expect(webView.goForward() == nil)
        #expect(webView.go(to: backItem) == nil)
        webView.reload(nil)
        webView.reloadFromOrigin(nil)
        webView.goBack(nil)
        webView.goForward(nil)
        #expect(webView.load(URLRequest(url: Self.simulatedURL)) == nil)

        try await settle()
        #expect(recorder.decisions == decisions)
        #expect(recorder.starts == starts)
        #expect(!webView.isLoading)
        #expect(webView.url == url)
        #expect(webView.backForwardList.backItem == backItem)
    }
}
#endif
