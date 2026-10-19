#if os(macOS)
import AppKit
import Foundation
import Testing
import WebKit
@testable import MarsDawnExport
@testable import MarsDawnKit

// kit #157 S2: export renders through the same preview page, so it inherits the page's CSP and
// element filter. Checked through the exporter's own public `webView`.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct ExportPageSecurityTests {
    /// Document content carrying HTML and SVG `<script>`, a `<noscript>` and an open `<details>`.
    static let markdown = """
    # Export

    <script>window.__md157 = 1;</script>

    <noscript><span>n</span></noscript>

    <svg><script>window.__md157 = 1;</script></svg>

    <details open><summary>More</summary><p>inside</p><script>window.__md157 = 1;</script></details>

    Text after.
    """

    static let cspScript = "document.querySelector('meta[http-equiv=\"Content-Security-Policy\"]').getAttribute('content')"

    /// The meta CSP the shipping preview page serves for a remote-image state.
    static func previewCSP(allowRemoteImages: Bool) async throws -> String {
        let webView = PreviewWKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 400),
                                       configuration: PreviewWebView.makeConfiguration())
        webView.applyContentRuleList(try await PreviewContentRules.ruleList(allowRemoteImages: allowRemoteImages))
        guard webView.load(URLRequest(url: PreviewSchemeHandler.pageURL(theme: .dawn, allowRemoteImages: allowRemoteImages))) != nil else {
            throw URLError(.cancelled)
        }
        let deadline = ContinuousClock.now + .seconds(20)
        while webView.isLoading, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        return try await webView.evaluateJavaScript(cspScript) as? String ?? ""
    }

    @Test(arguments: [false, true])
    func exportLoadsThePreviewPageWithItsCSP(allowRemoteImages: Bool) async throws {
        let exporter = DocumentExporter(baseDirectory: nil, allowRemoteImages: allowRemoteImages)
        try await exporter.prepare(markdown: Self.markdown, theme: .dawn)

        let url = try #require(exporter.webView.lastLoad?.url)
        #expect(url == PreviewSchemeHandler.pageURL(theme: .dawn, allowRemoteImages: allowRemoteImages))
        let exportCSP = try await exporter.webView.evaluateJavaScript(Self.cspScript) as? String
        #expect(exportCSP == (try await Self.previewCSP(allowRemoteImages: allowRemoteImages)))
    }

    @Test func exportedContentHoldsNoScriptAndRunsNone() async throws {
        let exporter = DocumentExporter(baseDirectory: nil, allowRemoteImages: false)
        try await exporter.prepare(markdown: Self.markdown, theme: .dawn)
        let webView = exporter.webView

        let scripts = try await webView.evaluateJavaScript(
            "document.getElementById('content').querySelectorAll('script, noscript').length") as? Int
        #expect(scripts == 0)
        // Nothing set the sentinel (it was never defined by the page, so it stays undefined).
        let sentinel = try await webView.evaluateJavaScript("typeof window.__md157") as? String
        #expect(sentinel == "undefined")
        // The ordinary content and the opened details block are there.
        let text = try await webView.evaluateJavaScript("document.getElementById('content').textContent") as? String ?? ""
        #expect(text.contains("Text after."))
        #expect(text.contains("inside"))
    }

    @Test func pdfIsProduced() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("md157-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("out.pdf")
        let result = try await DocumentExporter.exportPDF(
            markdown: Self.markdown, to: output, theme: .dawn, baseDirectory: nil, allowRemoteImages: false)
        #expect(result.pageCount >= 1)
        let head = try Data(contentsOf: output).prefix(5)
        #expect(head == Data("%PDF-".utf8))
    }
}
#endif
