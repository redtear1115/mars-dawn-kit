import Foundation
import Testing
@testable import MarsDawnKit

/// mars-dawn-kit#187: a math placeholder split apart by the parse (a list item, an attribute
/// definition line and a footnote together) was never expanded, so its pieces reached the page
/// with a random nonce. The renderer now renders such a document again without math.
struct MathPlaceholderLeakTests {
    static let leaking = [
        "1. ^[a]:=\n--$x$\n|[^1]\r\n[^1]:",
        "1. ^[a]:=\n--$x$\n|[^1]\n[^1]:",
    ]
    static let clean = [
        "^[a]:=\n--$x$\n",
        "--$x$\n|[^1]\r\n[^1]:",
        "1. ^[a]:=\n--$x$",
    ]

    static func leaks(_ html: String) -> Bool {
        html.unicodeScalars.contains { $0 == "\u{E000}" || $0 == "\u{E001}" }
    }

    @Test(arguments: leaking)
    func splitPlaceholderDoesNotLeak(_ source: String) {
        let first = MarkdownRenderer.render(source)
        #expect(!Self.leaks(first), "leaked: \(first.debugDescription)")
        for _ in 0..<5 { #expect(MarkdownRenderer.render(source) == first) }
        #expect(first.contains("$x$"), "math should show as literal source")
        #expect(!first.contains("math-inline"))
    }

    @Test(arguments: leaking)
    func asyncRenderDoesNotLeakEither(_ source: String) async {
        let result = await MarkdownRenderer.renderResult(source)
        #expect(result != nil && !Self.leaks(result!.html))
    }

    @Test(arguments: clean)
    func nonLeakingInputsStillRenderMath(_ source: String) {
        let html = MarkdownRenderer.render(source)
        #expect(html.contains("<span class=\"math-inline\">x</span>"), "\(html.debugDescription)")
        #expect(!Self.leaks(html))
        #expect(MarkdownRenderer.render(source) == html)
    }

    @Test func mathElsewhereInALeakingDocumentFallsBackToo() {
        let html = MarkdownRenderer.render("Intro $a+b$.\n\n" + Self.leaking[0])
        #expect(!Self.leaks(html))
        #expect(html.contains("$a+b$"))
    }

    @Test func authorWrittenPlaceholderScalarsAreNotATrigger() {
        let html = MarkdownRenderer.render("a \u{E000} b $x$")
        #expect(html.contains("math-inline"))
    }
}
