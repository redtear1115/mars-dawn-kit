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
    // densest form found, `?\n`, gives 393,220 at 384 KiB), so an event limit could never be
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
        #expect(densest > DataDocumentPreview.maximumYAMLBytes * 3 / 4, "positive: the probe parses dense forms (\(densest))")
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

    static func emptyMerges(_ count: Int) -> String {
        "e: &e {}\nl:\n" + String(repeating: "- {<<: *e}\n", count: count)
    }

    /// CORE_SCHEMA has no merge: `<<` is a plain key, 20,000 times (aliases to one empty mapping).
    /// The row cap is relaxed so the whole document is drawn. The draw is not timed tightly (a
    /// loaded hosted runner took 3.4 s and 4.2 s for it, kit #198); the parse is what this guards,
    /// and is timed by the next test.
    @Test func twentyThousandEmptyMergesAreLiteralKeys() async throws {
        let text = Self.emptyMerges(20_000)
        #expect(text.utf8.count <= DataDocumentPreview.maximumYAMLBytes)
        let (outcome, page) = try await timed(text, .yaml, limits: ["maximumRenderedNodes": 100_000, "autoExpandBudgetMilliseconds": 60_000], bound: .seconds(30))
        #expect(outcome == .rendered)
        #expect(try await DataPage.int("Array.from(document.querySelectorAll('#data .data-key')).filter((k) => k.textContent === '<<').length", in: page) == 20_000)
    }

    /// Kit #198: the parse and construct of the same shape, timed in the page with the page's own
    /// js-yaml calls and nothing drawn. Two guards: the 20k parse is under 500 ms (observed
    /// about 7 ms locally), and doubling the input costs under 3x (linear is 2x,
    /// quadratic 4x), taking the best of three runs of each size so one slow run on a loaded
    /// runner cannot fail it.
    @Test func parsingEmptyMergesGrowsLinearly() async throws {
        let page = try await DataPage.load()
        func parseMilliseconds(_ count: Int) async throws -> Double {
            let text = Self.emptyMerges(count)
            let result = try await page.callAsyncJavaScript("""
            let best = Infinity;
            for (let run = 0; run < 3; run++) {
              const start = performance.now();
              const events = jsyaml.parseEvents(text, { maxDepth: 1000 });
              jsyaml.constructFromEvents(events, { source: text, schema: jsyaml.CORE_SCHEMA, json: false, maxAliases: 1000000 });
              best = Math.min(best, performance.now() - start);
            }
            return best;
            """, arguments: ["text": text], contentWorld: .page)
            return result as? Double ?? -1
        }
        let small = try await parseMilliseconds(20_000)
        let large = try await parseMilliseconds(40_000)
        #expect(small > 0 && large > 0, "\(small) \(large)")
        #expect(small < 500, "20k parse took \(small) ms")
        // Timer resolution is about 1 ms and the parse about 7 ms, so the floor keeps the ratio honest.
        #expect(large < max(small, 20) * 3, "20k \(small) ms, 40k \(large) ms: not linear")
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

    // Chained alias cycles (kit #191). nestsDeeperThan keeps heights that a cycle cut short, so a
    // container reached again from another entry can be taller than it said. A ring is
    // `ringLength` nested lists whose deepest points back at its first. The list above a ring's
    // deepest also points at the previous ring's deepest, which the screen has by then kept at
    // its cut height, so one click at a time walks ring after ring: about k x 700 levels.

    static let ringLength = 700

    static func chainedRings(_ rings: Int) -> String {
        let n = ringLength
        let names = ["a", "b", "c", "d"]
        let bodies = (0..<rings).map { r -> String in
            let name = names[r]
            let cross = r > 0 ? ", *\(names[r - 1])\(n)" : ""
            return (1..<n).map { "&\(name)\($0) [" }.joined() + "&\(name)\(n) [*\(name)1]" + cross + String(repeating: "]", count: n - 1)
        }
        return "[" + bodies.joined(separator: ", ") + "]\n"
    }

    /// Clicks the first closed toggle until none is left, one level per click, and returns the
    /// deepest container drawn (a container's level is the number of `.data-children` around it, plus one).
    func expandOneClickAtATime(_ page: WKWebView) async throws -> (clicks: Int, deepest: Int) {
        let result = try await DataPage.value("""
        (() => {
          let clicks = 0;
          for (; clicks < 10000; clicks++) {
            const button = document.querySelector('#data .data-toggle[aria-expanded="false"]');
            if (!button) break;
            button.click();
          }
          let deepest = 0;
          for (const toggle of document.querySelectorAll('#data .data-toggle')) {
            let level = 1;
            for (let at = toggle.parentElement.parentElement; at; at = at.parentElement) if (at.classList.contains('data-children')) level++;
            deepest = Math.max(deepest, level);
          }
          return [clicks, deepest];
        })()
        """, in: page) as? [Int]
        return (result?[0] ?? -1, result?[1] ?? -1)
    }

    /// Two rings (the issue's fixture) and three: k rings used to draw about k x 700 levels.
    /// Time is linear: the screen walks each container once; a click draws one level's children.
    @Test(arguments: [2, 3]) func clickingThroughChainedCyclesNeverDrawsPastTheLimit(rings: Int) async throws {
        let (outcome, page) = try await timed(Self.chainedRings(rings), .yaml, bound: .seconds(10))
        #expect(outcome == .rendered, "the fixture must pass the screen, or the click path is not what is tested")
        let (clicks, deepest) = try await expandOneClickAtATime(page)
        #expect(clicks > 0 && clicks < 10000, "clicks: \(clicks)")
        #expect(deepest <= DataDocumentPreview.maximumDepth, "deepest drawn container: \(deepest)")
        #expect(deepest > Self.ringLength, "the click walk must get past one ring, or it proves nothing: \(deepest)")
        #expect(try await DataPage.int("document.querySelectorAll('#data .data-notice').length", in: page) == (deepest == DataDocumentPreview.maximumDepth ? 1 : 0))
    }

    /// Kit #205: the depth stop refuses a child for good, so "Show ... More" must move past it. After
    /// the click walk every "Show more" button is clicked until none is left: each click either
    /// draws rows or removes the button, and the buttons are gone within a few passes. Before the
    /// fix the same child was refused on every click and the button came back.
    @Test(arguments: [2, 3]) func showMoreAfterTheDepthStopMakesProgress(rings: Int) async throws {
        let (outcome, page) = try await timed(Self.chainedRings(rings), .yaml, bound: .seconds(10))
        #expect(outcome == .rendered)
        let (_, deepest) = try await expandOneClickAtATime(page)
        #expect(deepest == DataDocumentPreview.maximumDepth, "the walk must reach the depth stop, or this tests nothing: \(deepest)")
        let rowsBefore = try await DataPage.rows(in: page)
        let passes = try await DataPage.int("""
        (() => {
          let passes = 0;
          for (; passes < 20; passes++) {
            const buttons = Array.from(document.querySelectorAll('#data .data-more'));
            if (buttons.length === 0) break;
            for (const b of buttons) b.click();
          }
          return passes;
        })()
        """, in: page)
        #expect(passes < 20, "the buttons never ran out: \(passes) passes")
        #expect(try await DataPage.int("document.querySelectorAll('#data .data-more').length", in: page) == 0)
        #expect(try await DataPage.rows(in: page) >= rowsBefore)
    }
}
#endif
