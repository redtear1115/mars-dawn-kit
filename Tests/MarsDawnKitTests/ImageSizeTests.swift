import Foundation
import Testing
@testable import MarsDawnKit

/// HackMD's `![alt](url =WxH)` size suffix (#131), found in text after parsing (`ImageSizes`).
struct ImageSizeTests {
    private func render(_ markdown: String, options: MarkdownRenderer.Options = .init()) -> String {
        MarkdownRenderer.render(markdown, options: options)
    }

    // MARK: The forms

    @Test func widthAndHeight() {
        #expect(render("![a](https://example.com/a.png =200x100)\n")
            == "<p data-line=\"1\"><img src=\"https://example.com/a.png\" alt=\"a\" width=\"200\" height=\"100\"></p>\n")
    }

    @Test(arguments: [
        ("![a](b.png =200x)", #"<img src="b.png" alt="a" width="200">"#),
        ("![a](b.png =200)", #"<img src="b.png" alt="a" width="200">"#),
        ("![a](b.png =x100)", #"<img src="b.png" alt="a" height="100">"#),
        ("![a](b.png  =5x6)", #"<img src="b.png" alt="a" width="5" height="6">"#),
        ("![](b.png =5x6)", #"<img src="b.png" alt="" width="5" height="6">"#),
        ("![a b](b.png =5x6)", #"<img src="b.png" alt="a b" width="5" height="6">"#),
        ("![圖](圖片.png =5x6)", #"<img src="圖片.png" alt="圖" width="5" height="6">"#),
    ])
    func eachFormGivesItsSize(markdown: String, image: String) {
        #expect(render(markdown).contains(image), "\(render(markdown))")
    }

    @Test func sizesAreBounded() {
        #expect(render("![a](b.png =99999x0)").contains(#"<img src="b.png" alt="a" width="4096">"#))
        #expect(render("![a](b.png =0x7)").contains(#"<img src="b.png" alt="a" height="7">"#))
        #expect(render("![a](b.png =1234567x5)").contains("![a](b.png =1234567x5)"))
    }

    @Test(arguments: ["![a](b.png =)", "![a](b.png =x)", "![a](b.png =axb)", "![a](b.png = 5x5)",
                      "![a](b.png =5x5x5)", "![a](b c =5)"])
    func notASizeStaysText(markdown: String) {
        #expect(!render(markdown).contains("<img"), "\(render(markdown))")
    }

    /// Without the space these are ordinary CommonMark images, whose source holds the `=`.
    @Test func withoutTheSpaceItIsAnOrdinaryImage() {
        #expect(render("![a](b.png=5x5)").contains(#"<img src="b.png=5x5" alt="a">"#))
    }

    @Test func aPlainImageIsUnchanged() {
        #expect(render("![a](https://example.com/a.png \"t\")\n")
            == "<p data-line=\"1\"><img src=\"https://example.com/a.png\" alt=\"a\" title=\"t\"></p>\n")
    }

    // MARK: Where it applies

    @Test func everywhereTextIs() {
        #expect(render("text ![a](b.png =5x6) more").contains(#"text <img src="b.png" alt="a" width="5" height="6"> more"#))
        #expect(render("[x ![a](b.png =5) y](u)").contains(#"<a href="u">x <img src="b.png" alt="a" width="5"> y</a>"#))
        #expect(render("*em ![a](b.png =5)*").contains(#"<em>em <img src="b.png" alt="a" width="5"></em>"#))
        #expect(render("## H ![a](b.png =5)").contains(#"<img src="b.png" alt="a" width="5"></h2>"#))
        #expect(render("| h |\n|---|\n| ![a](b.png =5) |\n").contains(#"<td><img src="b.png" alt="a" width="5"></td>"#))
        #expect(render("> - ![a](b.png =5)").contains(#"<li data-line="1"><img src="b.png" alt="a" width="5">"#))
        #expect(render("==![a](b.png =5)==").contains(#"<mark><img src="b.png" alt="a" width="5"></mark>"#))
        #expect(render("![a](b.png =5) ![c](d.png =x6)").contains(
            #"<img src="b.png" alt="a" width="5"> <img src="d.png" alt="c" height="6">"#))
    }

    @Test func smartPunctuationAroundItIsFine() {
        let html = render("\"Quoted\" -- and it's... ![a](b.png =5)")
        #expect(html.contains(#"<img src="b.png" alt="a" width="5">"#), "\(html)")
    }

    @Test func aFootnoteNoteKeepsItsImageSizes() {
        #expect(render("x[^1]\n\n[^1]: ![a](b.png =5x6)\n").contains(#"<img src="b.png" alt="a" width="5" height="6">"#))
    }

    @Test func linesAndOtherContentAreUnchanged() {
        let html = render("# T\n\ntext ![a](b.png =5x6) more\n\n```\ncode\n```\n\n![c](d.png)\n")
        #expect(html.contains(#"<p data-line="3">text <img src="b.png" alt="a" width="5" height="6"> more</p>"#))
        #expect(html.contains(#"<p data-line="9"><img src="d.png" alt="c"></p>"#))
    }

    @Test func headingIDsAreAsBefore() {
        // The slug reads the heading's text as cmark parsed it, as it did before sizes existed.
        #expect(render("# H ![a](b =1)").contains(#"<h1 id="h-ab-1""#))
    }

    @Test func theImageSourcePolicyStillApplies() {
        var options = MarkdownRenderer.Options()
        options.resolveImageSource = { $0 == "a.png" ? "marsdawn-asset://doc/a.png" : $0 }
        #expect(render("![a](a.png =10x20)", options: options)
            .contains(#"<img src="marsdawn-asset://doc/a.png" alt="a" width="10" height="20">"#))
        #expect(render("![a](javascript:x =10x20)").contains(#"<img src="" alt="a" width="10" height="20">"#)
            || !render("![a](javascript:x =10x20)").contains("javascript"))
    }

    @Test func altAndSourceAreEscaped() {
        #expect(render("![a < b & \"c\"](x&y =5)").contains(#"<img src="x&amp;y" alt="a &lt; b &amp; “c”" width="5">"#))
    }

    // MARK: Text cmark doesn't read as text stays as it renders without the feature

    @Test(arguments: [
        ("[x](u \"![a](b =1)\")\n", #"<a href="u" title="![a](b =1)">x</a>"#),
        ("[x](u '![a](b =1)')\n", #"<a href="u" title="![a](b =1)">x</a>"#),
        ("[x](u \"a\n![a](b =1)\")\n", "<a href=\"u\" title=\"a\n![a](b =1)\">x</a>"),
        ("[x](u 'see\n![a](b =1)')\n", "<a href=\"u\" title=\"see\n![a](b =1)\">x</a>"),
        ("![i](u \"t\n![a](b =1)\")\n", "<img src=\"u\" alt=\"i\" title=\"t\n![a](b =1)\">"),
        ("[r]: u\n`a ![a](b =1)`\n", "<code>a ![a](b =1)</code>"),
        ("[r]: u\n[x](v \"![a](b =1)\")\n", #"<a href="v" title="![a](b =1)">x</a>"#),
        ("`![a](b.png =200x)`", "<code>![a](b.png =200x)</code>"),
        ("```\n![a](b.png =200x)\n```\n", "![a](b.png =200x)\n</code>"),
        ("    ![a](b.png =200x)\n", "![a](b.png =200x)"),
        ("<span title=\"![a](b =1)\">s</span>", #"<span title="![a](b =1)">s</span>"#),
        ("intro [x](v \"![a](b =1)\")\n| h |\n|---|\n| c |\n", #"<a href="v" title="![a](b =1)">x</a>"#),
        ("<!-- ![a](b =1) -->\n", "<!-- ![a](b =1) -->"),
    ])
    func notText(markdown: String, kept: String) {
        let html = render(markdown)
        #expect(html.contains(kept), "\(html)")
        #expect(!html.contains("width=\"1\""), "\(html)")
    }

    @Test(arguments: ["\\![a](b =1)", "!\\[a](b =1)", "![a\\](b =1)", "![a](b\\ =1)", "&#33;[a](b =1)",
                      "![a](b &#61;1)", "![a](b =1&#41;"])
    func anEscapeOrEntityKeepsItText(markdown: String) {
        #expect(!render(markdown).contains("<img"), "\(render(markdown))")
    }

    @Test func aSourceThatSmartPunctuationChangedIsNotAnImage() {
        #expect(!render("![a](my--file.png =5)").contains("<img"))
    }

    @Test func anUnclosedLinkAroundItOnlyConvertsTheImage() {
        #expect(render("[x](![a](b =1))").contains(#"[x](<img src="b" alt="a" width="1">)"#))
        #expect(render("see [docs](![a](b =1)").contains(#"see [docs](<img src="b" alt="a" width="1">"#))
    }

    @Test func noPrivateUseCharacterEverReachesTheOutput() {
        for markdown in ["![a](b =1)", "x $y$ ![a](b =1) $z$", "x[^1] ![a](b =1)\n\n[^1]: n\n", "![$a$](b =1)", "![a](b$c$ =1)"] {
            let html = render(markdown)
            #expect(!html.unicodeScalars.contains { (0xE000...0xF8FF).contains($0.value) }, "\(markdown) -> \(html)")
        }
    }

    // MARK: The scanner

    @Test func theScannerFindsEachMatchByItsBytes() {
        let matches = ImageSizes.matches(in: "x ![a](b =1) ![![c](d =2x3)")
        #expect(matches.map(\.alt) == ["a", "c"])
        #expect(matches.map(\.width) == [1, 2])
        #expect(matches.map(\.height) == [nil, 3])
    }

    @Test(.timeLimit(.minutes(1)))
    func scanningIsLinear() {
        let clock = ContinuousClock()
        func seconds(_ text: String) -> Double {
            let elapsed = clock.measure { _ = ImageSizes.matches(in: text) }
            return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        }
        // Each shape at 4x the size should take about 4x the time, not 16x.
        for unit in ["![a](b =1) ", "![![![", "![a](bbbbbbbbbb", "![aaaaaaaaaa", "![a](b =", "![a](b =1x"] {
            let small = seconds(String(repeating: unit, count: 20_000))
            let large = seconds(String(repeating: unit, count: 80_000))
            #expect(large < max(small, 0.005) * 10, "\(unit): \(small) s -> \(large) s")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func manyImagesOnOneLineRenderInLinearTime() {
        #if DEBUG
        let budget = 20.0
        #else
        let budget = 2.0
        #endif
        let line = String(repeating: "`c` ![a](b =1) ", count: 100_000)
        let clock = ContinuousClock()
        var html = ""
        let elapsed = clock.measure { html = render(line) }
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        #expect(html.components(separatedBy: "<img").count - 1 == 100_000)
        #expect(seconds < budget, "\(seconds) s")
    }

    /// Marks split one text into many pieces; its source is still checked once (#152 review).
    @Test(.timeLimit(.minutes(1)), arguments: ["![a](b =1)==x==", "![a](b =1)^x^", "![a] =1==x=="])
    func manyMarkPiecesInOneTextRenderInLinearTime(unit: String) {
        #if DEBUG
        let budget = 10.0
        #else
        let budget = 1.0
        #endif
        let clock = ContinuousClock()
        let elapsed = clock.measure { _ = render(String(repeating: unit, count: 8_000)) }
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        #expect(seconds < budget, "\(unit): \(seconds) s")
    }
}
