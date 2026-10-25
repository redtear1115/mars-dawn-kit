import Foundation
import Testing
@testable import MarsDawnKit

/// mars-dawn-kit#187: a math placeholder split apart by the parse was never expanded, so its
/// pieces reached the page with a random nonce. The renderer now renders such a document again
/// without math.
///
/// The leaking inputs were a list item, an attribute definition line and a footnote together,
/// where the footnote's column (wrong on a paragraph's later lines) put its placeholder over the
/// math's (#159 fixed that). They are the first two of `clean` now. What leaks today, found by a
/// random search, is a footnote definition whose opening fence line holds math.
struct MathPlaceholderLeakTests {
    static let leaking = [
        "[^2]: ``` $m$\n\n$x$",
        "[^2]: ``` $m$\r\n\r\n$x$",
    ]
    static let clean = [
        "1. ^[a]:=\n--$x$\n|[^1]\r\n[^1]:",
        "1. ^[a]:=\n--$x$\n|[^1]\n[^1]:",
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

    @Test func frontMatterScalarsDoNotCostTheDocumentItsMath() {
        let html = MarkdownRenderer.render("---\nicon: \u{E000}\u{E001}\n---\n\n$$E=mc^2$$")
        #expect(html.contains("math-display"), Comment(rawValue: html.unicodeScalars.map { $0.escaped(asASCII: true) }.joined()))
    }

    /// An author scalar the output drops (here inside the removed attribute-definition line)
    /// must not hide a leak by tying the scalar counts.
    @Test func droppedAuthorScalarDoesNotHideALeak() {
        for scalars in ["\u{E000}", "\u{E001}", "\u{E000}\u{E001}"] {
            let source = "^[a]:=\(scalars)\n[^2]: ``` $m$\n\n$x$"
            let first = MarkdownRenderer.render(source)
            let stray = first.unicodeScalars.filter { $0 == "\u{E000}" || $0 == "\u{E001}" }.count
            #expect(stray <= scalars.unicodeScalars.count, "\(first.debugDescription)")
            #expect(first.contains("$x$"), "\(first.debugDescription)")
            #expect(MarkdownRenderer.render(source) == first)
        }
    }
}
