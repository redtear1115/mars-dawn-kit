#if os(macOS)
import Foundation
import Testing
import WebKit
@testable import MarsDawnKit

/// A missing Preview folder must cost the preview, not the app (app #6): the handler used to
/// force-unwrap the bundle lookup, so an install or OS update that broke it trapped as soon as the
/// first preview was built.
@MainActor
@Suite(.serialized)
struct PreviewResourceTests {
    /// Waits for the page load to finish or fail.
    final class NavigationProbe: NSObject, WKNavigationDelegate {
        var result: String?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { result = "finished" }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { result = "failed" }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
            result = "failed"
        }
    }

    private func load(with handler: PreviewSchemeHandler) async throws -> String? {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(handler, forURLScheme: PreviewSchemeHandler.scheme)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        let probe = NavigationProbe()
        webView.navigationDelegate = probe
        webView.load(URLRequest(url: PreviewSchemeHandler.pageURL(theme: .dawn)))
        let deadline = ContinuousClock.now + .seconds(15)
        while probe.result == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        return probe.result
    }

    /// The instrument can report a positive: the real bundle's page loads.
    @Test func theBundledPageLoads() async throws {
        #expect(try await load(with: PreviewSchemeHandler()) == "finished")
    }

    /// No Preview folder: building the handler doesn't trap, and the page load fails cleanly,
    /// which is what the app's preview failure view is driven by.
    @Test func aMissingPreviewFolderFailsThePageInsteadOfTrapping() async throws {
        let handler = PreviewSchemeHandler(rootURL: nil)
        #expect(try await load(with: handler) == "failed")
    }
}
#endif
