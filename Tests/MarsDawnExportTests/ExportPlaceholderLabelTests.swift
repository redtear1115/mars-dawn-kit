#if os(macOS)
import AppKit
import Testing
import WebKit
@testable import MarsDawnExport
@testable import MarsDawnKit

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ExportPlaceholderLabelTests {
    @Test func blockedWebImagesAreLabelled() async throws {
        let exporter = DocumentExporter(baseDirectory: nil, allowRemoteImages: false)
        try await exporter.prepare(markdown: "# Export\n\n![logo](https://example.com/logo.png)\n", theme: .dawn)
        let labels = try await exporter.webView.evaluateJavaScript(
            #"[...document.querySelectorAll(".image-placeholder.remote .image-placeholder-label")].map((l) => l.textContent)"#
        ) as? [String] ?? []
        #expect(labels == ["\(KitStrings.webImage): example.com"])
        #expect(!KitStrings.webImage.isEmpty)
        // No banner text or button is sent to the export page.
        let bar = try await exporter.webView.evaluateJavaScript(#"document.getElementById("remote-images-bar").textContent"#) as? String
        #expect(bar == "")
    }

    @Test func webImageLabelIsLocalized() throws {
        let path = try #require(KitStrings.bundle.path(forResource: "zh-Hant", ofType: "lproj"))
        let bundle = try #require(Bundle(path: path))
        #expect(bundle.localizedString(forKey: "Web image", value: "missing", table: nil) == "網路圖片")
    }
}
#endif
