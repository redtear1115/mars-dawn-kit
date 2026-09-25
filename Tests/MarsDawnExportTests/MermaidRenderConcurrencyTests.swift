#if os(macOS)
import Foundation
import Testing
@testable import MarsDawnExport
@testable import MarsDawnKit

/// Regression coverage for mars-dawn-kit#113: `marsdawn export` of a document with many Mermaid
/// diagrams (mermaid-50, 16.5 KB) always failed with exit 5 ("took too long to lay out"), even
/// though the App settles the same diagrams quickly and `mermaid.render()` itself takes only
/// single-digit milliseconds per diagram when called one at a time.
///
/// The actual cause: `preview.js`'s `update()` (and `rerenderDiagrams()`) fired every changed
/// diagram's `mermaid.render()` call at once, without waiting for the previous one — and
/// `mermaid.render()` shares mutable state across calls (a temporary DOM sandbox, an id
/// counter), so concurrent calls don't overlap their work, they serialize it badly: measured
/// directly (bypassing preview.js), 25 concurrent `mermaid.render()` calls took ~15.5s total —
/// the first ten settled in under 200ms, then the rest in pairs roughly two seconds apart —
/// while 25 *sequential* calls to the exact same diagrams took under 0.6s combined. The fix
/// renders diagrams one at a time (`renderMermaidSequentially` in `preview.js`), never
/// concurrently, no matter how many changed in one update.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct MermaidRenderConcurrencyTests {
    static func markdown(diagrams: Int) -> String {
        var markdown = "# Many diagrams\n\n"
        for i in 0..<diagrams {
            markdown += "```mermaid\nflowchart TD\n  a\(i)[Node \(i)] --> b\(i)[Next \(i)]\n```\n\n"
        }
        return markdown
    }

    /// 40 trivial diagrams: rendered one at a time (the fix), the whole page settles in well
    /// under a second combined. Rendered concurrently (the bug), each diagram past the first ten
    /// cost roughly a second, so 40 of them either blew well past this test's own bound or
    /// tripped `DocumentExporter`'s 20s export deadline outright.
    @Test func manyDiagramsSettleWithoutSerializing() async throws {
        let markdown = Self.markdown(diagrams: 40)
        let exporter = DocumentExporter(baseDirectory: nil, allowRemoteImages: false)
        let start = ContinuousClock.now
        try await exporter.prepare(markdown: markdown, theme: .dawn)
        let elapsed = ContinuousClock.now - start
        #expect(exporter.diagramErrors.isEmpty, "\(exporter.diagramErrors)")
        // Generous (actual: well under 2s) but far below the ~1s/diagram the concurrent bug
        // cost, and below DocumentExporter's own 20s content timeout.
        #expect(elapsed < .seconds(10), "took \(elapsed) — mermaid.render() calls may be running concurrently again (kit#113)")
    }

    /// The same shape of fix, exercised through the real export path (mermaid-50's actual size):
    /// completes within the existing 20s content timeout, with no diagram errors.
    @Test func exportOfFiftyDiagramsCompletesWithinTheTimeout() async throws {
        let markdown = Self.markdown(diagrams: 50)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("export.pdf")

        let result = try await DocumentExporter.exportPDF(
            markdown: markdown, to: url, theme: .dawn, baseDirectory: nil, allowRemoteImages: false
        )
        #expect(result.diagramErrors.isEmpty, "\(result.diagramErrors)")
        #expect(result.pageCount > 0)
    }
}
#endif
