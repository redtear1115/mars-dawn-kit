import Foundation
import Testing
@testable import MarsDawnKit

/// `FrontMatter.split` must stay linear. Long runs of alternating combining marks (canonical
/// combining classes 230 and 220) are the worst case for anything that compares or classifies
/// by `Character`: a single grapheme holds the whole run, and comparing it normalises it.
struct FrontMatterTimingTests {
    #if DEBUG
    static let slack = 10.0
    #else
    static let slack = 1.0
    #endif

    enum Shape: String, CaseIterable, Sendable {
        case keyWithMarks, nonPairLineWithMarks, delimiterWithMarks

        /// A document holding about `n` UTF-8 bytes of combining marks.
        func source(_ n: Int) -> String {
            let marks = String(repeating: "\u{301}\u{316}", count: n / 4)
            switch self {
            case .keyWithMarks: return "---\na" + marks + ": v\n---\n"
            case .nonPairLineWithMarks: return "---\nx" + marks + "\n- a\n---\n"
            case .delimiterWithMarks: return "---\n..." + marks + "\n---\n"
            }
        }
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    /// Best of three, to keep scheduler noise out of the ratios.
    private static func time(_ work: () -> Void) -> Double {
        let clock = ContinuousClock()
        return (0..<3).map { _ in seconds(clock.measure(work)) }.min()!
    }

    @Test(arguments: Shape.allCases)
    func splitIsLinearInCombiningMarkRuns(_ shape: Shape) {
        let sizes = [16_000, 32_000, 64_000, 128_000]
        var times: [Double] = []
        for n in sizes {
            let source = shape.source(n)
            times.append(Self.time {
                let split = FrontMatter.split(source)
                _ = split.frontMatter?.pairs
                _ = split.body.utf8.count
            })
        }
        print("F1 timing: split \(shape) at \(sizes): " + times.map { String(format: "%.4f s", $0) }.joined(separator: ", "))
        // 8x the input: linear is about 8x the time, quadratic about 64x. Very small times are
        // mostly noise, so they pass on an absolute floor instead.
        let first = times[0], last = times[times.count - 1]
        #expect(last < max(24 * first, 0.02 * Self.slack), "\(times)")
        #expect(last < 0.25 * Self.slack, "\(times)")
    }

    @Test func splitResultsForTheSlowShapes() throws {
        let marks = String(repeating: "\u{301}\u{316}", count: 8)
        let key = try #require(FrontMatter.split(Shape.keyWithMarks.source(32)).frontMatter)
        #expect(key.pairs?.map(\.key) == ["a" + marks])
        #expect(key.pairs?.map(\.value) == ["v"])

        let nonPair = FrontMatter.split(Shape.nonPairLineWithMarks.source(32))
        #expect(try #require(nonPair.frontMatter).pairs == nil)
        #expect(nonPair.bodyLineOffset == 4)

        // "..." followed by marks is not a closing line.
        let delimiter = FrontMatter.split(Shape.delimiterWithMarks.source(32))
        #expect(try #require(delimiter.frontMatter).lines == ["..." + marks])
        #expect(delimiter.bodyLineOffset == 3)
    }
}
