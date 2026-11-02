#if os(macOS)
import Foundation
import Testing
@testable import MarsDawnExport

/// `DocumentImageRenderer`'s pure parts (kit #243): where the page is cut, which lines a heading's
/// section covers, and how lines are counted. No page is loaded.
struct DocumentImageSlicingTests {
    typealias Block = DocumentImageRenderer.Block

    /// Blocks of the given heights, 20 px apart, starting at 40, each on its own ten lines.
    static func blocks(_ heights: [Int], headings: Set<Int> = []) -> [Block] {
        var top = 40
        return heights.enumerated().map { index, height in
            defer { top += height + 20 }
            return Block(top: top, bottom: top + height, firstLine: index * 10 + 1, lastLine: index * 10 + 10, keepsWithNext: headings.contains(index))
        }
    }

    static func pageBottom(_ blocks: [Block]) -> Int { blocks.last!.bottom + 40 }

    @Test func aShortPageIsOneSliceOfTheWholePage() {
        let blocks = Self.blocks([100, 200, 300])
        let slices = DocumentImageRenderer.slices(blocks: blocks, pageBottom: Self.pageBottom(blocks), maxHeight: 8000)
        #expect(slices.count == 1)
        #expect(slices[0].top == 0 && slices[0].bottom == Self.pageBottom(blocks))
        #expect(slices[0].firstLine == 1 && slices[0].lastLine == 30)
        #expect(!slices[0].oversized)
    }

    @Test func aLongPageIsCutOnlyBetweenBlocksAndWithinTheLimit() {
        let blocks = Self.blocks(Array(repeating: 700, count: 30))
        let slices = DocumentImageRenderer.slices(blocks: blocks, pageBottom: Self.pageBottom(blocks), maxHeight: 2000)
        #expect(slices.count > 1)
        for slice in slices {
            #expect(slice.height <= 2000, "\(slice)")
            // No block straddles a cut: each lies wholly in one slice.
            #expect(!blocks.contains { $0.top < slice.bottom && $0.bottom > slice.bottom }, "cut inside a block at \(slice.bottom)")
        }
        // The slices tile the page, and their lines run on without a gap.
        #expect(slices.first!.top == 0 && slices.last!.bottom == Self.pageBottom(blocks))
        for (a, b) in zip(slices, slices.dropFirst()) {
            #expect(a.bottom == b.top)
            #expect(a.lastLine + 1 == b.firstLine)
        }
        #expect(slices.last!.lastLine == 300)
    }

    @Test func theCutIsHalfwayIntoTheGap() {
        let blocks = [Block(top: 0, bottom: 900, firstLine: 1, lastLine: 5), Block(top: 940, bottom: 1500, firstLine: 6, lastLine: 9)]
        let slices = DocumentImageRenderer.slices(blocks: blocks, pageBottom: 1500, maxHeight: 1000)
        #expect(slices.map(\.bottom) == [920, 1500])
    }

    @Test func aBlockTallerThanTheLimitGetsAnImageOfItsOwn() {
        let blocks = Self.blocks([300, 2500, 300])
        let slices = DocumentImageRenderer.slices(blocks: blocks, pageBottom: Self.pageBottom(blocks), maxHeight: 1000)
        #expect(slices.map(\.oversized) == [false, true, false], "\(slices)")
        #expect(slices[1].firstLine == 11 && slices[1].lastLine == 20)
        #expect(slices[1].height > 1000)
    }

    @Test func aHeadingStaysWithWhatFollowsItWhenAnotherCutFits() {
        // Cutting after block 2 (a heading) would fill the slice best; the cut after block 1 is
        // taken instead, so the heading starts the next image.
        let blocks = Self.blocks([400, 400, 40, 600], headings: [2])
        let slices = DocumentImageRenderer.slices(blocks: blocks, pageBottom: Self.pageBottom(blocks), maxHeight: 1000)
        #expect(slices.first!.lastLine == 20, "\(slices)")
        #expect(slices[1].firstLine == 21)
    }

    @Test func aHeadingIsCutAfterWhenNothingElseFits() {
        let blocks = Self.blocks([900, 40, 900], headings: [1])
        let slices = DocumentImageRenderer.slices(blocks: blocks, pageBottom: Self.pageBottom(blocks), maxHeight: 1000)
        #expect(slices.allSatisfy { !$0.oversized })
        #expect(slices.allSatisfy { $0.height <= 1000 }, "\(slices)")
    }

    @Test func noBlocksIsNoSlices() {
        #expect(DocumentImageRenderer.slices(blocks: [], pageBottom: 500).isEmpty)
    }

    // MARK: Headings and lines

    static let document = """
    ---
    title: Plan
    ---
    # Plan

    Intro.

    ## Rollout

    Steps.

    ### Phase one

    More.

    ## Risks

    None.
    """

    @Test func aSectionRunsToTheNextHeadingOfTheSameOrAHigherLevel() {
        // Lines counted in the whole file, front matter included.
        #expect(DocumentImageRenderer.headingLines("Rollout", markdown: Self.document) == 8...15)
        #expect(DocumentImageRenderer.headingLines("Phase one", markdown: Self.document) == 12...15)
        #expect(DocumentImageRenderer.headingLines("Risks", markdown: Self.document) == 16...18)
        #expect(DocumentImageRenderer.headingLines("Plan", markdown: Self.document) == 4...18)
    }

    @Test func theMatchIgnoresCaseAndRunsOfSpaces() {
        #expect(DocumentImageRenderer.headingLines("  phase   ONE ", markdown: Self.document) == 12...15)
    }

    @Test func aHeadingThatIsNotThereIsNil() {
        #expect(DocumentImageRenderer.headingLines("Budget", markdown: Self.document) == nil)
        #expect(DocumentImageRenderer.headingLines("Rollou", markdown: Self.document) == nil, "whole titles only")
        #expect(DocumentImageRenderer.headingLines("title: Plan", markdown: Self.document) == nil, "front matter isn't a heading")
    }

    @Test func linesAreCountedAsTheEditorCountsThem() {
        #expect(DocumentImageRenderer.lineCount("") == 1)
        #expect(DocumentImageRenderer.lineCount("a") == 1)
        #expect(DocumentImageRenderer.lineCount("a\n") == 1)
        #expect(DocumentImageRenderer.lineCount("a\nb") == 2)
        #expect(DocumentImageRenderer.lineCount("a\n\n") == 2)
    }
}
#endif
