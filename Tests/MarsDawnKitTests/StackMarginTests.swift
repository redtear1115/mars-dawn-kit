import Foundation
import Testing
@testable import MarsDawnKit

/// K1 requires the worker's 64 MB stack to keep at least a 4x margin over the deepest
/// input the parse limits accept, and re-measuring whenever a new walker moves onto the
/// worker. `TextStatistics`, `DocumentOutline` and `MathExtractor` are three new ones:
/// the statistics visitor is a recursive `MarkupWalker`, and the extractor parses the
/// body, up to three rewrites and each candidate's TeX.
///
/// Each case measures the peak stack of the whole workload by painting the worker's
/// unused stack (see `peakStackUsage`), which is a direct measurement rather than a
/// search for the smallest stack that survives; the two differ by about one frame.
struct StackMarginTests {
    static let maxDepth = ParseLimits.default.maxDepth
    static let workerStack = MarkdownParsing.workerStackSize

    /// The deepest input of `shape` the limits accept, with math, a heading and a table
    /// appended so the extractor, the outline and the statistics all have work to do.
    /// The nesting is what drives the stack; the tail is what makes all four types run.
    static func measurementDocument(_ shape: NestingShape) -> String {
        shape.source(depthAtMost: maxDepth - 2).source + """


            # Heading with $x^2$ and *emphasis*

            Text with $a<b$, `code`, [a link](https://example.com) and ![alt](i.png).

            $$
            \\sum_{i=1}^n a_i
            $$

            | a | $b$ |
            |---|-----|
            | *c* | $d$ |

            """
    }

    /// Everything the renderer did before this move: parse, render, release.
    @Sendable static func renderOnly(_ source: String) {
        let result = MarkdownRenderer.renderResult(source)
        precondition(result.fallback == nil, "the measurement document must render")
    }

    /// Each of the three types that moved onto the worker, on its own, so the print says
    /// which one reaches deepest. Each nests into the worker this already runs on.
    @Sendable static func statisticsOnly(_ source: String) {
        // The readable-text visitor is a recursive MarkupWalker over the whole tree.
        precondition(TextStatistics(markdownBody: source).words > 0)
    }

    @Sendable static func outlineOnly(_ source: String) {
        precondition(!DocumentOutline(markdownBody: source).headings.isEmpty)
    }

    @Sendable static func mathOnly(_ source: String) {
        // Parses the body, a rewrite and each candidate's TeX.
        precondition(MathExtractor.extract(from: source).expressionCount > 0)
    }

    /// All four together, sharing one worker and one stack.
    @Sendable static func everything(_ source: String) {
        renderOnly(source)
        statisticsOnly(source)
        outlineOnly(source)
        mathOnly(source)
    }

    /// Runs `work` on a parsing worker and returns its peak stack use in bytes.
    static func peakOnWorker(_ source: String, _ work: @escaping @Sendable (String) -> Void) -> Int? {
        // An empty outer document: the workload does its own parsing, nested and inline.
        MarkdownParsing.withDocument("") { _ in
            peakStackUsage { work(source) }
        }
    }

    @Test(arguments: NestingShape.allCases)
    func stackMarginStaysAboveFourfold(_ shape: NestingShape) throws {
        let source = Self.measurementDocument(shape)
        let depth = CMarkDepthScan.maximumDepth(of: source)
        #expect(depth <= Self.maxDepth - 2, "the measurement document must still be accepted")
        #expect(depth >= Self.maxDepth - 6, "the measurement document must sit at the limit")

        let before = try #require(Self.peakOnWorker(source, Self.renderOnly))
        let statistics = try #require(Self.peakOnWorker(source, Self.statisticsOnly))
        let outline = try #require(Self.peakOnWorker(source, Self.outlineOnly))
        let math = try #require(Self.peakOnWorker(source, Self.mathOnly))
        let after = try #require(Self.peakOnWorker(source, Self.everything))
        let margin = Double(Self.workerStack) / Double(after)
        print("""
            STACK MARGIN \(shape): depth \(depth), \
            renderer only \(before / 1024) KB, statistics \(statistics / 1024) KB, \
            outline \(outline / 1024) KB, math \(math / 1024) KB, \
            all four \(after / 1024) KB, \
            margin \(String(format: "%.1f", margin))x of \(Self.workerStack >> 20) MB
            """)

        #expect(after > 0)
        // The margin K1 requires. If this ever fails, report it rather than lowering
        // `maxDepth`: the limit is a product decision.
        #expect(after * 4 <= Self.workerStack,
                "\(shape): \(after / 1024) KB used, under \(Self.workerStack / 4 / 1024) KB needed for 4x")
    }

    /// The workload also survives a worker only a quarter the size, run in a child process
    /// so that an overflow fails the test instead of killing the run.
    #if compiler(>=6.3)
    @Test(arguments: NestingShape.allCases)
    func aQuarterSizedWorkerSurvivesTheDeepestAcceptedInput(_ shape: NestingShape) async {
        let source = Self.measurementDocument(shape)
        await #expect(processExitsWith: .success) { [source = source as String, quarter = (MarkdownParsing.workerStackSize / 4) as Int] in
            let ran = MarkdownParsing.withDocument("", options: .default, gate: WorkerGate(slots: 1), stackSize: quarter) { _ in
                StackMarginTests.everything(source)
                return true
            }
            precondition(ran)
        }
    }
    #else
    /// Swift 6.2's exit tests can't capture values (capture lists came in 6.3), so one child
    /// process runs every shape in turn; a failure doesn't say which shape, only that one did.
    @Test func aQuarterSizedWorkerSurvivesTheDeepestAcceptedInput() async {
        await #expect(processExitsWith: .success) {
            for shape in NestingShape.allCases {
                let source = StackMarginTests.measurementDocument(shape)
                let ran = MarkdownParsing.withDocument("", options: .default, gate: WorkerGate(slots: 1), stackSize: MarkdownParsing.workerStackSize / 4) { _ in
                    StackMarginTests.everything(source)
                    return true
                }
                precondition(ran, "shape \(shape)")
            }
        }
    }
    #endif
}
