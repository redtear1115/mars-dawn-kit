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

    /// Through the bundle's own list of localizations, not a hard-coded folder name: SwiftPM
    /// writes `zh-hant.lproj` under Xcode 26 and `zh-Hant.lproj` under 27, so asking for one
    /// exact spelling finds nothing on the toolchain CI uses. `PreviewWebView.moduleLocalizedString`
    /// was added for exactly this in #22 and carries the same note; this test was written before
    /// it and never moved across. The product is unaffected -- it already goes through that
    /// helper -- which is why the shipped 0.4.0 bundle has the translation while this test said
    /// it didn't. See mars-dawn-kit#35.
    @Test func webImageLabelIsLocalized() throws {
        #expect(PreviewWebView.moduleLocalizedString("Web image", localization: "zh-Hant") == "網路圖片")
    }
}
#endif
