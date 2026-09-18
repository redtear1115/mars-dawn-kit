import Darwin
import Foundation
import Testing
import cmark_gfm
import cmark_gfm_extensions
@testable import MarsDawnKit

/// Hostile tables: cells padded by cmark, and its quadratic empty-cell and row-span loops.
@Suite(.serialized)
struct TableBudgetTests {
    #if DEBUG
    static let slack = 10.0
    #else
    static let slack = 1.0
    #endif

    // MARK: Inputs

    /// The measured repro: a 128-column header, a `$x$` row and 4,200 one-cell rows, which
    /// cmark pads to 128 cells each (up to its 524,288 padded cells per table).
    static func maxedTables(_ count: Int, columns: Int = 128, rows: Int = 4_200) -> String {
        // In steps: Xcode 26's type checker gives up on the single expression.
        let header: String = Array(repeating: "a", count: columns).joined(separator: "|") + "\n"
        let delimiter: String = Array(repeating: "-", count: columns).joined(separator: "|") + "\n"
        let table = header + delimiter + "$x$\n" + String(repeating: "b\n", count: rows)
        return Array(repeating: table, count: count).joined(separator: "\n")
    }

    static func filledTable(rows: Int, columns: Int) -> String {
        var text = "| " + (0..<columns).map { "Column \($0)" }.joined(separator: " | ") + " |\n"
        text += "|" + Array(repeating: "---", count: columns).joined(separator: "|") + "|\n"
        for row in 0..<rows {
            text += "| " + (0..<columns).map { "r\(row)c\($0)" }.joined(separator: " | ") + " |\n"
        }
        return text
    }

    /// Every body cell is a row-span marker.
    static func markerTable(rows: Int, columns: Int) -> String {
        Array(repeating: "a", count: columns).joined(separator: "|") + "\n"
            + Array(repeating: "-", count: columns).joined(separator: "|") + "\n"
            + String(repeating: Array(repeating: "^", count: columns).joined(separator: "|") + "\n", count: rows)
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    /// Renders on a blocking worker, timing it and noting the process's peak memory.
    private static func timedRender(_ source: String) -> (result: MarkdownRenderer.RenderResult, seconds: Double, peakMB: Int) {
        let clock = ContinuousClock()
        var result: MarkdownRenderer.RenderResult?
        let elapsed = clock.measure { result = MarkdownRenderer.renderResult(source) }
        return (result!, seconds(elapsed), peakResidentMegabytes())
    }

    // MARK: Hostile tables fall back quickly and in bounded memory

    @Test(arguments: [28, 8, 1])
    func paddedTablesFallBack(count: Int) {
        let source = Self.maxedTables(count)
        let (result, seconds, peak) = Self.timedRender(source)
        print("K1 tables: \(count) padded tables (\(source.utf8.count / 1024) KB) → \(String(describing: result.fallback)) in \(seconds) s, peak \(peak) MB")
        #expect(result.fallback == .tooComplex)
        #expect(result.html == MarkdownRenderer.sourceFallbackHTML(source))
        // The source bound refuses them before cmark runs.
        expectWithinBudget(seconds, 0.1 * Self.slack)
        // Soft: the whole test process, other suites included. Unguarded, 28 tables took 6.5 GB.
        #expect(peak < 2_000)
    }

    /// The table budget itself, measured on a body with no `$` in it, so it stays the bound on
    /// the table machinery alone that it has always been. `maxedTables` keeps the repro's `$x$`
    /// row; here it is spelled without the dollars, and `aPaddedTableWithMathCostsOneMoreParse`
    /// below measures what putting them back costs.
    @Test func aPaddedTableWithinTheBudgetRenders() {
        let source = Self.maxedTables(1, rows: 3_000).replacingOccurrences(of: "$x$", with: "xx")
        #expect(!source.contains("$"))
        #expect(CMarkDepthScan.measure(source).nodes < ParseLimits.defaultMaxNodes)
        let (result, seconds, peak) = Self.timedRender(source)
        print("K1 tables: padded table of 384,000 cells rendered in \(seconds) s, peak \(peak) MB")
        #expect(result.fallback == nil)
        #expect(result.html.components(separatedBy: "<tr").count - 1 == 3_002)
        expectWithinBudget(seconds, 1.0 * Self.slack)
        #expect(peak < 2_000)
    }

    /// S5: a body with a `$` in it is scanned for math before it is parsed, and that scan parses
    /// it once itself (`MathExtractor`, which then refuses this one for having more block nodes
    /// than `maxBlocks` and hands the body back unchanged). So the worst case costs one more
    /// parse than the same table without dollars — measured 2026-09-18 (release, Apple silicon):
    /// 0.50 s without, 0.90 s with. Two parses, not "a few", is the bound this holds to.
    @Test func aPaddedTableWithMathCostsOneMoreParse() {
        let plain = Self.maxedTables(1, rows: 3_000).replacingOccurrences(of: "$x$", with: "xx")
        let withMath = Self.maxedTables(1, rows: 3_000)
        #expect(withMath.contains("$x$"))
        let (plainResult, plainSeconds, _) = Self.timedRender(plain)
        let (mathResult, mathSeconds, peak) = Self.timedRender(withMath)
        print("K1 tables: padded table rendered in \(plainSeconds) s without math, \(mathSeconds) s with, peak \(peak) MB")
        // Same output either way: the table is too big to rewrite, so the `$x$` stays text.
        #expect(plainResult.fallback == nil)
        #expect(mathResult.fallback == nil)
        #expect(mathResult.html.contains("$x$"))
        #expect(mathResult.html.components(separatedBy: "<tr").count - 1 == 3_002)
        expectWithinBudget(mathSeconds, 2.0 * Self.slack)
        #expect(peak < 2_000)
    }

    @Test func aTenThousandRowTableRenders() {
        let source = Self.filledTable(rows: 10_000, columns: 10)
        let (result, seconds, _) = Self.timedRender(source)
        print("K1 tables: 10,000 x 10 table rendered in \(seconds) s")
        #expect(result.fallback == nil)
        #expect(result.html.components(separatedBy: "<tr").count - 1 == 10_001)
        #expect(result.html.contains("<td>r9999c9</td>"))
        expectWithinBudget(seconds, 1.0 * Self.slack)
    }

    @Test func rowsOfEmptyCellsFallBack() {
        let source = "a|b\n-|-\n" + String(repeating: "|", count: 65_000) + "\n"
        let (result, seconds, _) = Self.timedRender(source)
        #expect(result.fallback == .tooComplex)
        expectWithinBudget(seconds, 0.1 * Self.slack)

        // The same pipes in a paragraph that a delimiter row tries to turn into a header.
        let header = String(repeating: String(repeating: "|", count: 65_000) + "\n-|-\n\n", count: 10)
        #expect(MarkdownRenderer.renderResult(header).fallback == .tooComplex)
    }

    @Test func longRunsOfRowSpanMarkersFallBack() {
        let source = Self.markerTable(rows: 2_000, columns: 64)
        let (result, seconds, _) = Self.timedRender(source)
        #expect(result.fallback == .tooComplex)
        expectWithinBudget(seconds, 0.1 * Self.slack)
    }

    @Test func rowSpanMarkersJustUnderTheLimitRenderInTime() {
        var rows = 1
        while TableCostBound.measure(Self.markerTable(rows: rows + 1, columns: 64)).work <= TableCostBound.maxWork {
            rows += 1
        }
        let source = Self.markerTable(rows: rows, columns: 64)
        #expect(rows > 300)
        let (result, seconds, _) = Self.timedRender(source)
        print("K1 tables: \(rows) rows of 64 row-span markers rendered in \(seconds) s")
        #expect(result.fallback == nil)
        expectWithinBudget(seconds, 1.0 * Self.slack)
        #expect(MarkdownRenderer.renderResult(Self.markerTable(rows: rows + 1, columns: 64)).fallback == .tooComplex)
    }

    @Test func ordinaryRowSpansRender() {
        let source = "| a | b |\n|---|---|\n| 1 | x |\n| ^ | y |\n| ^ | z |\n"
        let result = MarkdownRenderer.renderResult(source)
        #expect(result.fallback == nil)
        #expect(result.html.contains("<table"))
    }

    // MARK: The node budget

    @Test func theNodeLimitIsExact() {
        let prose = "a\n\nb *c*\n"
        let proseNodes = CMarkDepthScan.measure(prose).nodes
        #expect(proseNodes == 7)   // document, 2 paragraphs, 2 texts, emphasis and its text
        #expect(Self.outcome(prose, maxNodes: proseNodes) == "document")
        #expect(Self.outcome(prose, maxNodes: proseNodes - 1) == "tooComplex")

        let table = "| a | b |\n|---|---|\n| 1 |\n| 2 | 3 |\n"
        let tableNodes = CMarkDepthScan.measure(table).nodes
        #expect(TableCostBound.measure(table).cells < tableNodes)
        #expect(Self.outcome(table, maxNodes: tableNodes) == "document")
        #expect(Self.outcome(table, maxNodes: tableNodes - 1) == "tooComplex")

        let options = MarkdownRenderer.Options(maxNodes: tableNodes - 1)
        #expect(MarkdownRenderer.renderResult(table, options: options).fallback == .tooComplex)
        #expect(MarkdownRenderer.renderResult(table, options: options).html == MarkdownRenderer.sourceFallbackHTML(table))
        #expect(ParseLimits(maxNodes: -5).maxNodes == 1)
        #expect(ParseLimits().maxNodes == ParseLimits.defaultMaxNodes)
        #expect(MarkdownRenderer.Options().maxNodes == ParseLimits.defaultMaxNodes)
    }

    @Test func denseDocumentsPastTheBudgetFallBackQuickly() {
        let paragraph = "Word *em* **strong** `code` [link](u) ~~del~~ word.\n\n"
        let source = String(repeating: paragraph, count: 50_000)   // 2.6 MB, over a million nodes
        let (result, seconds, _) = Self.timedRender(source)
        #expect(result.fallback == .tooComplex)
        expectWithinBudget(seconds, 1.0 * Self.slack)
    }

    private static func outcome(_ source: String, maxNodes: Int) -> String {
        MarkdownParsing.withDocument(source, options: ParseLimits(maxNodes: maxNodes)) { outcome in
            switch outcome {
            case .document: "document"
            case .tooDeep: "tooDeep"
            case .tooLarge: "tooLarge"
            case .tooComplex: "tooComplex"
            }
        }
    }

    // MARK: The source bound never undercounts

    @Test func cellBoundCoversCmarksCells() {
        var inputs = MarkdownNestingTests.corpus
        inputs += [
            Self.maxedTables(1), Self.maxedTables(3, columns: 7, rows: 20),
            Self.filledTable(rows: 50, columns: 6), Self.markerTable(rows: 30, columns: 5),
            "a|b\n-|-\n" + String(repeating: "|", count: 300) + "\n",
            "|" + String(repeating: "a|", count: 40) + "\n" + String(repeating: "-|", count: 40) + "-\n" + "x\n",
        ]
        var random = SeededGenerator(seed: 0x7AB1E)
        for _ in 0..<3_000 {
            inputs.append(Self.randomTables(using: &random))
        }
        var failures: [String] = []
        for input in inputs {
            let bound = TableCostBound.measure(input).cells
            let real = cmarkTableCells(input)
            if bound < real {
                failures.append("bound \(bound) < cmark \(real): \(input.prefix(300).debugDescription)")
            }
        }
        #expect(failures.isEmpty, "\(failures.prefix(3))")
    }

    /// Tables in every container and line ending, with ragged rows, empty and escaped cells,
    /// markers, several tables in one run, and multi-line headers.
    static func randomTables(using random: inout SeededGenerator) -> String {
        let prefixes = ["", "", "> ", "- ", "1. ", ">   ", "  ", "> > ", "- > "]
        let endings = ["\n", "\n", "\r\n", "\r"]
        let cellTexts = ["a", "", " ", "^", " ^ ", "\\|", "x^2", "`|`", "*b*", "-", ":", "|"]
        let prefix = prefixes.randomElement(using: &random)!
        let ending = endings.randomElement(using: &random)!
        var lines: [String] = []
        for _ in 0..<Int.random(in: 1...3, using: &random) {
            let columns = Int.random(in: 1...9, using: &random)
            for _ in 0..<Int.random(in: 0...2, using: &random) {
                lines.append(["text", "more | text", "| a |", "# heading", "---"].randomElement(using: &random)!)
            }
            func row(_ count: Int) -> String {
                let cells = (0..<count).map { _ in cellTexts.randomElement(using: &random)! }
                let lead = Bool.random(using: &random) ? "|" : ""
                let trail = Bool.random(using: &random) ? "|" : ""
                return lead + cells.joined(separator: "|") + trail
            }
            lines.append(row(columns))
            let delimiterColumns = max(1, columns + Int.random(in: -1...1, using: &random))
            let markers = (0..<delimiterColumns).map { _ in [":-", "-", "--:", " :-: ", "---"].randomElement(using: &random)! }
            lines.append((Bool.random(using: &random) ? "|" : "") + markers.joined(separator: "|") + (Bool.random(using: &random) ? "| " : ""))
            for _ in 0..<Int.random(in: 0...25, using: &random) {
                switch Int.random(in: 0..<10, using: &random) {
                case 0: lines.append("")
                case 1: lines.append("   ")
                case 2: lines.append("plain line")
                default: lines.append(row(Int.random(in: 0...(columns + 3), using: &random)))
                }
            }
        }
        return lines.map { prefix + $0 }.joined(separator: ending) + ending
    }

    @Test func boundScanIsFast() {
        let source = String(repeating: Self.filledTable(rows: 1_000, columns: 10), count: 5)   // about 500 KB
        let clock = ContinuousClock()
        let elapsed = clock.measure { _ = TableCostBound.measure(source) }
        expectWithinBudget(Self.seconds(elapsed), 0.05 * Self.slack)
    }
}

/// The table cells cmark-gfm creates, with swift-markdown's parser setup.
func cmarkTableCells(_ source: String) -> Int {
    cmark_gfm_core_extensions_ensure_registered()
    let parser = cmark_parser_new(CMARK_OPT_TABLE_SPANS | CMARK_OPT_SMART | CMARK_OPT_SOURCEPOS)!
    defer { cmark_parser_free(parser) }
    for name in ["table", "strikethrough", "tasklist"] {
        cmark_parser_attach_syntax_extension(parser, cmark_find_syntax_extension(name))
    }
    cmark_parser_feed(parser, source, source.utf8.count)
    let root = cmark_parser_finish(parser)!
    defer { cmark_node_free(root) }
    let iterator = cmark_iter_new(root)!
    defer { cmark_iter_free(iterator) }
    var cells = 0
    while true {
        let event = cmark_iter_next(iterator)
        if event == CMARK_EVENT_DONE { return cells }
        if event == CMARK_EVENT_ENTER,
           String(cString: cmark_node_get_type_string(cmark_iter_get_node(iterator))) == "table_cell" {
            cells += 1
        }
    }
}

/// The process's peak resident memory so far, in megabytes.
func peakResidentMegabytes() -> Int {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let status = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(task_self_trap(), task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return status == KERN_SUCCESS ? Int(info.resident_size_max / 1_048_576) : 0
}
