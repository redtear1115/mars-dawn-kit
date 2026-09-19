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

    /// A local image that can't be shown is labelled with its path as the document wrote it
    /// (#23). An absolute path travels as `marsdawn-asset://abs/<path without its slash>`, and the
    /// label lost the slash with the host, so `/x/y.png` read as `x/y.png` -- a path that isn't
    /// the one in the document. Relative paths are the twins: they keep what was written and
    /// gain no slash. The space checks the path is still percent-decoded.
    @Test func aLocalImagePlaceholderShowsThePathAsWritten() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("marsdawn-labels-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let exporter = DocumentExporter(baseDirectory: folder, allowRemoteImages: false)
        try await exporter.prepare(markdown: """
        ![a](/nonexistent-marsdawn/outside.png)

        ![b](</nonexistent-marsdawn/with space.png>)

        ![c](missing.png)

        ![d](../outside.png)
        """, theme: .dawn)
        let labels = try await exporter.webView.evaluateJavaScript(
            #"[...document.querySelectorAll(".image-placeholder:not(.remote):not(.insecure) .image-placeholder-label")].map((l) => l.textContent)"#
        ) as? [String] ?? []
        let label = PreviewWebView.unloadableImagePlaceholderLabel
        #expect(labels == [
            "\(label): /nonexistent-marsdawn/outside.png",
            "\(label): /nonexistent-marsdawn/with space.png",
            "\(label): missing.png",
            "\(label): ../outside.png",
        ])
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
