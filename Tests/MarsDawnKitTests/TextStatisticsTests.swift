import Testing
@testable import MarsDawnKit

struct TextStatisticsTests {
    @Test func mixedCJKAndLatinWords() {
        let stats = TextStatistics(plainText: "Hello 世界")
        #expect(stats.words == 3)
        #expect(stats.nonCJKWordCount == 1)
        #expect(stats.cjkWordCount == 2)
        #expect(stats.characters == 7)
    }

    @Test func hiraganaCountsEachCharacter() {
        #expect(TextStatistics(plainText: "こんにちは").words == 5)
    }

    @Test func hangulCountsEachSyllable() {
        #expect(TextStatistics(plainText: "안녕하세요").words == 5)
    }

    @Test func apostrophesAndHyphensDontSplitWords() {
        #expect(TextStatistics(plainText: "don't stop well-known 123").words == 4)
    }

    @Test func emojiAndPunctuationAreNotWords() {
        #expect(TextStatistics(plainText: "🙂 !!! —").words == 0)
    }

    @Test func lineCountEdgeCases() {
        #expect(TextStatistics(plainText: "").lines == 0)
        #expect(TextStatistics(plainText: "a").lines == 1)
        #expect(TextStatistics(plainText: "a\n").lines == 1)
        #expect(TextStatistics(plainText: "a\nb").lines == 2)
        #expect(TextStatistics(plainText: "a\r\nb").lines == 2)
        #expect(TextStatistics(plainText: "a\r\n").lines == 1)
    }

    @Test func charactersExcludeWhitespaceAndNewlines() {
        let stats = TextStatistics(plainText: "a b\nc")
        #expect(stats.characters == 3)
        #expect(stats.charactersWithSpaces == 4)
    }

    @Test func readingTimeRoundsUpWithAMinimumOfOneWordPresent() {
        let twoFifty = String(repeating: "word ", count: 250)
        #expect(TextStatistics(plainText: twoFifty).readingMinutes == 1)

        let twoFiftyOne = String(repeating: "word ", count: 251)
        #expect(TextStatistics(plainText: twoFiftyOne).readingMinutes == 2)

        let fourHundredCJK = String(repeating: "字", count: 400)
        #expect(TextStatistics(plainText: fourHundredCJK).readingMinutes == 1)

        #expect(TextStatistics(plainText: "").readingMinutes == 0)
    }

    @Test func markdownBodyCountsOnlyReadableText() {
        let markdown = "# Title\n\nSee [docs](https://example.com/very/long) and ![图](a.png).\n\n```swift\nlet x = 1\n```\n"
        let stats = TextStatistics(markdownBody: markdown)
        #expect(stats.words == 8)
        #expect(stats.nonCJKWordCount == 7)
        #expect(stats.cjkWordCount == 1)
        #expect(stats.lines == 7)
    }

    @Test func markdownBodyLineCountIsSourceLinesNotRenderedText() {
        let markdown = "# Title\n\nBody text.\n"
        let stats = TextStatistics(markdownBody: markdown)
        #expect(stats.lines == 3)
    }

    // MARK: The parsing worker and its budgets

    /// One body past `maxDepth`, one past `maxNodes` (cmark-gfm pads a table's short rows
    /// to the header's width).
    static let overBudgetBodies: [String] = {
        let tooDeep = String(repeating: ">", count: 300) + " hello world\n"
        let header = Array(repeating: "a", count: 128).joined(separator: "|")
        let delimiter = Array(repeating: "-", count: 128).joined(separator: "|")
        let filler = String(repeating: "b\n", count: 5_000)
        return [tooDeep, header + "\n" + delimiter + "\n" + filler]
    }()

    @Test func markdownBodyIsCountedOnAParsingWorker() {
        #expect(!MarkdownParsing.isOnWorker)
        // Deep enough to overflow the calling thread's stack if it were parsed there.
        let deep = NestingShape.blockQuotes.source(depthAtMost: ParseLimits.default.maxDepth - 2).source
        let fromSmallStack = onSmallStackThread { TextStatistics(markdownBody: deep) }
        #expect(fromSmallStack == TextStatistics(markdownBody: deep))
        #expect(fromSmallStack.words == 1)
    }

    /// Over a budget there is no tree, so the body is counted as the plain text it is.
    /// The counts then include Markdown markers and URLs; `lines` is unaffected.
    @Test(arguments: overBudgetBodies)
    func bodiesOverABudgetAreCountedAsPlainText(body: String) {
        let refused = MarkdownParsing.withDocument(body) { outcome -> Bool in
            if case .document = outcome { return false } else { return true }
        }
        #expect(refused, "this input must be over a budget for the test to mean anything")
        #expect(TextStatistics(markdownBody: body) == TextStatistics(plainText: body))
    }

    @Test func aParsedBodyIsNotJustItsPlainText() {
        // The same comparison as above, on a body that does parse, must differ: otherwise
        // the budget test would pass even if the fallback never ran.
        let body = "# Title\n\nSee [docs](https://example.com/very/long).\n"
        #expect(TextStatistics(markdownBody: body) != TextStatistics(plainText: body))
    }

    @Test func frontMatterIsTheCallersToSplit() {
        let file = "---\ntitle: Notes\n---\n\nBody text here.\n"
        let (_, body, _) = FrontMatter.split(file)
        let split = TextStatistics(markdownBody: String(body))
        #expect(split.words == 3)
        // Passing the whole file instead counts the front matter as prose.
        #expect(TextStatistics(markdownBody: file).words > split.words)
    }

    @Test func performanceOnALargeDocument() {
        var lines: [String] = []
        for i in 0..<5000 {
            lines.append("Line number \(i) has some words, 世界 and `code`.")
        }
        let markdown = lines.joined(separator: "\n")

        let start = ContinuousClock.now
        let stats = TextStatistics(markdownBody: markdown)
        let elapsed = start.duration(to: .now)

        #expect(stats.lines == 5000)
        #expect(stats.words > 0)
        #expect(elapsed < .seconds(3))
    }
}
