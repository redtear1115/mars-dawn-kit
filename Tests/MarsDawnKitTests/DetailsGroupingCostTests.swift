import Foundation
import Testing
@testable import MarsDawnKit

/// Finding the end of a `<details>` is one forward pass, however many openings never close, and
/// writing a group is iterative however deeply the openings nest (kit security review F1).
///
/// The bounds are for release builds; a debug build runs smaller documents and checks only the
/// output.
@Suite(.serialized, .timeLimit(.minutes(8)))
struct DetailsGroupingCostTests {
    #if DEBUG
    static let isRelease = false
    static let unmatched = 20_000
    static let nested = 20_000
    #else
    static let isRelease = true
    static let unmatched = 200_000
    static let nested = 100_000
    #endif

    enum Shape: String, CaseIterable {
        case document, quote, listItem

        /// `count` blocks, each `tag` on its own line and each followed by a blank line.
        func source(_ lines: [String]) -> String {
            switch self {
            case .document: return lines.map { $0 + "\n\n" }.joined()
            case .quote: return lines.map { "> " + $0 + "\n>\n" }.joined()
            case .listItem:
                return lines.enumerated().map { ($0.offset == 0 ? "- " : "\n  ") + $0.element + "\n" }.joined()
            }
        }

        /// What the document renders to when no block groups: each block on its own, wrapped.
        func ungrouped(_ lines: [String]) -> String {
            let blocks = lines.enumerated().map {
                "<div class=\"html-block\" data-line=\"\(1 + 2 * $0.offset)\">\($0.element)\n</div>\n"
            }.joined()
            switch self {
            case .document: return blocks
            case .quote: return "<blockquote data-line=\"1\">\n" + blocks + "</blockquote>\n"
            case .listItem: return "<ul data-line=\"1\">\n<li data-line=\"1\">" + blocks + "</li>\n</ul>\n"
            }
        }
    }

    private func seconds(_ work: () -> Void) -> Double {
        let clock = ContinuousClock()
        let elapsed = clock.measure(work)
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }

    /// The fastest of a few runs, to keep a scheduling hiccup out of a ratio.
    private func best(of runs: Int = 3, _ work: () -> Void) -> Double {
        (0..<runs).map { _ in seconds(work) }.min()!
    }

    @Test(arguments: Shape.allCases)
    func unmatchedOpeningsCostAsMuchAsAnyOtherBlock(_ shape: Shape) {
        let n = Self.unmatched
        let details = shape.source(Array(repeating: "<details>", count: n))
        let divs = shape.source(Array(repeating: "<div>", count: n))
        var output = ""
        let detailsTime = best { output = MarkdownRenderer.render(details) }
        let divTime = best { _ = MarkdownRenderer.render(divs) }
        #expect(output == shape.ungrouped(Array(repeating: "<details>", count: n)), "\(shape): rendered as before")
        print("A16 unmatched \(shape): \(n) <details> \(detailsTime) s, \(n) <div> \(divTime) s, ratio \(detailsTime / divTime)")
        if Self.isRelease {
            #expect(detailsTime <= divTime * 1.5, "\(shape): \(detailsTime) s against \(divTime) s")
        }
    }

    @Test(arguments: Shape.allCases)
    func doublingTheOpeningsAtMostAboutDoublesTheTime(_ shape: Shape) {
        let half = shape.source(Array(repeating: "<details>", count: Self.unmatched / 2))
        let full = shape.source(Array(repeating: "<details>", count: Self.unmatched))
        let halfTime = best { _ = MarkdownRenderer.render(half) }
        let fullTime = best { _ = MarkdownRenderer.render(full) }
        print("A16 doubling \(shape): \(Self.unmatched / 2) \(halfTime) s, \(Self.unmatched) \(fullTime) s, ratio \(fullTime / halfTime)")
        if Self.isRelease {
            #expect(fullTime <= halfTime * 2.5, "\(shape): \(fullTime) s against \(halfTime) s")
        }
    }

    /// 100k openings, each in its own block, then 100k closes: one group 200k children long. It
    /// is written without recursion, so the worker's stack does not grow with it.
    @Test(arguments: Shape.allCases)
    func deepNestingRendersOnTheWorkerWithoutGrowingTheStack(_ shape: Shape) throws {
        let n = Self.nested
        let source = shape.source(Array(repeating: "<details>", count: n) + Array(repeating: "</details>", count: n))
        let html = MarkdownRenderer.render(source)
        #expect(html.components(separatedBy: "<div class=\"html-block\"").count - 1 == 1, "\(shape): one group")
        #expect(html.components(separatedBy: "<details>").count - 1 == n)
        #expect(html.components(separatedBy: "</details>").count - 1 == n)
        // The same measurement the other walkers answer to: at most a quarter of the worker's stack.
        let peak = try #require(StackMarginTests.peakOnWorker(source, StackMarginTests.renderOnly))
        print("A16 nested \(shape): \(n) openings + \(n) closes, peak stack \(peak / 1024) KB of \(StackMarginTests.workerStack >> 20) MB")
        #expect(peak * 4 <= StackMarginTests.workerStack, "\(shape): \(peak / 1024) KB")
    }
}
