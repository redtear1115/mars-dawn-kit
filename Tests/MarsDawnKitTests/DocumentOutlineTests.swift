import Testing
@testable import MarsDawnKit

struct DocumentOutlineTests {
    @Test func atxHeadingLevelsOneThroughSix() {
        let markdown = "# H1\n## H2\n### H3\n#### H4\n##### H5\n###### H6\n"
        let outline = DocumentOutline(markdownBody: markdown)
        #expect(outline.headings.map(\.level) == [1, 2, 3, 4, 5, 6])
        #expect(outline.headings.map(\.title) == ["H1", "H2", "H3", "H4", "H5", "H6"])
        #expect(outline.headings.map(\.line) == [1, 2, 3, 4, 5, 6])
    }

    @Test func setextHeadings() {
        let markdown = "Title One\n=========\n\nTitle Two\n---------\n"
        let outline = DocumentOutline(markdownBody: markdown)
        #expect(outline.headings.count == 2)
        #expect(outline.headings[0].level == 1)
        #expect(outline.headings[0].title == "Title One")
        #expect(outline.headings[0].line == 1)
        #expect(outline.headings[1].level == 2)
        #expect(outline.headings[1].title == "Title Two")
        #expect(outline.headings[1].line == 4)
    }

    @Test func inlineMarkupIsResolvedToPlainText() {
        let markdown = "# a *b* [c](u) `d` ![e](x)"
        let outline = DocumentOutline(markdownBody: markdown)
        #expect(outline.headings.count == 1)
        #expect(outline.headings[0].title == "a b c d e")
    }

    @Test func headingLikeLineInFencedCodeBlockIsNotAHeading() {
        let markdown = "# Real\n\n```\n# Not a heading\n```\n"
        let outline = DocumentOutline(markdownBody: markdown)
        #expect(outline.headings.count == 1)
        #expect(outline.headings[0].title == "Real")
    }

    @Test func headingLikeLineInIndentedCodeBlockIsNotAHeading() {
        let markdown = "# Real\n\n    # Not a heading\n"
        let outline = DocumentOutline(markdownBody: markdown)
        #expect(outline.headings.count == 1)
        #expect(outline.headings[0].title == "Real")
    }

    @Test func headingInsideBlockQuoteIsIncluded() {
        let markdown = "> # Quoted heading\n"
        let outline = DocumentOutline(markdownBody: markdown)
        #expect(outline.headings.count == 1)
        #expect(outline.headings[0].title == "Quoted heading")
    }

    @Test func lineOffsetShiftsEveryLine() {
        let markdown = "# One\n\n## Two\n"
        let outline = DocumentOutline(markdownBody: markdown, lineOffset: 5)
        #expect(outline.headings.map(\.line) == [6, 8])
    }

    @Test func crlfLineEndings() {
        let markdown = "# One\r\n\r\n## Two\r\n"
        let outline = DocumentOutline(markdownBody: markdown)
        #expect(outline.headings.map(\.line) == [1, 3])
        #expect(outline.headings.map(\.title) == ["One", "Two"])
    }

    @Test func emptyBodyGivesNoHeadings() {
        #expect(DocumentOutline(markdownBody: "").headings.isEmpty)
    }

    @Test func sectionIndexBeforeFirstHeadingIsNil() {
        let outline = DocumentOutline(markdownBody: "Intro text.\n\n# First\n")
        #expect(outline.sectionIndex(containingLine: 1) == nil)
    }

    @Test func sectionIndexExactlyOnAHeading() {
        let outline = DocumentOutline(markdownBody: "# First\n\n## Second\n")
        #expect(outline.sectionIndex(containingLine: 1) == 0)
        #expect(outline.sectionIndex(containingLine: 3) == 1)
    }

    @Test func sectionIndexBetweenHeadings() {
        let outline = DocumentOutline(markdownBody: "# First\n\nBody.\n\n## Second\n")
        #expect(outline.sectionIndex(containingLine: 2) == 0)
    }

    @Test func sectionIndexAfterLastHeading() {
        let outline = DocumentOutline(markdownBody: "# First\n\n## Second\n\nBody.\n")
        #expect(outline.sectionIndex(containingLine: 100) == 1)
    }

    // MARK: The parsing worker and its budgets

    /// One body past `maxDepth`, one past `maxNodes` (cmark-gfm pads a table's short rows
    /// to the header's width), each holding a heading that would otherwise be found.
    static let overBudgetBodies: [String] = {
        let tooDeep = String(repeating: ">", count: 300) + " # Quoted heading\n"
        let header = Array(repeating: "a", count: 128).joined(separator: "|")
        let delimiter = Array(repeating: "-", count: 128).joined(separator: "|")
        let filler = String(repeating: "b\n", count: 5_000)
        let tooComplex = header + "\n" + delimiter + "\n" + filler + "\n# A heading\n"
        return [tooDeep, tooComplex]
    }()

    @Test func headingsAreCollectedOnAParsingWorker() {
        #expect(!MarkdownParsing.isOnWorker)
        let deep = NestingShape.blockQuotes.source(depthAtMost: ParseLimits.default.maxDepth - 2).source
            + "\n# Heading after the deep part\n"
        let fromSmallStack = onSmallStackThread { DocumentOutline(markdownBody: deep) }
        #expect(fromSmallStack == DocumentOutline(markdownBody: deep))
        #expect(fromSmallStack.headings.map(\.title) == ["Heading after the deep part"])
    }

    /// Over a budget there is no tree, so there are no headings: the preview shows such a
    /// body as escaped source, which has no headings in it either.
    @Test(arguments: overBudgetBodies)
    func bodiesOverABudgetHaveNoHeadings(body: String) {
        let refused = MarkdownParsing.withDocument(body) { outcome -> Bool in
            if case .document = outcome { return false } else { return true }
        }
        #expect(refused, "this input must be over a budget for the test to mean anything")
        #expect(DocumentOutline(markdownBody: body).headings.isEmpty)
        #expect(DocumentOutline(markdownBody: body, lineOffset: 7).sectionIndex(containingLine: 9) == nil)
    }

    @Test func lineOffsetIsTheOneFrontMatterSplitReturns() {
        let file = "---\ntitle: Notes\n---\n# First\n\n## Second\n"
        let (frontMatter, body, offset) = FrontMatter.split(file)
        #expect(frontMatter?.lineRange == 1...3)
        #expect(offset == 3)
        let outline = DocumentOutline(markdownBody: String(body), lineOffset: offset)
        // Lines 4 and 6 of the file.
        #expect(outline.headings.map(\.line) == [4, 6])
        #expect(outline.headings.map(\.title) == ["First", "Second"])
    }

    @Test func frontMatterIsTheCallersToSplit() {
        // Passed the whole file, the closing `---` reads as a setext underline instead.
        let file = "---\ntitle: Notes\n---\n\nBody.\n"
        #expect(DocumentOutline(markdownBody: file).headings.map(\.title) == ["title: Notes"])
        let (_, body, offset) = FrontMatter.split(file)
        #expect(DocumentOutline(markdownBody: String(body), lineOffset: offset).headings.isEmpty)
    }

    @Test func performanceOnALargeDocument() {
        var lines: [String] = []
        for i in 0..<5000 {
            lines.append("# Heading \(i)")
        }
        let markdown = lines.joined(separator: "\n")

        let start = ContinuousClock.now
        let outline = DocumentOutline(markdownBody: markdown)
        let elapsed = start.duration(to: .now)

        #expect(outline.headings.count == 5000)
        #expect(outline.headings.last?.title == "Heading 4999")
        #expect(elapsed < .seconds(3))
    }
}
