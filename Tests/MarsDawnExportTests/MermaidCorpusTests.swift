#if os(macOS)
import AppKit
import Foundation
import PDFKit
import Testing
import WebKit
@testable import MarsDawnExport
@testable import MarsDawnKit

/// The Mermaid compatibility corpus (redtear1115/mars-dawn#3): one small real diagram for each
/// diagram type the vendored Mermaid registers, plus one invalid diagram. A Mermaid upgrade is a
/// breaking change, so this is the pass it has to go through (see `LICENSE-mermaid.txt`).
///
/// The fixtures and their `expect.json` markers come from kit #21's PDF golden corpus
/// (`pdf-corpus-harness`), which is otherwise still parked; only its Mermaid part lives here.
///
/// For each fixture:
/// - **PDF export** (#2): the export completes, every marker extracts from the PDF text, the
///   paragraph after the diagram is on the last page, and the diagram rendered or failed as
///   expected.
/// - **Preview**: the diagram renders to the same number of SVG elements as the recorded
///   baseline in `node-counts.json`. Node counts rather than SVG text, because Mermaid's SVG
///   carries generated ids and measured coordinates; a count moves when an upgrade draws a
///   diagram differently, and stays put when only a font metric does.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(10)))
struct MermaidCorpusTests {
    struct Expectation: Decodable {
        struct Diagrams: Decodable { var rendered: Int; var failed: Int }
        var markers: [String]
        var markersOnLastPage: [String] = []
        var placeholders: [String]?
        var diagrams: Diagrams
    }

    nonisolated static var corpusURL: URL? { Bundle.module.url(forResource: "MermaidCorpus", withExtension: nil) }

    nonisolated static let fixtureNames: [String] = {
        guard let corpusURL,
              let entries = try? FileManager.default.contentsOfDirectory(
                at: corpusURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
              ) else { return [] }
        return entries.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .map(\.lastPathComponent).sorted()
    }()

    static func load(_ name: String) throws -> (markdown: String, expectation: Expectation) {
        let folder = try #require(corpusURL).appendingPathComponent(name, isDirectory: true)
        let markdown = try String(contentsOf: folder.appendingPathComponent("document.md"), encoding: .utf8)
        let expectation = try JSONDecoder().decode(
            Expectation.self, from: Data(contentsOf: folder.appendingPathComponent("expect.json"))
        )
        return (markdown, expectation)
    }

    /// Whitespace-free and compatibility-folded, so line breaks and ligatures in the PDF's text
    /// don't hide a marker that is there.
    static func normalize(_ text: String) -> String {
        String(text.precomposedStringWithCompatibilityMapping.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0)
        })
    }

    @Test func theCorpusWasFound() {
        // An empty list would make every parameterised case below silently run zero times.
        #expect(Self.fixtureNames.count >= 30, "found \(Self.fixtureNames)")
        #expect(Self.fixtureNames.contains("mermaid-invalid"))
        #expect(Self.fixtureNames.contains("mermaid-flowchart-v2"))
    }

    // MARK: PDF export

    @Test(arguments: MermaidCorpusTests.fixtureNames)
    func exportsToPDF(_ name: String) async throws {
        let (markdown, expectation) = try Self.load(name)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("export.pdf")

        let result = try await DocumentExporter.exportPDF(
            markdown: markdown, to: url, theme: .dawn, baseDirectory: nil, allowRemoteImages: false
        )
        let pdf = try #require(PDFDocument(url: url))
        let pages = (0..<pdf.pageCount).map { pdf.page(at: $0)?.string ?? "" }
        let text = Self.normalize(pages.joined(separator: "\n"))
        let lastPage = Self.normalize(pages.last ?? "")

        for marker in expectation.markers + (expectation.placeholders ?? []) {
            #expect(text.contains(Self.normalize(marker)), "\(name): \(marker) is missing from the PDF")
        }
        for marker in expectation.markersOnLastPage {
            #expect(lastPage.contains(Self.normalize(marker)), "\(name): \(marker) is missing from the last page")
        }
        #expect(result.diagramErrors.count == expectation.diagrams.failed, "\(name): \(result.diagramErrors)")
        let fences = markdown.components(separatedBy: "```mermaid").count - 1
        #expect(fences == expectation.diagrams.rendered + expectation.diagrams.failed, "\(name): diagram count")
    }

    // MARK: Preview node counts

    nonisolated static func recordedNodeCounts() throws -> [String: Int] {
        let url = try #require(corpusURL).appendingPathComponent("node-counts.json")
        return try JSONDecoder().decode([String: Int].self, from: Data(contentsOf: url))
    }

    private func loadedPreview() async throws -> PreviewWKWebView {
        let webView = PreviewWKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 1000),
                                       configuration: PreviewWebView.makeConfiguration())
        webView.applyContentRuleList(try await PreviewContentRules.ruleList(allowRemoteImages: false))
        #expect(webView.load(URLRequest(url: PreviewSchemeHandler.pageURL(theme: .dawn))) != nil)
        let deadline = ContinuousClock.now + .seconds(20)
        while webView.isLoading, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!webView.isLoading)
        return webView
    }

    /// Every fixture that should render draws the recorded number of SVG elements in the preview,
    /// and the invalid one draws none. One test over all fixtures, so a missing baseline prints
    /// every measured count at once for recording.
    @Test func previewNodeCountsMatchTheBaseline() async throws {
        let recorded = try Self.recordedNodeCounts()
        let webView = try await loadedPreview()
        var measured: [String: Int] = [:]
        for name in Self.fixtureNames {
            let (markdown, expectation) = try Self.load(name)
            _ = try await webView.evaluateJavaScript(
                PreviewWebView.updateScript(html: MarkdownRenderer.render(markdown), lineCount: 40)
            )
            _ = try? await webView.callAsyncJavaScript("return await MarsDawn.idle();", contentWorld: .page)
            let count = try await webView.callAsyncJavaScript(
                "return document.querySelectorAll('#content .mermaid-output svg, #content .mermaid-output svg *').length;",
                contentWorld: .page
            ) as? Int ?? -1
            measured[name] = count
            if expectation.diagrams.failed > 0 {
                #expect(count == 0, "\(name): an invalid diagram drew \(count) SVG elements")
            } else {
                #expect(count > 1, "\(name): the diagram drew nothing")
            }
        }
        let missing = Self.fixtureNames.filter { recorded[$0] == nil }
        let changed = Self.fixtureNames.filter { recorded[$0] != nil && recorded[$0] != measured[$0] }
        let record = measured.sorted { $0.key < $1.key }.map { "  \"\($0.key)\": \($0.value)" }.joined(separator: ",\n")
        #expect(missing.isEmpty && changed.isEmpty,
                "missing \(missing), changed \(changed.map { "\($0) \(recorded[$0]!)→\(measured[$0]!)" }); measured:\n{\n\(record)\n}")
        #expect(Set(recorded.keys).subtracting(Self.fixtureNames).isEmpty, "baseline entries with no fixture")
    }
}
#endif
