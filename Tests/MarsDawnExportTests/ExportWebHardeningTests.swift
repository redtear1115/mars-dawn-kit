#if os(macOS)
import AppKit
import Testing
import WebKit
@testable import MarsDawnExport
@testable import MarsDawnKit

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ExportWebHardeningTests {
    @Test(arguments: [false, true])
    func ruleListIsAttachedBeforeTheFirstNavigation(allowRemoteImages: Bool) async throws {
        let exporter = DocumentExporter(baseDirectory: nil, allowRemoteImages: allowRemoteImages)
        #expect(exporter.webView.firstLoad == nil)
        try await exporter.prepare(markdown: "# Export\n\nText.", theme: .dawn)

        let expected = PreviewContentRules.identifier(allowRemoteImages: allowRemoteImages)
        let first = try #require(exporter.webView.firstLoad)
        #expect(first.contentRuleListIdentifier == expected)
        #expect(first == exporter.webView.lastLoad)
        let url = try #require(first.url)
        #expect(url == PreviewSchemeHandler.pageURL(theme: .dawn, allowRemoteImages: allowRemoteImages))
    }

    @Test func exportWebViewIsHardened() {
        let exporter = DocumentExporter(baseDirectory: nil, allowRemoteImages: false)
        #expect(!exporter.webView.allowsLinkPreview)
        #expect(exporter.webView.configuration.mediaTypesRequiringUserActionForPlayback == .all)
    }

    @Test func previewWebViewRefusesToLoadWithoutRules() {
        let webView = PreviewWKWebView(frame: .zero, configuration: PreviewWebView.makeConfiguration())
        #expect(webView.load(URLRequest(url: PreviewSchemeHandler.pageURL)) == nil)
        #expect(webView.firstLoad == nil)
    }
}
#endif
