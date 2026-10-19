#if os(macOS)
import Foundation
import Testing
import WebKit
@testable import MarsDawnKit

/// D3 (kit #128): hostile documents sized from the kit's limits. Every check is on the end state or
/// an exact row count, never on "takes longer"; times are bounds only (3 s each, 1 s for the
/// flow-collection shapes). For each row, every other limit that could produce the same state is
/// relaxed through the `limits` argument, and the test says which.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(5)))
struct DataDocumentBombTests {
    static let wide = 1 << 30

    func timed(_ text: String, _ kind: DataDocumentPreview.Kind, limits: [String: Int] = [:], bound: Duration = .seconds(3),
               in webView: WKWebView? = nil) async throws -> (DataDocumentPreview.RenderOutcome, WKWebView) {
        let page: WKWebView
        if let webView { page = webView } else { page = try await DataPage.load() }
        let start = ContinuousClock.now
        let outcome = await DataPage.render(text, kind: kind, in: page, limits: limits)
        let elapsed = ContinuousClock.now - start
        #expect(elapsed < bound, "\(kind) \(text.prefix(40).debugDescription)… took \(elapsed)")
        return (outcome, page)
    }

    // Depth. The builder's depth limit is maximumDepth, sent as maximumTreeDepth so a test can
    // relax the builder alone and see the parser's own limit at work.

    @Test func yamlNestedToTheLimitIsRendered() async throws {
        let (outcome, _) = try await timed(DataPage.nestedSequences(DataDocumentPreview.maximumDepth), .yaml)
        #expect(outcome == .rendered)
    }

    /// Produced by js-yaml's maxDepth: the builder's depth limit is relaxed, so only the parser
    /// can refuse it (the fact itself is DataDocumentJSYAMLProbeTests.parseEventsHonoursMaxDepth).
    @Test func yamlOneLevelPastTheLimitIsTooComplexFromTheParser() async throws {
        let (outcome, _) = try await timed(DataPage.nestedSequences(DataDocumentPreview.maximumDepth + 1), .yaml,
                                           limits: ["maximumTreeDepth": Self.wide])
        #expect(outcome == .tooComplex)
    }

    /// JSON has no parser depth option: the builder's limit is the only one.
    @Test func jsonOneLevelPastTheLimitIsTooComplexFromTheBuilder() async throws {
        var (outcome, _) = try await timed(DataPage.nestedSequences(DataDocumentPreview.maximumDepth), .json)
        #expect(outcome == .rendered)
        (outcome, _) = try await timed(DataPage.nestedSequences(DataDocumentPreview.maximumDepth + 1), .json)
        #expect(outcome == .tooComplex)
        // A scalar is a level: maximumDepth - 1 arrays around one number is the limit.
        let around = { (n: Int) in String(repeating: "[", count: n) + "1" + String(repeating: "]", count: n) }
        (outcome, _) = try await timed(around(DataDocumentPreview.maximumDepth - 1), .json)
        #expect(outcome == .rendered)
        (outcome, _) = try await timed(around(DataDocumentPreview.maximumDepth), .json)
        #expect(outcome == .tooComplex)
    }

    /// A million levels: JSON is refused by the builder; YAML of that size is over its byte cap,
    /// so the largest one the parser can be given (half a million `[` within the cap) is used too.
    @Test func aMillionLevelsIsBoundedAndCrashesNothing() async throws {
        let million = DataPage.nestedSequences(1_000_000)
        var (outcome, page) = try await timed(million, .json)
        #expect(outcome == .tooComplex)
        (outcome, _) = try await timed(million, .yaml, in: page)
        #expect(outcome == .overCap)
        let open = String(repeating: "[", count: DataDocumentPreview.maximumYAMLBytes)
        (outcome, _) = try await timed(open, .yaml, in: page)
        #expect(outcome == .tooComplex)
        (outcome, _) = try await timed(open, .json, in: page)
        #expect(outcome == .tooComplex, "an unclosed JSON nest is past maxDepth in the position re-parse")
        #expect(try await DataPage.value("1 + 1", in: page) as? Int == 2, "the page still answers")
    }

    // Events. Within maximumYAMLBytes no YAML produces more than about one event per byte (the
    // densest form found, `?\n`, gives 524,292 at 512 KiB), so an event limit could never be
    // reached and there is none. This pins the measured density, so a parser change that made a
    // denser form possible would be seen.
    @Test func noFormReachesAMillionEventsWithinTheCap() async throws {
        let webView = try await DataPage.load()
        let densest = try await DataPage.value("""
        (() => {
          const cap = \(DataDocumentPreview.maximumYAMLBytes);
          const fill = (unit) => unit.repeat(Math.floor(cap / unit.length));
          let most = 0;
          for (const unit of ["?\\n", "[[]],", "---\\n", "- -\\n", "[],", "-\\n", ": \\n", "? : \\n", "{? }\\n"]) {
            try { most = Math.max(most, jsyaml.parseEvents(fill(unit), { maxDepth: \(DataDocumentPreview.maximumDepth + 1) }).length); } catch (e) {}
          }
          return most;
        })()
        """, in: webView) as? Int ?? -1
        #expect(densest > 400_000, "positive: the probe parses dense forms (\(densest))")
        #expect(densest <= DataDocumentPreview.maximumYAMLBytes + 8, "\(densest) events within the cap")
    }

    // Aliases.

    static func aliasesToAMapping(keys: Int, aliases: Int) -> String {
        "m: &m {" + (0..<keys).map { "k\($0): \($0)" }.joined(separator: ", ") + "}\nl: [" + Array(repeating: "*m", count: aliases).joined(separator: ", ") + "]\n"
    }

    /// 300 aliases to a 300-key mapping: 90,000 visits wanted, exactly maximumRenderedNodes drawn.
    /// The time budget is relaxed, so only the row cap can stop it.
    @Test func manyAliasesToABigMappingStopAtExactlyTheRowCap() async throws {
        let text = Self.aliasesToAMapping(keys: 300, aliases: 300)
        #expect(text.utf8.count <= DataDocumentPreview.maximumYAMLBytes)
        let (outcome, page) = try await timed(text, .yaml, limits: ["autoExpandBudgetMilliseconds": 60_000])
        #expect(outcome == .capped)
        #expect(try await DataPage.rows(in: page) == DataDocumentPreview.maximumRenderedNodes)
    }

    /// One alias past maxAliases: js-yaml refuses it (the fact is the direct probe).
    @Test func oneAliasPastTheLimitIsTooComplex() async throws {
        let n = DataDocumentPreview.maximumAliases
        let text = { (count: Int) in "a: &a x\nb: [" + Array(repeating: "*a", count: count).joined(separator: ",") + "]\n" }
        #expect(text(n + 1).utf8.count <= DataDocumentPreview.maximumYAMLBytes)
        var (outcome, page) = try await timed(text(n), .yaml)
        #expect(outcome == .capped, "at the limit the document is built (and capped by rows)")
        (outcome, _) = try await timed(text(n + 1), .yaml, in: page)
        #expect(outcome == .tooComplex)
    }

    // Schema.

    /// CORE_SCHEMA has no merge: `<<` is a plain key, 20,000 times (aliases to one empty mapping).
    /// The row cap is relaxed so the whole document is drawn.
    @Test func twentyThousandEmptyMergesAreLiteralKeys() async throws {
        let text = "e: &e {}\nl:\n" + String(repeating: "- {<<: *e}\n", count: 20_000)
        #expect(text.utf8.count <= DataDocumentPreview.maximumYAMLBytes)
        let (outcome, page) = try await timed(text, .yaml, limits: ["maximumRenderedNodes": 100_000, "autoExpandBudgetMilliseconds": 60_000])
        #expect(outcome == .rendered)
        #expect(try await DataPage.int("Array.from(document.querySelectorAll('#data .data-key')).filter((k) => k.textContent === '<<').length", in: page) == 20_000)
    }

    @Test func aLargeOmapIsAnUnknownTagWithItsLine() async throws {
        let text = "intro: 1\nx: !!omap\n" + (0..<10_000).map { "  - k\($0): \($0)\n" }.joined()
        let recorder = RecordingMessageHandler()
        let page = try await DataPage.load(messageHandlers: [DataDocumentPreview.errorMessageName: recorder])
        let (outcome, _) = try await timed(text, .yaml, in: page)
        #expect(outcome == .parseError)
        #expect(try await DataPage.messageText(in: page) == DataPage.parseErrorAt("YAML", 2, 4))
    }

    /// The flow-collection shape of the advisory fixed in 5.x: bounded at 1 s.
    @Test(arguments: [String(repeating: "[", count: 30), String(repeating: "[", count: 30) + "a",
                      String(repeating: "{", count: 30) + "a:", String(repeating: "[{", count: 15) + "a: b",
                      String(repeating: "[a, ", count: 30), String(repeating: "{a: [", count: 15)])
    func theFlowCollectionShapeIsBounded(text: String) async throws {
        let (outcome, _) = try await timed(text, .yaml, bound: .seconds(1))
        #expect(outcome == .parseError || outcome == .tooComplex, "\(outcome)")
    }

    // Cycles.

    @Test(arguments: ["&a [*a]\n", "&a {x: &b {y: *a, z: *b}}\n", "a: &a [&b [*a, *b], 1]\n"])
    func aCycleIsDrawnAsAMarker(text: String) async throws {
        let (outcome, page) = try await timed(text, .yaml)
        #expect(outcome == .rendered)
        #expect(try await DataPage.int("document.querySelectorAll('#data .data-cycle').length", in: page) >= 1)
    }
}
#endif
