#if os(macOS)
import AppKit
import Foundation
import Testing
import WebKit
@testable import MarsDawnExport
@testable import MarsDawnKit

/// redtear1115/mars-dawn-kit#119 on the export path: the exporter prepares the same page the
/// preview uses, so a message label inside a `rect` band has the band's colour as its halo there
/// too, and one outside any band keeps the page background.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(5)))
struct SequenceBandStrokeTests {
    static let markdown = """
    # Bands

    ```mermaid
    sequenceDiagram
      participant A
      participant B
      A->>B: OUTSIDE01
      rect rgb(191, 223, 255)
        A->>B: INBAND02
        rect rgb(200, 150, 255)
          B->>A: NESTED03
        end
      end
      A->>B: AFTER04
    ```
    """

    @Test func thePreparedExportPageHasBandColouredHalos() async throws {
        let exporter = DocumentExporter(baseDirectory: nil, allowRemoteImages: false)
        try await exporter.prepare(markdown: Self.markdown, theme: .dawn)

        let raw = try #require(try await exporter.webView.evaluateJavaScript("""
        (() => {
          const probe = document.createElement('div');
          probe.style.color = getComputedStyle(document.documentElement).getPropertyValue('--bg').trim();
          document.body.appendChild(probe);
          const bg = getComputedStyle(probe).color;
          probe.remove();
          const labels = {};
          for (const el of document.querySelectorAll('.mermaid-output svg .messageText')) {
            labels[el.textContent] = getComputedStyle(el).stroke;
          }
          return JSON.stringify({ labels, bg });
        })()
        """) as? String)
        struct Strokes: Decodable { let labels: [String: String]; let bg: String }
        let s = try JSONDecoder().decode(Strokes.self, from: Data(raw.utf8))
        #expect(s.labels.count == 4)
        #expect(s.labels["OUTSIDE01"] == s.bg)
        #expect(s.labels["INBAND02"] == "rgb(191, 223, 255)")
        #expect(s.labels["NESTED03"] == "rgb(200, 150, 255)")
        #expect(s.labels["AFTER04"] == s.bg)
    }
}
#endif
