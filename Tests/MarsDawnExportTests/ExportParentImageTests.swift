#if os(macOS)
import AppKit
import Foundation
import PDFKit
import Testing
@testable import MarsDawnExport
@testable import MarsDawnKit

/// `../` images in an exported PDF (mars-dawn#8). The exporter reads images only inside its
/// scope: the document's folder by default, as the CLI keeps it, or a `scopeRoot` the caller
/// passes (the app passes the folder the user granted).
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct ExportParentImageTests {
    /// <root>/granted/project/doc.md, <root>/granted/shared/pic.png, <root>/outside/pic.png, and
    /// <root>/granted/project/link.png, a symbolic link to the outside picture.
    private func makeTree() throws -> (root: URL, project: URL) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("export-dotdot-\(UUID().uuidString)").resolvingSymlinksInPath()
        let project = root.appendingPathComponent("granted/project")
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("granted/shared"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("outside"), withIntermediateDirectories: true)
        try Self.png().write(to: root.appendingPathComponent("granted/shared/pic.png"))
        try Self.png().write(to: root.appendingPathComponent("outside/pic.png"))
        try fm.createSymbolicLink(at: project.appendingPathComponent("link.png"), withDestinationURL: root.appendingPathComponent("outside/pic.png"))
        return (root, project)
    }

    /// What the export drew for `source`: whether any image is embedded, and the page's text.
    private func export(_ source: String, project: URL, scopeRoot: URL?) async throws -> (hasImage: Bool, text: String) {
        let url = project.deletingLastPathComponent().appendingPathComponent("out-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try await DocumentExporter.exportPDF(
            markdown: "# Pictures\n\n![pic](\(source))\n", to: url, theme: .dawn,
            baseDirectory: project, allowRemoteImages: false, scopeRoot: scopeRoot
        )
        let data = try Data(contentsOf: url)
        let text = try #require(PDFDocument(url: url)).page(at: 0)?.string ?? ""
        return (data.range(of: Data("/Subtype /Image".utf8)) != nil, text)
    }

    @Test func aSiblingImageLoadsOnlyWithTheParentAsScope() async throws {
        let (root, project) = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let granted = root.appendingPathComponent("granted")

        let withParent = try await export("../shared/pic.png", project: project, scopeRoot: granted)
        #expect(withParent.hasImage, "the parent as scope: the sibling image is drawn")
        #expect(!withParent.text.contains("Image not available"))

        // No scope passed, as the CLI does: the document's folder only, as before.
        let documentOnly = try await export("../shared/pic.png", project: project, scopeRoot: nil)
        #expect(!documentOnly.hasImage)
        #expect(documentOnly.text.contains("Image not available: ../shared/pic.png"))
    }

    /// With the parent as scope, nothing above it loads, however it's reached.
    @Test func nothingOutsideTheScopeLoads() async throws {
        let (root, project) = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let granted = root.appendingPathComponent("granted")
        for source in ["../../outside/pic.png", "..%2f..%2foutside/pic.png", "link.png", "../project/link.png"] {
            let result = try await export(source, project: project, scopeRoot: granted)
            #expect(!result.hasImage, "\(source) stays out")
            #expect(result.text.contains("Image not available"), "\(source) shows the placeholder")
        }
    }

    /// The placeholder for a `../` image that can't load reads the path as the document has it,
    /// carried in the URL's fragment. That text is the document's, so it is only ever text: a
    /// hostile path is shown, never parsed.
    @Test func aBlockedParentImageIsLabelledAsWrittenAndInert() async throws {
        let (root, project) = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let exporter = DocumentExporter(baseDirectory: project, allowRemoteImages: false)
        try await exporter.prepare(markdown: """
        ![a](../shared/pic.png)

        ![b](../%3Cimg%20src=x%20onerror=alert(1)%3E.png)

        ![c](../%3Cscript%3Ealert(1)%3C/script%3E.png)

        ![d](../%E0%A4%A.png)
        """, theme: .dawn)
        let labels = try await exporter.webView.evaluateJavaScript(
            #"[...document.querySelectorAll(".image-placeholder .image-placeholder-label")].map((l) => l.textContent)"#
        ) as? [String] ?? []
        let label = PreviewWebView.unloadableImagePlaceholderLabel
        #expect(labels == [
            "\(label): ../shared/pic.png",
            "\(label): ../<img src=x onerror=alert(1)>.png",
            "\(label): ../<script>alert(1)</script>.png",
            "\(label): ../%E0%A4%A.png",
        ], "\(labels)")
        let injected = try await exporter.webView.evaluateJavaScript(
            #"document.querySelectorAll('#content img[src="x"], #content script, .image-placeholder-label *').length"#
        ) as? Int
        #expect(injected == 0, "nothing from a path became markup")
    }

    /// A 16×16 PNG.
    static func png() throws -> Data {
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16, bitsPerSample: 8, samplesPerPixel: 3,
            hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        for y in 0..<16 { for x in 0..<16 { rep.setColor(.red, atX: x, y: y) } }
        return try #require(rep.representation(using: .png, properties: [:]))
    }
}
#endif
