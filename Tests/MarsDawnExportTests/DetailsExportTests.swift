#if os(macOS)
import AppKit
import Foundation
import PDFKit
import Testing
import WebKit
@testable import MarsDawnExport
@testable import MarsDawnKit

/// A PDF prints everything a `<details>` holds, however the document left it collapsed
/// (redtear1115/mars-dawn#414). The text is read from the PDF itself.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(3)))
struct DetailsExportTests {
    private static let markdown = """
        ---
        title: FRONTMATTER-SECRET
        ---
        \(DetailsFixture.markdown)

        <details name="x">
        <summary>NAMED-ONE-SUMMARY</summary>

        NAMED-ONE-BODY

        </details>

        <details name="x">
        <summary>NAMED-TWO-SUMMARY</summary>

        NAMED-TWO-BODY

        </details>

        <details>
        <summary>CLOSED-SUMMARY</summary>

        CLOSED-BODY

        ```swift
        let closedCode = 1
        ```

        </details>

        LAST-PARAGRAPH
        """

    private func pdfText(_ markdown: String) async throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("marsdawn-details-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try await DocumentExporter.exportPDF(
            markdown: markdown, to: url, theme: .dawn, baseDirectory: nil, allowRemoteImages: false
        )
        let document = try #require(PDFDocument(url: url))
        return (0..<document.pageCount).compactMap { document.page(at: $0)?.string }.joined(separator: "\n")
    }

    /// A8: every collapsed group's body is in the PDF's own text, the exclusive (`name`) ones too,
    /// the end of the fixture is there and the front matter is not.
    @Test func thePdfHoldsEverythingInsideEveryDetails() async throws {
        let text = try await pdfText(Self.markdown)
        for part in [
            "A 補充細節", "A 內文", "A 清單二", "A code",
            "C 預設展開", "C 內文",
            "G 外層", "G 外文", "G 內層", "G 內文",
            "NAMED-ONE-SUMMARY", "NAMED-ONE-BODY", "NAMED-TWO-SUMMARY", "NAMED-TWO-BODY",
            "CLOSED-BODY", "closedCode", "A 之後的段落", "END-OF-FIXTURE", "LAST-PARAGRAPH",
        ] {
            #expect(text.contains(part), "the PDF holds \(part)")
        }
        #expect(!text.contains("FRONTMATTER-SECRET"), "front matter stays out")
        #expect(!text.contains("Document info"))
        #expect(!text.contains("</details>"))
    }

    /// The same document on the export page itself: all open, no exclusive names, front matter
    /// untouched.
    @Test func theExportPageOpensEverythingExceptFrontMatter() async throws {
        let exporter = DocumentExporter(baseDirectory: nil, allowRemoteImages: false)
        try await exporter.prepare(markdown: Self.markdown, theme: .dawn)
        let text = try #require(try await exporter.webView.evaluateJavaScript("""
            JSON.stringify({
              all: [...document.querySelectorAll("details:not(.front-matter)")].map((d) => d.open),
              names: document.querySelectorAll("details[name]").length,
              frontMatter: document.querySelector("details.front-matter").open,
              frontMatterCount: document.querySelectorAll("details.front-matter").length,
            })
            """) as? String)
        let state = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let all = state["all"] as? [Bool] ?? []
        #expect(all.count == 7)
        #expect(!all.contains(false), "every details is open")
        #expect(state["names"] as? Int == 0)
        #expect(state["frontMatter"] as? Bool == false)
        #expect(state["frontMatterCount"] as? Int == 1)
    }

    /// F3: the open-all script is a constant, and an inline handler is as inert on the export
    /// page as on the preview.
    @Test func anInlineToggleHandlerDoesNotRunOnTheExportPage() async throws {
        let exporter = DocumentExporter(baseDirectory: nil, allowRemoteImages: false)
        let markdown = """
            <details>
            <summary>S</summary>

            <div>
            <details open ontoggle="document.title='x'"><summary>t</summary>inner</details>
            </div>

            </details>
            """
        try await exporter.prepare(markdown: markdown, theme: .dawn)
        let text = try #require(try await exporter.webView.callAsyncJavaScript("""
            window.__toggles = 0;
            document.addEventListener("toggle", () => { window.__toggles++; }, true);
            const inner = document.querySelector("details details");
            inner.open = false; inner.open = true;
            await new Promise((r) => setTimeout(r, 200));
            return JSON.stringify({ title: document.title, toggles: window.__toggles, has: inner.hasAttribute("ontoggle") });
            """, contentWorld: .page) as? String)
        let state = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(state["has"] as? Bool == true, "positive fixture: the attribute is there")
        #expect((state["toggles"] as? Int ?? 0) >= 1, "positive fixture: toggle events fire")
        #expect(state["title"] as? String != "x")
    }
}
#endif
