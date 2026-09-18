import Foundation
import Markdown
import Testing
@testable import MarsDawnKit

private struct FixedGenerator: RandomNumberGenerator {
    var value: UInt64
    mutating func next() -> UInt64 { value }
}

private struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private typealias Segment = MathExtractor.Segment

/// Extracts with a fixed nonce and checks the line-count invariant for every input.
private func extract(_ body: String, sourceLocation: Testing.SourceLocation = #_sourceLocation) -> MathExtractor.Extraction {
    var generator = FixedGenerator(value: 0x0123_4567_89AB_CDEF)
    let extraction = MathExtractor.extract(from: body, using: &generator)
    #expect(lineCount(extraction.markdown) == lineCount(body), "line count changed", sourceLocation: sourceLocation)
    return extraction
}

/// Lines as CommonMark counts them (LF, CR LF, lone CR).
private func lineCount(_ string: String) -> Int {
    let bytes = Array(string.utf8)
    var count = 1
    var index = 0
    while index < bytes.count {
        if bytes[index] == 0x0A {
            count += 1
        } else if bytes[index] == 0x0D {
            count += 1
            if index + 1 < bytes.count, bytes[index + 1] == 0x0A { index += 1 }
        }
        index += 1
    }
    return count
}

private func math(_ extraction: MathExtractor.Extraction) -> [Segment] {
    extraction.segments(in: extraction.markdown).filter {
        if case .math = $0 { return true }
        return false
    }
}

private func assertUntouched(_ body: String, sourceLocation: Testing.SourceLocation = #_sourceLocation) {
    let extraction = extract(body, sourceLocation: sourceLocation)
    #expect(extraction.markdown == body, sourceLocation: sourceLocation)
    #expect(extraction.expressionCount == 0, sourceLocation: sourceLocation)
}

private func descendants(_ markup: any Markup) -> [any Markup] {
    markup.children.flatMap { [$0] + descendants($0) }
}

/// Every expression is recoverable from the parsed rewrite, only from plain text (or the
/// generated fence), and putting the inline TeX back gives the original source.
private func invariantViolation(_ body: String) -> String? {
    let extraction = extract(body)
    let document = Document(parsing: extraction.markdown)
    var recovered: [String] = []
    for node in descendants(document) {
        switch node {
        case let text as Text:
            for case .math(let tex, _) in extraction.segments(in: text.string) { recovered.append(tex) }
        case let code as CodeBlock:
            if code.language?.unicodeScalars.contains("\u{E000}") == true {
                recovered.append(extraction.tex(forMathFence: code.language, code: code.code))
            }
            if code.code.unicodeScalars.contains("\u{E000}") { return "placeholder in code block" }
        case let code as InlineCode where code.code.unicodeScalars.contains("\u{E000}"):
            return "placeholder in code span"
        case let html as InlineHTML where html.rawHTML.unicodeScalars.contains("\u{E000}"):
            return "placeholder in inline HTML"
        case let html as HTMLBlock where html.rawHTML.unicodeScalars.contains("\u{E000}"):
            return "placeholder in HTML block"
        case let link as Link where (link.destination ?? "").unicodeScalars.contains("\u{E000}"):
            return "placeholder in link destination"
        default:
            break
        }
    }
    let expected = extraction.expressions.map(\.tex)
    guard recovered.sorted() == expected.sorted() else { return "recovered \(recovered), expected \(expected)" }
    guard !extraction.expressions.contains(where: \.isBlock) else { return nil }
    var rebuilt = extraction.markdown
    for (index, expression) in extraction.expressions.enumerated() {
        let delimiter = expression.display ? "$$" : "$"
        guard let range = rebuilt.range(of: "\u{E000}\(index):\(nonce)\u{E001}") else { return "missing \(index)" }
        rebuilt.replaceSubrange(range, with: delimiter + expression.tex + delimiter)
    }
    return rebuilt == body ? nil : "rebuilt \(rebuilt.debugDescription)"
}

private let nonce = "0123456789abcdef"

struct MathExtractorTests {
    // MARK: Inline math

    @Test(arguments: [
        #"a\,b"#, #"\{x\}"#, "a*b*c", "x<y>z", "</span><script>alert(1)</script>",
    ])
    func inlineTeXIsVerbatim(tex: String) {
        let extraction = extract("before $\(tex)$ after")
        #expect(extraction.markdown == "before \u{E000}0:\(nonce)\u{E001} after")
        #expect(extraction.segments(in: extraction.markdown) == [
            .text("before "), .math(tex: tex, display: false), .text(" after"),
        ])
    }

    @Test func escapedDollarStaysLiteral() {
        let extraction = extract(#"costs \$5 and $x$"#)
        #expect(extraction.markdown.hasPrefix(#"costs \$5 and "#))
        #expect(math(extraction) == [.math(tex: "x", display: false)])
        let inside = extract(#"$a\$b$"#)
        #expect(math(inside) == [.math(tex: #"a\$b"#, display: false)])
    }

    @Test(arguments: [
        "$5 and $6", "$ x$", "$x $", "$x$5", "costs $5", "a $$ b", "$$$x$$$", "`$x$`", "``a ` $x$ ``",
        "text `code\n$x$` more", "no dollars at all",
    ])
    func notInlineMath(body: String) {
        assertUntouched(body)
    }

    @Test func doubleDollarInsideAParagraphIsDisplay() {
        let extraction = extract("where $$x^2$$ holds, and $y$")
        #expect(math(extraction) == [.math(tex: "x^2", display: true), .math(tex: "y", display: false)])
    }

    @Test func singleLineDisplayParagraphBecomesPlaceholder() {
        let extraction = extract("$$ x = 1 $$\n")
        #expect(extraction.markdown == "\u{E000}0:\(nonce)\u{E001}\n")
        #expect(math(extraction) == [.math(tex: " x = 1 ", display: true)])
    }

    @Test func mathInHeadingsListsQuotesAndCellsIsExtracted() {
        let extraction = extract("# Title $a$\n\n- item $b$\n\n> quote $c$\n\nSetext $d$\n---\n\n| h |\n|---|\n| $e$ |\n")
        #expect(math(extraction).map { if case .math(let tex, _) = $0 { tex } else { "" } } == ["a", "b", "c", "d", "e"])
    }

    /// The left-to-right rule: math that opens first may enclose code spans,
    /// HTML and links completely, but never ends inside one.
    @Test func leftToRightPrecedence() {
        #expect(math(extract("$a `b` c$")) == [.math(tex: "a `b` c", display: false)])
        #expect(math(extract("$a [b](c) d$")) == [.math(tex: "a [b](c) d", display: false)])
        assertUntouched("$a `b$` c")  // the only closer is inside a code span
        assertUntouched("`$a` b$")  // the opener is inside a code span
        assertUntouched("[a $x](u) y$")  // math may not leave a link's text
        #expect(math(extract("[a $x$](u) $y$")).count == 2)
    }

    // MARK: Display blocks

    @Test func multiLineDisplayParagraphBecomesAFence() {
        let body = "Intro\n\n$$\na \\\\ b\n$$\n\nAfter"
        let extraction = extract(body)
        let lines = extraction.markdown.components(separatedBy: "\n")
        #expect(lines == ["Intro", "", "```math \u{E000}0:\(nonce)\u{E001}", "a \\\\ b", "```", "", "After"])
        #expect(extraction.tex(forMathFence: "math \u{E000}0:\(nonce)\u{E001}", code: "a \\\\ b\n") == "\na \\\\ b\n")
        // A block expression is never expanded from ordinary text.
        #expect(extraction.segments(in: "\u{E000}0:\(nonce)\u{E001}") == [.text("\u{E000}0:\(nonce)\u{E001}")])
    }

    @Test func texOnDelimiterLinesIsKeptOutOfTheFence() {
        let body = "$$ x = 1\ny = 2\nz = 3 $$\n"
        let extraction = extract(body)
        let lines = extraction.markdown.components(separatedBy: "\n")
        #expect(lines == ["```math \u{E000}0:\(nonce)\u{E001}", "y = 2", "```", ""])
        #expect(extraction.tex(forMathFence: String(lines[0].dropFirst(3)), code: "y = 2\n") == " x = 1\ny = 2\nz = 3 ")
    }

    @Test func indentedDisplayParagraphIsStillTopLevel() {
        let extraction = extract("  $$\n  a\n  $$")
        #expect(extraction.markdown == "```math \u{E000}0:\(nonce)\u{E001}\n  a\n```")
        #expect(extraction.tex(forMathFence: "math \u{E000}0:\(nonce)\u{E001}", code: "") == "\n  a\n  ")
    }

    @Test func backticksInsideDisplayMathGetALongerFence() {
        // A line of three backticks would open a code block in the original parse, so the
        // backticks here sit inside TeX lines.
        let extraction = extract("$$\na ``` b\n\\text{`a``}\n$$")
        let lines = extraction.markdown.components(separatedBy: "\n")
        #expect(lines[0] == "````math \u{E000}0:\(nonce)\u{E001}")
        #expect(lines[3] == "````")
        let document = Document(parsing: extraction.markdown)
        let blocks = descendants(document).compactMap { $0 as? CodeBlock }
        #expect(blocks.count == 1)
        #expect(blocks.first?.code == "a ``` b\n\\text{`a``}\n")
        #expect(extraction.tex(forMathFence: blocks.first?.language, code: blocks.first?.code ?? "")
            == "\na ``` b\n\\text{`a``}\n")
    }

    @Test func aLineOfThreeBackticksEndsTheParagraph() {
        assertUntouched("$$\n```\n$$")
    }

    @Test func displayLineEndingsArePreserved() {
        let extraction = extract("$$\r\nx\r\n$$\r\n\r\nnext $y$\r\n")
        #expect(extraction.markdown
            == "```math \u{E000}0:\(nonce)\u{E001}\r\nx\r\n```\r\n\r\nnext \u{E000}1:\(nonce)\u{E001}\r\n")
        #expect(extraction.tex(forMathFence: "math \u{E000}0:\(nonce)\u{E001}", code: "") == "\r\nx\r\n")
        let lone = extract("$$\ra\r$$\r\r$b$\r")
        #expect(lone.markdown == "```math \u{E000}0:\(nonce)\u{E001}\ra\r```\r\r\u{E000}1:\(nonce)\u{E001}\r")
    }

    @Test(arguments: [
        "> $$\n> a*b*\n> $$",
        "- $$\n  a*b*\n  $$",
        "1. > $$\n   > a*b*\n   > $$\n",
        "- > $$\n  > a*b*\n  > $$\n",
        "> - $$\n>   a\n>   $$\n",
        "$$\na\n\nb\n$$",  // blank line: two paragraphs
        "$$ unclosed\nmore",
        "text\n$$\na\n$$",  // the `$$` lines continue the paragraph
        "$$\na $$ b\n$$",  // more than one display expression
        // A2: lazy continuation lines belong to the quote or list item.
        "> quote\n$$\na\n$$\n",
        "- item\n$$\na\n$$\n",
    ])
    func displayOnlyForWholeTopLevelParagraphs(body: String) {
        assertUntouched(body)
    }

    @Test func authoredMathFenceReturnsItsCode() {
        let extraction = extract("```math\nx\n```")
        #expect(extraction.expressionCount == 0)
        #expect(extraction.tex(forMathFence: "math", code: "x\n") == "x")
        #expect(extraction.tex(forMathFence: "math \u{E000}0:\(nonce)\u{E001}", code: "x\n") == "x")
    }

    @Test func mathFenceLanguage() {
        #expect(MathExtractor.isMathFence(language: "math"))
        #expect(MathExtractor.isMathFence(language: "Math"))
        #expect(MathExtractor.isMathFence(language: "math \u{E000}0:x\u{E001}"))
        #expect(!MathExtractor.isMathFence(language: "mathematica"))
        #expect(!MathExtractor.isMathFence(language: ""))
        #expect(!MathExtractor.isMathFence(language: nil))
    }

    /// The info string is split on ASCII bytes, as cmark-gfm splits it, not on graphemes:
    /// a space or tab that a combining mark or Prepend scalar has joined to its neighbour
    /// is still a separator, and a mark stuck to the language still makes it another word.
    @Test func mathFenceLanguageIsReadOnBytesNotGraphemes() {
        // A combining mark on the separating space: `math` is still the language.
        #expect(MathExtractor.isMathFence(language: "math \u{0301}rest"))
        #expect(MathExtractor.isMathFence(language: "math\t\u{0301}rest"))
        // A Prepend scalar sits in the word before it, as cmark-gfm also reads it, so the
        // language is `math\u{0600}` and not `math`.
        #expect(!MathExtractor.isMathFence(language: "math\u{0600} rest"))
        // A mark on the language itself is part of it, so it is not `math`.
        #expect(!MathExtractor.isMathFence(language: "math\u{0301} rest"))
        #expect(!MathExtractor.isMathFence(language: "\u{0301}math"))
        // Leading separators are skipped, as `split(whereSeparator:)` skipped them.
        #expect(MathExtractor.isMathFence(language: "  \tmath  "))

        // The placeholder form follows the same split, and the nonce still gates it.
        let extraction = extract("$$\n\\sum x\n$$\n")
        #expect(extraction.expressionCount == 1)
        #expect(MathExtractor.blockPlaceholderIndex(info: "math \u{E000}0:\(nonce)\u{E001}", nonce: nonce) == 0)
        #expect(MathExtractor.blockPlaceholderIndex(info: "math \u{0301}\u{E000}0:\(nonce)\u{E001}", nonce: nonce) == nil)
        #expect(MathExtractor.blockPlaceholderIndex(info: "Math \u{E000}0:\(nonce)\u{E001}", nonce: nonce) == nil)
    }

    /// A fence's code is trimmed of its final line ending on bytes: `hasSuffix("\n")` is
    /// false for code ending in CR LF, whose last grapheme is the pair, and `dropLast()`
    /// would then have dropped both.
    @Test func authoredFenceCodeLosesOnlyItsFinalLineEnding() {
        let extraction = extract("```math\nx\n```")
        #expect(extraction.tex(forMathFence: "math", code: "x\n") == "x")
        #expect(extraction.tex(forMathFence: "math", code: "x\r\n") == "x")
        #expect(extraction.tex(forMathFence: "math", code: "x") == "x")
        #expect(extraction.tex(forMathFence: "math", code: "a\nb\n") == "a\nb")
        #expect(extraction.tex(forMathFence: "math", code: "") == "")
        #expect(extraction.tex(forMathFence: "math", code: "\n") == "")
    }

    // MARK: Skipped regions

    @Test(arguments: [
        "```\n$x$\n```",
        "~~~~\n$x$\n~~~\n$y$\n~~~~",
        "```swift\nlet a = \"$x$\"\n```",
        "    $x$",
        "\t$x$",
        "text\n\n    $x$\n\n    $y$",
        "- item\n\n  ```\n  $x$\n  ```",
        "- item\n    - nested\n\n      ```\n      $x$\n      ```",
        "> ```\n> $x$\n> ```",
        "[a](x$y$z)",
        "![i]($x$.png \"$t$\")",
        "![$x$](i.png)",
        "[a](<x $y$ z>)",
        "[a][$x$]\n\n[$x$]: /u",
        "[a](u \"$x$\")",
        "<a title=\"$x$\">",
        "<a title='$x$'\n  data-y=\"$y$\">",
        "<https://example.com/$x$>",
        "<a$b$c@example.com>",
        "[ref]: https://example.com/$x$",
        "<div>\n$x$\n</div>",
        "<script>\n\n$x$\n\n</script>",
        "<!--\n$x$\n\n$y$\n-->",
        "<custom-tag>\n$x$",
    ])
    func codeLinksAndHTMLAreUntouched(body: String) {
        assertUntouched(body)
    }

    @Test func textAroundSkippedRegionsIsStillScanned() {
        #expect(math(extract("[link $x$](u) $y$")).count == 2)
        #expect(math(extract("<b>$x$</b>")).count == 1)
        #expect(math(extract("text\n    $x$")).count == 1)  // paragraph continuation, not code
        #expect(math(extract("```\ncode\n```\n$x$")).count == 1)
        #expect(math(extract("<div>\n$a$\n\n$x$")) == [.math(tex: "x", display: false)])
        #expect(math(extract("text\n<span>$x$</span>")).count == 1)
        #expect(math(extract("> ```\n> code\n\n$x$")).count == 1)
        #expect(math(extract("$|x|$ and a | b")).count == 1)
        #expect(math(extract("[a][$x$]")).count == 1)  // no definition: plain text
        #expect(math(extract("then x](`y) and `$z$`")) == [.math(tex: "z", display: false)])
    }

    @Test func mathStaysInsideTableCells() {
        let extraction = extract("| a | b | c |\n|---|:-:|---|\n| $x|y$ | $z$ |")
        #expect(math(extraction) == [.math(tex: "z", display: false)])
    }

    // MARK: Verifier regressions

    /// F1: an indented code block after a setext heading is code.
    @Test(arguments: ["Title\n=====\n    code $x$ here\n", "Title\n-\n    let price = $a$\n"])
    func indentedCodeAfterSetextHeading(body: String) {
        assertUntouched(body)
    }

    /// F2: a rewrite may not turn a paragraph into a fence that swallows the document.
    @Test func rewriteCannotCreateAFence() {
        assertUntouched("```$`$ rest\n\nLater paragraph\n")
        let extraction = extract("```$`$ rest\n\nLater paragraph $y$\n")
        #expect(extraction.markdown == "```$`$ rest\n\nLater paragraph \u{E000}0:\(nonce)\u{E001}\n")
        #expect(math(extraction) == [.math(tex: "y", display: false)])
        let blocks = descendants(Document(parsing: extraction.markdown)).filter { $0 is CodeBlock }
        #expect(blocks.isEmpty)
    }

    /// F3: quotes nested in list items.
    @Test(arguments: ["- > ```\n  > let s = $x$\n  > ```\n", "- > <div>\n  > $x$\n  > </div>\n"])
    func quoteInsideListItem(body: String) {
        assertUntouched(body)
    }

    /// F4: multi-line link reference definitions.
    @Test(arguments: [
        "[ref]:\n  https://example.com/$x$\n\n[ref]\n",
        "[ref]: /url\n  \"Title $x$\"\n\n[ref]\n",
        "[a]: <b $x$>\n\n[a]\n",
        "[r]: /u\n  \"t $x$\"\nfollowing $y$ text\n\n[r]\n",
    ])
    func linkReferenceDefinitions(body: String) {
        let extraction = extract(body)
        #expect(extraction.markdown.contains("$x$"))
        #expect(!math(extraction).contains(.math(tex: "x", display: false)))
        #expect(invariantViolation(body) == nil)
    }

    /// F5: removing math must not create links or HTML.
    @Test(arguments: ["[see]($a + b$) now\n", "<a f=\"$\"$\">\n", "](`)$:$`"])
    func rewriteCannotCreateStructure(body: String) {
        assertUntouched(body)
    }

    @Test func mappedPositionsHandleWideCharactersAndContainers() {
        let cases: [(String, [String])] = [
            ("中文 `碼` 😀 $x$ <i>$y$</i>", ["x", "y"]),
            ("> 引用 `$no$`\n> 第二行 `c` $a$\n懶惰 `d` $b$", ["a", "b"]),
            ("- 項目 `$no$`\n  續行 😀😀 `c` $a$\n\n  段落 `$no$` $b$", ["a", "b"]),
            ("  前導 `$no$`\n      續 `c` $a$", ["a"]),
            (">\t表 `$no$`\n>\t😀 `c` $a$", ["a"]),
            ("| 中 `$no$` | 😀 $a$ |\n|---|---|\n| `$no$` 表 | $b$ 😀 |", ["a", "b"]),
            ("é\u{301} $a$ `$no$` 👨‍👩‍👧 $b$", ["a", "b"]),
        ]
        for (body, expected) in cases {
            let tex = math(extract(body)).map { if case .math(let tex, _) = $0 { tex } else { "" } }
            #expect(tex == expected, "\(body)")
            #expect(invariantViolation(body) == nil, "\(body)")
        }
    }

    @Test func unreliablePositionsFailClosed() {
        // cmark-gfm misreports positions after a backslash hard break and multi-line links;
        // either the math is found correctly or the container is left alone.
        for body in [
            "a\\\nb `$no$` $x$",
            "a [b](\n  u \"t\"\n) `$no$`\nf `g` $x$",
            "  a <b\n  c=\"x\"> d `$no$` $x$",
            "[r]: /u\na `$no$` $x$\nc `d`",
            "$http:*\"\r-\r\n$$`$/$)b```)_>1&!",
        ] {
            #expect(invariantViolation(body) == nil, "\(body)")
            #expect(!math(extract(body)).contains(.math(tex: "no", display: false)), "\(body)")
        }
    }

    @Test func randomInputsKeepTheInvariants() {
        let alphabet: [String] = [
            "$", "$", "$", "$$", "`", "`", "\\", "<", "[", "]", "(", ")", ">", "-", "|", "\n", "\n", "a", "b",
            " ", " ", "*", "_", "#", "!", "\"", ":", "\r", "\r\n", "\t", "1", "    ", "- ", "> ", "```",
            "$$\n", "\n$$", "<div>", "<a href=\"", "](", "[x]: ", "---", "|-|", "=", "'", "1. ", "<!--", "-->",
        ]
        var generator = SplitMix(state: 42)
        for _ in 0..<3000 {
            let length = Int.random(in: 1...30, using: &generator)
            let body = (0..<length).map { _ in alphabet.randomElement(using: &generator)! }.joined()
            if let violation = invariantViolation(body) {
                Issue.record("\(body.debugDescription): \(violation)")
                return
            }
        }
    }

    // MARK: Placeholders

    @Test func forgedPlaceholdersStayText() {
        let forged = "\u{E000}0:0000000000000000\u{E001}"
        let extraction = MathExtractor.extract(from: "real $x$ and \(forged)")
        #expect(extraction.segments(in: extraction.markdown) == [
            .text("real "), .math(tex: "x", display: false), .text(" and \(forged)"),
        ])

        // CommonMark decodes character references, so a document can smuggle the delimiters in.
        let entities = MathExtractor.extract(from: "$x$ &#xE000;0:0000000000000000&#xE001; &#57344;0:0&#57345;")
        let texts = descendants(Document(parsing: entities.markdown)).compactMap { $0 as? Text }
        let segments = texts.flatMap { entities.segments(in: $0.string) }
        #expect(segments == [
            .math(tex: "x", display: false),
            .text(" \u{E000}0:0000000000000000\u{E001} \u{E000}0:0\u{E001}"),
        ])
    }

    @Test func onlyWellFormedPlaceholdersExpand() {
        let extraction = extract("$x$")
        let good = "\u{E000}0:\(nonce)\u{E001}"
        #expect(extraction.segments(in: good) == [.math(tex: "x", display: false)])
        for bad in [
            "\u{E000}1:\(nonce)\u{E001}",  // index out of range
            "\u{E000}00:\(nonce)\u{E001}",  // leading zero
            "\u{E000}0:\(nonce.uppercased())\u{E001}",
            "\u{E000}0:\(nonce)0\u{E001}",
            "\u{E000}0:\(nonce)",
            "\u{E000}\u{E001}",
            "\u{E001}\u{E000}",
        ] {
            #expect(extraction.segments(in: bad) == [.text(bad)])
        }
        #expect(extraction.segments(in: "\u{E000}" + good + "\u{E001}") == [
            .text("\u{E000}"), .math(tex: "x", display: false), .text("\u{E001}"),
        ])
        #expect(extraction.segments(in: "") == [])
    }

    @Test func noncesAreFreshAndSixteenHexDigits() {
        let first = MathExtractor.extract(from: "$x$")
        let second = MathExtractor.extract(from: "$x$")
        #expect(first.nonce != second.nonce)
        #expect(first.nonce.count == 16)
        #expect(first.nonce.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        var generator = FixedGenerator(value: 0xAB)
        #expect(MathExtractor.extract(from: "", using: &generator).nonce == "00000000000000ab")
    }

    // MARK: Limits

    @Test func overlongExpressionsStaySource() {
        let limit = MathExtractor.maxExpressionLength
        let longest = "$" + String(repeating: "a", count: limit) + "$"
        #expect(extract(longest).expressionCount == 1)
        assertUntouched("$" + String(repeating: "a", count: limit + 1) + "$")
        // Measured in Unicode scalars, not bytes.
        #expect(extract("$" + String(repeating: "é", count: limit) + "$").expressionCount == 1)
        #expect(extract("$" + String(repeating: "😀", count: limit) + "$").expressionCount == 1)
        assertUntouched("$$" + String(repeating: "é", count: limit + 1) + "$$")
        // A display paragraph: the TeX includes the two newlines.
        #expect(extract("$$\n" + String(repeating: "a", count: limit - 2) + "\n$$").expressionCount == 1)
        assertUntouched("$$\n" + String(repeating: "a", count: limit - 1) + "\n$$")
        // An overlong display paragraph is left alone entirely, including math-like text inside it.
        assertUntouched("$$\n$x$ " + String(repeating: "a", count: limit) + "\n$$")
    }

    @Test func onlyTheFirstExpressionsAreExtracted() {
        let count = MathExtractor.maxExpressionCount
        let body = Array(repeating: "$x$", count: count + 5).joined(separator: " ")
        let extraction = extract(body)
        #expect(extraction.expressionCount == count)
        #expect(extraction.markdown.hasSuffix(Array(repeating: "$x$", count: 5).joined(separator: " ")))

        let blocks = Array(repeating: "$x$", count: count).joined(separator: " ") + "\n\n$$\ny\n$$\n\n$z$"
        let blockExtraction = extract(blocks)
        #expect(blockExtraction.expressionCount == count)
        #expect(blockExtraction.markdown.hasSuffix("\n\n$$\ny\n$$\n\n$z$"))
    }

    @Test func bodiesOverTheSizeLimitAreNotScanned() {
        let filler = String(repeating: "a", count: MathExtractor.maxBodyBytes - "$x$\n".utf8.count)
        #expect(extract("$x$\n" + filler).expressionCount == 1)
        assertUntouched("$x$\n" + filler + "b")
    }

    /// Past `maxBlocks` block nodes the body comes back unchanged. Reachable on its own,
    /// with 60,000 paragraphs: 120,003 cmark nodes, under `ParseLimits.defaultMaxNodes`,
    /// and 180 KB, under `maxBodyBytes`, so this is the extractor's own guard firing.
    @Test func bodiesWithTooManyBlocksAreNotRewritten() {
        let paragraphs = String(repeating: "b\n\n", count: 60_000) + "$x$\n"
        #expect(paragraphs.utf8.count < MathExtractor.maxBodyBytes)
        #expect(CMarkDepthScan.measure(paragraphs).nodes < ParseLimits.defaultMaxNodes)
        assertUntouched(paragraphs)
        let fewer = String(repeating: "b\n\n", count: 1_000) + "$x$\n"
        #expect(extract(fewer).expressionCount == 1)
    }

    /// cmark-gfm pads short rows to the header's width, so a small file can hold a huge
    /// table. That one the parsing worker now refuses outright, before the extractor sees
    /// a tree, and the body comes back unchanged all the same.
    @Test func wideTablesAreRefusedByTheParsingBudget() {
        let header = Array(repeating: "a", count: 128).joined(separator: "|")
        let delimiter = Array(repeating: "-", count: 128).joined(separator: "|")
        let wide = header + "\n" + delimiter + "\n$x$\n" + String(repeating: "b\n", count: 5_000)
        let refused = MarkdownParsing.withDocument(wide) { outcome -> Bool in
            if case .tooComplex = outcome { return true } else { return false }
        }
        #expect(refused)
        assertUntouched(wide)
        let narrow = "a|b\n-|-\n$x$|y\n" + String(repeating: "b|c\n", count: 1_000)
        #expect(extract(narrow).expressionCount == 1)
    }

    // MARK: The parsing worker and its budgets

    /// Two bodies past `maxDepth`, one nested in block quotes and one in images.
    static let overBudgetBodies: [String] = {
        let quoted = String(repeating: ">", count: 300) + " $x^2$\n"
        let images = String(repeating: "![", count: 300) + "$x$" + String(repeating: "](u)", count: 300) + "\n"
        return [quoted, images]
    }()

    @Test func extractionRunsOnAParsingWorker() {
        #expect(!MarkdownParsing.isOnWorker)
        let deep = NestingShape.blockQuotes.source(depthAtMost: ParseLimits.default.maxDepth - 2).source
            + "\nA paragraph with $x^2$ in it.\n"
        let fromSmallStack = onSmallStackThread { MathExtractor.extract(from: deep).expressionCount }
        #expect(fromSmallStack == 1)
        // Nested inside a body it runs inline on the worker already open.
        let fromWorker = MarkdownParsing.withDocument("") { _ in
            MathExtractor.extract(from: deep).expressionCount
        }
        #expect(fromWorker == 1)
    }

    /// Over a budget there is no tree to check a rewrite against, so the body comes back
    /// as written, the same answer as a body with no `$` in it. Such a body renders as
    /// escaped source, where the TeX belongs verbatim anyway.
    @Test(arguments: overBudgetBodies)
    func bodiesOverABudgetComeBackUnchanged(body: String) {
        let refused = MarkdownParsing.withDocument(body) { outcome -> Bool in
            if case .document = outcome { return false } else { return true }
        }
        #expect(refused, "this input must be over a budget for the test to mean anything")
        assertUntouched(body)
    }

    /// An expression's TeX is a run of bytes from one line of the body, so its own tree is
    /// a sub-tree of the body's: a body the worker accepted can't hold TeX the worker
    /// refuses. The guard on that parse is therefore defensive, and this records why there
    /// is no input for it: the deepest inline nesting reachable inside an accepted body is
    /// itself accepted.
    @Test func texIsNeverDeeperThanTheBodyItCameFrom() {
        let stars = String(repeating: "*", count: 300)
        let body = "Text $\(stars)a\(stars)$ more.\n"
        let bodyDepth = CMarkDepthScan.maximumDepth(of: body)
        let texDepth = CMarkDepthScan.maximumDepth(of: "\(stars)a\(stars)")
        #expect(texDepth <= bodyDepth)
        #expect(bodyDepth <= ParseLimits.default.maxDepth - 2)
        #expect(extract(body).expressionCount == 1)
    }

    @Test func frontMatterIsTheCallersToSplit() {
        let file = "---\nprice: $9.99$\n---\n\nBody with $x$.\n"
        let (_, body, offset) = FrontMatter.split(file)
        #expect(offset == 3)
        let split = extract(String(body))
        #expect(split.expressionCount == 1)
        // Passed the whole file, the front matter is scanned like any other text.
        #expect(extract(file).expressionCount == 2)
    }

    @Test func pathologicalInputsFinish() {
        let size = 60_000
        let inputs = [
            String(repeating: "$a ", count: size / 3) + "b$",
            String(repeating: "](", count: size / 2),
            String(repeating: "`` ` ", count: size / 5),
            String(repeating: "<a b=\"", count: size / 6),
            String(repeating: "<!-- ", count: size / 5),
            String(repeating: "$$a\n", count: size / 4),
            String(repeating: "$$ ", count: size / 3),
            String(repeating: "\\", count: size) + "$x$",
        ]
        for input in inputs {
            _ = extract(input)
        }
    }

    /// F6: the extractor's own work stays linear, measured on nesting cmark-gfm survives.
    /// (swift-markdown itself overflows the stack on very deep nesting, so the work runs
    /// on a thread with a large stack.)
    ///
    /// The baseline is the shape the extractor now has: one worker holding two guarded
    /// parses, the body's and the rewrite's. A bare `Document(parsing:)` would leave the
    /// pre-scans and the worker's own cost charged to the extractor, and two separate
    /// guarded parses would charge it one worker too few, which on this input is larger
    /// than the work being measured.
    @Test func nestedListsScaleLinearly() {
        @Sendable func line(_ depth: Int) -> String { String(repeating: "- ", count: depth) + "$x$" }
        @Sendable func seconds(_ body: String, _ work: (String) -> Void) -> Double {
            var best = Double.infinity
            for _ in 0..<5 {
                let start = ContinuousClock.now
                work(body)
                let elapsed = ContinuousClock.now - start
                best = min(best, Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
            }
            return best
        }
        final class Results: @unchecked Sendable { var values: [(extract: Double, parse: Double)] = [] }
        let box = Results()
        let done = DispatchSemaphore(value: 0)
        let thread = Thread { @Sendable in
            for copies in [10, 40] {
                let body = Array(repeating: line(500), count: copies).joined(separator: "\n\n")
                let parse = seconds(body) { source in
                    // One worker, two parses: what extraction costs before its own work.
                    MarkdownParsing.withDocument(source) { _ in
                        MarkdownParsing.withDocument(source) { _ in }
                    }
                }
                let total = seconds(body) { _ = MathExtractor.extract(from: $0) }
                box.values.append((total, parse))
            }
            done.signal()
        }
        thread.stackSize = 64 << 20
        thread.start()
        done.wait()
        let results = box.values
        #expect(results.count == 2)
        guard results.count == 2 else { return }
        // Two guarded parses plus linear work: what the extractor adds beyond parsing grows
        // linearly with the input (F18), which is the property that catches a quadratic
        // regression. The bound is relative to what this machine just measured, because these
        // are wall-clock figures from a machine that may be running anything else. A fixed cap
        // of 0.1s failed on a 3-CPU CI runner at 0.1018s, and a cap of "less than one parse"
        // failed in release at 0.0353s against 0.0341s, both with nothing wrong
        // (mars-dawn-kit#15).
        let ownSmall = max(results[0].extract - results[0].parse, 0.002)
        let ownLarge = max(results[1].extract - results[1].parse, 0)
        #expect(ownLarge < ownSmall * 4 * 3 + 0.05, "\(ownSmall)s → \(ownLarge)s")
    }

    // MARK: swift-markdown

    @Test func placeholdersSurviveParsing() throws {
        let body = """
            # Title $E=mc^2$

            Some *emphasis with $a*b$ inside* and [a link $x<y$](https://example.com/p?q=$1$).
            Forged &#xE000;3:\(nonce)&#xE001; stays text.

            $$
            \\sum_{i=1}^n i < \\infty
            $$

            | col | $t$ |
            |-----|-----|
            | **$u_1$** | 2 |
            """
        let extraction = extract(body)
        let document = Document(parsing: extraction.markdown)
        let nodes = descendants(document)

        let texts = nodes.compactMap { $0 as? Text }
        let expanded = texts.flatMap { extraction.segments(in: $0.string) }
        let expressions = expanded.compactMap { segment -> String? in
            if case .math(let tex, false) = segment { return tex }
            return nil
        }
        #expect(expressions == ["E=mc^2", "a*b", "x<y", "t", "u_1"])

        let emphasis = try #require(nodes.compactMap { $0 as? Emphasis }.first)
        #expect(emphasis.children.compactMap { ($0 as? Text).map { extraction.segments(in: $0.string) } } == [
            [.text("emphasis with "), .math(tex: "a*b", display: false), .text(" inside")],
        ])
        let link = try #require(nodes.compactMap { $0 as? Link }.first)
        #expect(link.destination == "https://example.com/p?q=$1$")
        #expect(link.children.compactMap { ($0 as? Text).map { extraction.segments(in: $0.string) } } == [
            [.text("a link "), .math(tex: "x<y", display: false)],
        ])

        // The entity-decoded forgery carries the real nonce but an index that is a display block's.
        #expect(expanded.contains(.text("Forged \u{E000}3:\(nonce)\u{E001} stays text.")))
        #expect(nodes.contains { $0 is InlineHTML } == false)

        let block = try #require(nodes.compactMap { $0 as? CodeBlock }.first)
        #expect(MathExtractor.isMathFence(language: block.language))
        #expect(block.code == "\\sum_{i=1}^n i < \\infty\n")
        #expect(extraction.tex(forMathFence: block.language, code: block.code) == "\n\\sum_{i=1}^n i < \\infty\n")
        #expect(block.range?.lowerBound.line == 6)
        let table = try #require(nodes.compactMap { $0 as? Markdown.Table }.first)
        #expect(table.range?.lowerBound.line == 10)
    }

    /// cmark-gfm gives the paragraph it splits off before a table no source range. A forged
    /// placeholder there must not expand into another container's math.
    @Test(arguments: [
        "p &#xE000;0:\(nonce)&#xE001;\nh\n-|\n$x$",
        "$x$\n\n&#xE000;0:\(nonce)&#xE001;\n]\n-|",
    ])
    func forgedPlaceholderInRangelessParagraphNeverExpands(body: String) {
        #expect(invariantViolation(body) == nil)
        let extraction = extract(body)
        let document = Document(parsing: extraction.markdown)
        let expanded = descendants(document).compactMap { $0 as? Text }.flatMap { extraction.segments(in: $0.string) }
        #expect(expanded.filter { if case .math = $0 { true } else { false } }.count <= 1)
    }
}
