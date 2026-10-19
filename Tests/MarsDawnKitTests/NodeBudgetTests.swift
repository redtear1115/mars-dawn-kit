import Foundation
import Testing
@testable import MarsDawnKit

/// The pre-scan's early stop at the node budget (kit #150): `CMarkDepthScan.scan` feeds cmark in
/// chunks and refuses at a checkpoint whose lower bound is over the budget.
///
/// What a red test here means: B1 — a checkpoint counted more than the finished tree has (a
/// false refusal is then possible); B2 — the early check refuses where it shouldn't, or never
/// does; B3 — a document that used to parse doesn't, or changed its outcome.
///
/// Serialized: several of these keep a few cores busy, and alongside the WebKit suites' short
/// deadlines that is enough to make those miss in a parallel run.
@Suite(.serialized)
struct NodeBudgetTests {
    /// This suite's own worker slot, so its parses never hold up other suites' on the shared gate.
    static let gate = WorkerGate(slots: 1)

    // MARK: Inputs

    /// Generated shapes, each meant to exercise one thing the lower bound's proof relies on.
    static let shapes: [(name: String, source: String)] = {
        var shapes: [(String, String)] = [
            ("dense - a lists", String(repeating: "- a\n", count: 600)),
            ("alternating -/+ lists", String(repeating: "- a\n+ a\n", count: 300)),
            ("# lines", String(repeating: "# a\n", count: 600)),
            (">-a blank-separated", String(repeating: ">-a\n\n", count: 400)),
            ("empty items", String(repeating: "-\n", count: 800)),
            ("thematic breaks", String(repeating: "***\n", count: 500)),
            ("empty headings", String(repeating: "#\n", count: 600)),
            ("task lists", String(repeating: "- [ ] a\n- [x] b\n", count: 200)),
            ("closed fence", "```\n" + String(repeating: "- a\n> b\n", count: 200) + "```\n" + String(repeating: "- c\n", count: 100)),
            ("unclosed fence", String(repeating: "- a\n", count: 100) + "```\n" + String(repeating: "- a\n# b\n", count: 200)),
            ("indented code", "para\n    - not code\n\n" + String(repeating: "    - a\n", count: 300)),
            ("lazy lines", String(repeating: "> a\nlazy\n- b\nlazy\n", count: 150)),
            ("trailing reference definition", String(repeating: "[a]\n\n", count: 300) + "[a]: /u\n"),
            // Nothing but definitions: the finished tree is the document node alone, so a
            // checkpoint that counted the open paragraph would already be over it.
            ("definitions only", String(repeating: "[a]: /u\n", count: 300)),
            ("definitions only, then blank lines", String(repeating: "[a]: /u\n", count: 300) + "\n\n\n"),
            ("attribute definitions only", String(repeating: "^[a]: (k: v)\n", count: 150)),
            ("definitions-only paragraph open", String(repeating: "[a]: /u\n", count: 300) + "\n" + String(repeating: "- x\n", count: 50)),
            ("definitions then text", String(repeating: "[a]: /u\n", count: 200) + "text\n" + String(repeating: "- x\n", count: 50)),
            ("closed paragraph then definitions", String(repeating: "a\n\n[x]: /u\n\n", count: 200)),
            ("setext underlines", String(repeating: "a\n===\n\nb\n---\n", count: 200)),
            ("setext under definitions", String(repeating: "[a]: /u\n===\n\n[b]: /v\nc\n---\n", count: 150)),
            ("tables", "| a | b |\n|---|---|\n" + String(repeating: "| 1 | 2 |\n", count: 300)),
            ("tables after a lead paragraph", String(repeating: "lead\nmore\n| a | b |\n|:-|-:|\n| 1 |\n| 2 | 3 |\nafter\n\n", count: 100)),
            ("row spans", "| a | b |\n|---|---|\n| 1 | 2 |\n" + String(repeating: "| ^ | ^ |\n", count: 200)),
            ("not a table row", "| a |\n|---|\n" + String(repeating: "| 1 |\n- x\n", count: 150)),
            ("open brackets", String(repeating: "[", count: 3000)),
            ("smart quotes", String(repeating: "\"a\" 'b' ", count: 400)),
            ("unmatched emphasis", String(repeating: "*a ", count: 900)),
            ("one long paragraph", String(repeating: "a\n", count: 900)),
            ("paragraphs", String(repeating: "a\n\n", count: 700)),
            ("strikethrough", String(repeating: "~~a~~ ~b ", count: 300)),
            ("trailing attribute definition", String(repeating: "para ^[a](k: v)\n\n", count: 100) + "^[a]: (k: v)\n"),
            ("attribute definitions open", String(repeating: "^[a]: (k: v)\n", count: 150) + "\n- x\n"),
            ("single-line quotes", String(repeating: ">", count: 3000) + "\n"),
            ("single-line spaced quotes", String(repeating: "> ", count: 1500) + "a\n"),
            ("single-line nested lists", String(repeating: "- ", count: 120) + "a\n"),
            ("nested quotes per line", (1...60).map { String(repeating: ">", count: $0) + " a\n" }.joined()),
            ("html blocks", String(repeating: "<div>\n- a\n</div>\n\n<script>\n- b\n</script>\n<!--\n- c\n-->\n<?\n- d\n?>\n<!X\n- e\n>\n<![CDATA[\n- f\n]]>\n<custom-tag>\n- g\n\n", count: 40)),
            ("unclosed html", "<!--\n" + String(repeating: "- a\n# b\n", count: 200)),
            ("crlf lines", String(repeating: "- a\r\n# b\r\n\r\npara\r\n", count: 150)),
            ("lone cr lines", String(repeating: "- a\r# b\r\r", count: 200)),
            ("cjk", String(repeating: "- 中文字\n# 日本語\n한국어 문단\n\n", count: 120)),
            ("nul bytes", String(repeating: "- a\u{0}b\n\u{0}\n# \u{0}\n", count: 200)),
            ("byte order mark", "\u{FEFF}- a\n" + String(repeating: "- \u{FEFF}b\n", count: 300)),
        ]
        var random = SeededGenerator(seed: 0x150B)
        let pieces = [">", "> ", "- ", "+ ", "  ", "    ", "1. ", "*", "_", "~~", "![", "](u)", "^[", "[", "]", "(", ")",
                      "|", "|-|", "| ^ |", "`", "```", "a", " ", "\n", "\n\n", "\r\n", "\r", "<div>", "<!--", "-->", "- [ ] ",
                      "\\", "#", "===", "---", "[a]: /u", "^[a]: (k: v)", "中", "\u{0}", "\u{FEFF}"]
        for index in 0..<300 {
            let length = Int.random(in: 1...400, using: &random)
            shapes.append(("random \(index)", (0..<length).map { _ in pieces.randomElement(using: &random)! }.joined()))
        }
        return shapes
    }()

    /// The Markdown corpus: the nesting corpus, every PDF-corpus document and the README.
    static let corpus: [(name: String, source: String)] = {
        var corpus = MarkdownNestingTests.corpus.enumerated().map { ("nesting corpus \($0.offset)", $0.element) }
        let tests = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let folder = tests.appending(path: "MarsDawnExportTests/Corpus")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names.sorted() {
            let file = folder.appending(path: name).appending(path: "document.md")
            if let text = try? String(contentsOf: file, encoding: .utf8) { corpus.append(("corpus \(name)", text)) }
        }
        let readme = tests.deletingLastPathComponent().appending(path: "README.md")
        if let text = try? String(contentsOf: readme, encoding: .utf8) { corpus.append(("README", text)) }
        return corpus
    }()

    static var allInputs: [(name: String, source: String)] { shapes + corpus }

    /// Chunk sizes for `source`: down to one byte for small inputs, so boundaries fall inside
    /// every UTF-8 sequence and between every `\r` and `\n`.
    static func chunkSizes(for source: String) -> [Int] {
        let count = source.utf8.count
        let smallest = max(1, count / 2_000)
        return Array(Set([smallest, smallest + 1, 7, 64])).sorted()
    }

    /// The largest bound over all checkpoints at `chunkSize`, and the scan's result.
    static func maxBound(_ source: String, chunkSize: Int) -> (bound: Int, checkpoints: Int, result: CMarkDepthScan.Result) {
        var largest = 0
        var checkpoints = 0
        let result = CMarkDepthScan.scan(source, stopAbove: nil, chunkSize: chunkSize) { _, bound in
            largest = max(largest, bound)
            checkpoints += 1
        }
        return (largest, checkpoints, result)
    }

    // MARK: B1 — the bound never exceeds the exact count

    /// The largest bound over every checkpoint is at most the exact node count, for every input
    /// and chunk size; and a chunked scan counts exactly what one feed does (F6).
    @Test func theBoundNeverExceedsTheExactCount() {
        var failures: [String] = []
        var labels: [String] = []
        for (name, source) in Self.allInputs {
            let exact = CMarkDepthScan.measure(source)
            var largest = 0
            for chunkSize in Self.chunkSizes(for: source) {
                let (bound, _, result) = Self.maxBound(source, chunkSize: chunkSize)
                largest = max(largest, bound)
                if bound > exact.nodes {
                    failures.append("\(name), chunk \(chunkSize): bound \(bound) > exact \(exact.nodes)")
                }
                if result != .measured(depth: exact.depth, nodes: exact.nodes) {
                    failures.append("\(name), chunk \(chunkSize): chunked \(result) != one feed \(exact)")
                }
            }
            labels.append("\(name): exact \(exact.nodes), max bound \(largest)")
        }
        print("B1 inputs:\n" + labels.filter { !$0.hasPrefix("random") }.joined(separator: "\n"))
        #expect(failures.isEmpty, "\(failures.prefix(10))")
        #expect(Self.allInputs.count > 340)
    }

    /// Positive fixture: the bound is not trivially small. A dense list's blocks are nearly all
    /// counted, and the corpus's documents get bounds too.
    @Test func theBoundCountsTheBlocksItCan() {
        let lines = 600
        let list = String(repeating: "- a\n", count: lines)
        // Exact: document, list, and per line an item, a paragraph and a text.
        #expect(CMarkDepthScan.measure(list).nodes == 2 + 3 * lines)
        let (bound, checkpoints, _) = Self.maxBound(list, chunkSize: 4)
        #expect(checkpoints == lines - 1)
        // At the last checkpoint: the document, the list, every item so far and every paragraph
        // but the open one.
        #expect(bound == 1 + 2 * (lines - 1), "bound \(bound)")
        // Empty items have no inline nodes: the bound misses only the last line's item.
        let empty = String(repeating: "-\n", count: 800)
        #expect(Self.maxBound(empty, chunkSize: 2).bound == CMarkDepthScan.measure(empty).nodes - 1)
    }

    // MARK: B2 — exact boundaries, and which path refuses

    static func decide(_ source: String, maxNodes: Int, chunkSize: Int = 64) -> MarkdownParsing.Decision {
        MarkdownParsing.decide(source, limits: ParseLimits(maxNodes: maxNodes), chunkSize: chunkSize, earlyStop: true)
    }

    static func isEarly(_ decision: MarkdownParsing.Decision) -> Bool {
        if case .tooComplexEarly = decision { return true }
        return false
    }

    static let blockHeavy: [(name: String, source: String)] = [
        ("dense - a lists", String(repeating: "- a\n", count: 2_000)),
        ("alternating -/+ lists", String(repeating: "- a\n+ a\n", count: 1_000)),
        ("# lines", String(repeating: "# a\n", count: 2_000)),
        (">-a blank-separated", String(repeating: ">-a\n\n", count: 1_500)),
    ]

    /// Budget = exact count: accepted. One less: refused. Budget = the largest bound: the early
    /// check does not fire. One less: it does, at the checkpoint that reached it.
    @Test(arguments: blockHeavy.map(\.name))
    func exactBoundaries(name: String) throws {
        let source = try #require(Self.blockHeavy.first { $0.name == name }).source
        let exact = CMarkDepthScan.measure(source).nodes
        let (largest, _, _) = Self.maxBound(source, chunkSize: 64)
        print("B2 \(name): exact \(exact), max bound \(largest) at chunk 64")
        #expect(largest > 0 && largest < exact)

        #expect(Self.decide(source, maxNodes: exact) == .accept(depth: CMarkDepthScan.measure(source).depth, nodes: exact))
        #expect(Self.decide(source, maxNodes: exact - 1) == .tooComplexFinal(nodes: exact))

        let atBound = Self.decide(source, maxNodes: largest)
        #expect(!Self.isEarly(atBound), "budget = max bound must not stop early: \(atBound)")
        let underBound = Self.decide(source, maxNodes: largest - 1)
        guard case .tooComplexEarly(_, let bound) = underBound else {
            Issue.record("budget = max bound - 1 must stop early: \(underBound)")
            return
        }
        #expect(bound == largest)
    }

    /// A document with no inline nodes and nothing in its last chunk: the bound reaches the
    /// exact count, so the early check is the one that refuses at exact count - 1.
    @Test func withNothingLeftToBuildTheEarlyCheckDecidesTheExactBoundary() {
        // `*`, not `-`: a line of dashes is a table delimiter candidate, and TableCostBound's
        // over-estimate would refuse first.
        let source = String(repeating: "*\n", count: 3_000) + String(repeating: "\n", count: 200)
        let exact = CMarkDepthScan.measure(source).nodes
        #expect(exact == 3_002)
        #expect(Self.decide(source, maxNodes: exact) == .accept(depth: 3, nodes: exact))
        let refused = Self.decide(source, maxNodes: exact - 1)
        #expect(Self.isEarly(refused), "\(refused)")
    }

    /// At the real chunk size and budget, block-heavy documents past the budget are refused by
    /// the early check, and parseChecked returns `.tooComplex` for them.
    @Test func realSizeBlockHeavyDocumentsStopEarly() {
        for (name, unit) in [("- a", "- a\n"), ("- a/+ a", "- a\n+ a\n"), ("# a", "# a\n"), (">-a", ">-a\n\n")] {
            let source = String(repeating: unit, count: (3 << 20) / unit.utf8.count)
            let decision = MarkdownParsing.decide(source, limits: .default)
            print("B2 real size \(name) (\(source.utf8.count) bytes): \(decision)")
            #expect(Self.isEarly(decision), "\(name): \(decision)")
            let outcome = MarkdownParsing.withDocument(source, options: .default, gate: Self.gate) { outcome -> Bool in
                if case .tooComplex = outcome { return true }
                return false
            }
            #expect(outcome, "\(name)")
        }
    }

    // MARK: B3 — no false refusal

    static func outcomeCase(_ decision: MarkdownParsing.Decision) -> String {
        switch decision {
        case .tooLarge: "tooLarge"
        case .tooComplexTables, .tooComplexEarly, .tooComplexFinal: "tooComplex"
        case .tooDeep: "tooDeep"
        case .accept: "document"
        }
    }

    /// With the default limits, every input decides the same with the early stop as without it
    /// (the code path before #150), and the corpus documents all parse.
    @Test func everyInputDecidesAsBefore() {
        var differences: [String] = []
        for (name, source) in Self.allInputs {
            for chunkSize in [7, 64, CMarkDepthScan.chunkSize] {
                let early = MarkdownParsing.decide(source, limits: .default, chunkSize: chunkSize, earlyStop: true)
                let before = MarkdownParsing.decide(source, limits: .default, chunkSize: chunkSize, earlyStop: false)
                if early != before { differences.append("\(name), chunk \(chunkSize): \(early) vs \(before)") }
            }
        }
        #expect(differences.isEmpty, "\(differences.prefix(5))")
        for (name, source) in Self.corpus {
            #expect(Self.outcomeCase(MarkdownParsing.decide(source, limits: .default)) == "document", "\(name)")
        }
    }

    /// Small budgets: the early stop only ever turns an exact-count refusal into an earlier one.
    @Test func atAnyBudgetTheEarlyStopRefusesOnlyWhatTheExactCountRefuses() {
        var failures: [String] = []
        for (name, source) in Self.shapes where !name.hasPrefix("random") {
            let exact = CMarkDepthScan.measure(source).nodes
            for maxNodes in Set([1, 2, exact / 3, exact / 2, exact - 1, exact, exact + 1].filter { $0 >= 1 }) {
                let early = Self.decide(source, maxNodes: maxNodes, chunkSize: 16)
                let before = MarkdownParsing.decide(source, limits: ParseLimits(maxNodes: maxNodes), chunkSize: 16, earlyStop: false)
                if Self.isEarly(early), Self.outcomeCase(before) != "tooComplex" {
                    failures.append("\(name), budget \(maxNodes): early \(early), exact path \(before)")
                }
                if !Self.isEarly(early), early != before {
                    failures.append("\(name), budget \(maxNodes): \(early) vs \(before)")
                }
            }
        }
        #expect(failures.isEmpty, "\(failures.prefix(10))")
    }

    // MARK: B4d — every checkpoint can stop

    /// Stopping at every checkpoint frees what was built (run once under ASan: B4d).
    @Test func stoppingAtEveryCheckpointFreesCleanly() {
        var stops = 0
        for (name, source) in Self.allInputs where source.utf8.count <= 20_000 {
            let chunkSize = max(16, source.utf8.count / 64)
            let (_, checkpoints, _) = Self.maxBound(source, chunkSize: chunkSize)
            for checkpoint in stride(from: 1, through: checkpoints, by: 1) {
                let result = CMarkDepthScan.scan(source, stopAbove: nil, chunkSize: chunkSize, stopAtCheckpoint: checkpoint)
                guard case .stoppedEarly(let stopped, _) = result, stopped == checkpoint else {
                    Issue.record("\(name): \(result) at \(checkpoint)")
                    continue
                }
                stops += 1
            }
        }
        #expect(stops > 5_000, "\(stops) stops")
    }
}

// MARK: - BC-2: the swift-cmark guard

struct CMarkGuardTests {
    /// On the pinned swift-cmark the guard is on.
    @Test func thePinnedCMarkIsTheAuditedOne() {
        #expect(CMarkInternals.Fingerprint.current == .audited)
        #expect(CMarkInternals.isAudited)
    }

    /// Any difference in what the guard compares turns it off.
    @Test func aDifferentFingerprintTurnsTheEarlyStopOff() {
        let current = CMarkInternals.Fingerprint.current
        #expect(CMarkInternals.matches(current, audited: .audited), "positive fixture")
        var changes: [CMarkInternals.Fingerprint] = []
        var version = current; version.version = "0.29.0.gfm.14"; changes.append(version)
        var size = current; size.parserSize += 8; changes.append(size)
        var offset = current; offset.rootOffset = 24; changes.append(offset)
        var missing = current; missing.rootOffset = nil; changes.append(missing)
        var probes = current; probes.probeNodes[0] += 1; changes.append(probes)
        var bounds = current; bounds.probeBoundsHold = false; changes.append(bounds)
        for changed in changes {
            #expect(!CMarkInternals.matches(changed, audited: .audited), "\(changed)")
        }
    }

    /// With the guard off, nothing stops early and every decision is the exact path's.
    @Test func withTheGuardOffNothingStopsEarly() {
        var checkpoints = 0
        for (name, source) in NodeBudgetTests.allInputs {
            for maxNodes in [1, 10, 100] {
                let decision = MarkdownParsing.decide(source, limits: ParseLimits(maxNodes: maxNodes), chunkSize: 16, earlyStop: false)
                #expect(!NodeBudgetTests.isEarly(decision), "\(name)")
            }
        }
        _ = CMarkDepthScan.scan(String(repeating: "- a\n", count: 100), stopAbove: nil, chunkSize: 4) { _, _ in checkpoints += 1 }
        #expect(checkpoints == 99, "positive fixture: an observer sees the checkpoints")
    }
}

/// F6: the code was written for swift-cmark 0.8.0. A different resolved version fails here, and
/// RELEASING.md says what a bump takes.
struct CMarkVersionPinTests {
    @Test func theResolvedSwiftCMarkIsTheAuditedOne() throws {
        let resolved = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Package.resolved")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: resolved)) as? [String: Any]
        let pins = try #require(object?["pins"] as? [[String: Any]])
        let cmark = try #require(pins.first { $0["identity"] as? String == "swift-cmark" })
        let state = try #require(cmark["state"] as? [String: Any])
        #expect(state["version"] as? String == "0.8.0")
        #expect(state["revision"] as? String == "924936d0427cb25a61169739a7660230bffa6ea6")
    }
}
