#if os(macOS)
import AppKit
import Testing
import WebKit
@testable import MarsDawnExport
@testable import MarsDawnKit

/// Front matter in the real preview page: shown as an inert, collapsed block on screen and
/// hidden when printing (which is how PDF export renders).
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct FrontMatterPageTests {
    @Test func blockIsInertOnScreenAndHiddenInPrint() async throws {
        let exporter = DocumentExporter(baseDirectory: nil, allowRemoteImages: false)
        let markdown = """
        ---
        title: <script>window.frontMatterRan = 1</script>
        link: <a href="javascript:window.frontMatterRan=2">x</a> javascript:alert(1)
        image: <img src=x onerror="window.frontMatterRan=3">
        ---
        # Body
        """
        try await exporter.prepare(markdown: markdown, theme: .dawn)
        let webView = exporter.webView

        let script = """
        (() => {
          const content = document.querySelector("#content");
          const block = content.querySelector(":scope > details.front-matter");
          return JSON.stringify({
            first: content.firstElementChild === block,
            open: block.open,
            line: block.dataset.line,
            summary: block.querySelector("summary").textContent,
            cells: [...block.querySelectorAll("th, td")].map((c) => c.textContent),
            elements: [...block.querySelectorAll("*")].map((e) => e.tagName.toLowerCase()),
            injected: content.querySelectorAll("script, a, img").length,
            ran: window.frontMatterRan ?? null,
            display: getComputedStyle(block).display,
            heading: content.querySelector("h1").dataset.line,
          });
        })()
        """
        let screen = try #require(try await webView.evaluateJavaScript(script) as? String)
        let state = try JSONDecoder().decode(PageState.self, from: Data(screen.utf8))
        #expect(state.first)
        #expect(!state.open)
        #expect(state.line == "1")
        #expect(state.summary == "Document info")
        #expect(state.cells == [
            "title", "<script>window.frontMatterRan = 1</script>",
            "link", #"<a href="javascript:window.frontMatterRan=2">x</a> javascript:alert(1)"#,
            "image", #"<img src=x onerror="window.frontMatterRan=3">"#,
        ])
        #expect(Set(state.elements).isSubset(of: ["summary", "table", "tbody", "tr", "th", "td"]))
        #expect(state.injected == 0)
        #expect(state.ran == nil)
        #expect(state.display == "block")
        #expect(state.heading == "6")

        webView.mediaType = "print"
        let printed = try #require(try await webView.evaluateJavaScript(
            #"getComputedStyle(document.querySelector("details.front-matter")).display"#
        ) as? String)
        #expect(printed == "none")
    }

    private struct PageState: Decodable {
        let first: Bool
        let open: Bool
        let line: String
        let summary: String
        let cells: [String]
        let elements: [String]
        let injected: Int
        let ran: Int?
        let display: String
        let heading: String
    }
}
#endif
