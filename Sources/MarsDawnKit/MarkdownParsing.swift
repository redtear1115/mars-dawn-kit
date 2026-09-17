import Foundation
import Markdown
import os
import cmark_gfm
import cmark_gfm_extensions

// swift-markdown converts cmark's tree into Swift nodes recursively, and every visitor and
// walker over those nodes recurses too. Deeply nested input (`>>>>…`, nested emphasis,
// nested images, indented lists) therefore overflows small stacks: the 512 KB of a
// cooperative-pool thread, or a test runner's worker thread. This file is the only place
// in the package that parses Markdown into nodes, and it does so under two guards:
//
// 1. A depth and size pre-scan with cmark-gfm's own C parser, configured exactly as
//    swift-markdown configures it, walked without recursion. Input nested past
//    `ParseLimits.maxDepth`, or with more than `ParseLimits.maxNodes` nodes, is never turned
//    into Swift nodes.
// 2. Before that, a linear scan of the source bounds what cmark's table extension would
//    build and how long it would take (see `TableCostBound`), so hostile tables are refused
//    before cmark sees them.
// 3. The parse and every walk over its nodes run on a dedicated thread with a 64 MB stack.
//    That thread gives stack headroom; it is not crash isolation.

/// Limits applied before a document is parsed.
public struct ParseLimits: Sendable, Equatable {
    /// The deepest nesting any caller may allow.
    ///
    /// Stack budget, measured 2026-09-17 (Apple silicon, macOS 26.6, Swift 6.4, swift-markdown
    /// 0.8.0): the smallest worker stack on which `MarkdownRenderer` parses, renders and
    /// releases the deepest accepted input (pre-scan depth 252-254), for each nesting shape
    /// in `MarkdownNestingTests` plus quotes around nested images. Searched in 16 KB steps.
    /// - DEBUG: 368-432 KB (about 1.5 KB per level), so 64 MB is a 150x margin.
    /// - Release: 224 KB (images) to 2,032 KB (inline attributes, emphasis), up to 8 KB per
    ///   level because of inlining, so 64 MB is a 32x margin (it would hold about 8,000 levels).
    /// Both are well past the required 4x. Bodies with bigger frames per level (walkers,
    /// rewriters) eat into that margin, so re-measure when adding one.
    public static let depthCeiling = 256

    /// Documents whose tree (the document node counts as 1) plus two levels of headroom
    /// is deeper than this are rejected. Clamped to `1...depthCeiling`.
    public let maxDepth: Int
    /// Documents larger than this many UTF-8 bytes are rejected. `nil` means no limit.
    public let maxBytes: Int?

    /// The default node budget.
    ///
    /// Measured 2026-09-17 (release build, Apple silicon, macOS 26.6): parsing and rendering
    /// costs about 1.35 µs and 450 bytes per node. A table padded to 537,000 nodes renders in
    /// 0.72 s with a 245 MB peak; 1,070,000 nodes take 1.45 s and 479 MB. Ordinary Markdown
    /// has 20-45 nodes per KB (a 1 MB document is about 200,000 nodes and renders in 0.34 s),
    /// and a 10,000 x 10 table is 210,000 nodes (0.31 s, 102 MB). 500,000 nodes keeps the
    /// worst case near 0.7 s and 250 MB, and admits dense documents up to about 2.4 MB.
    public static let defaultMaxNodes = 500_000

    /// Documents that would have more nodes than this (table cells included) are rejected.
    /// At least 1.
    public let maxNodes: Int

    public init(maxDepth: Int = ParseLimits.depthCeiling, maxBytes: Int? = nil, maxNodes: Int = ParseLimits.defaultMaxNodes) {
        self.maxDepth = min(max(maxDepth, 1), Self.depthCeiling)
        self.maxBytes = maxBytes.map { max($0, 0) }
        self.maxNodes = max(maxNodes, 1)
    }

    public static let `default` = ParseLimits()
}

/// The result of a guarded parse, handed to a `MarkdownParsing.withDocument` body.
///
/// Not `Sendable`: swift-markdown's nodes aren't. An outcome is created and consumed on the
/// parsing worker only, and must not escape the body.
public enum ParseOutcome {
    /// The parsed document.
    case document(Document)
    /// The input nests `depth` levels deep, past the limit; it was not parsed.
    case tooDeep(depth: Int)
    /// The input is larger than `ParseLimits.maxBytes`; it was not parsed.
    case tooLarge
    /// The input would have more than `ParseLimits.maxNodes` nodes, or its tables would take
    /// too long to build; it was not parsed.
    case tooComplex
}

@available(*, unavailable, message: "Parsed nodes must stay on the parsing worker")
extension ParseOutcome: Sendable {}

/// Guarded Markdown parsing.
///
/// Each call parses `source` and runs `body` on a dedicated worker thread with a 64 MB
/// stack, then hands back only the body's `Sendable` result. At most two workers run at a
/// time; further calls wait for a free slot. The document and all of its nodes are released
/// on the worker before the result is returned, so nodes never reach the calling thread.
///
/// A `withDocument` call made from inside a body runs inline on the same worker.
public enum MarkdownParsing {
    /// Stack size of each worker thread.
    static let workerStackSize = 64 << 20
    /// How many workers may run at once.
    static let workerSlots = 2
    static let sharedGate = WorkerGate(slots: workerSlots)

    /// Whether the current thread is a parsing worker (and so may parse).
    static var isOnWorker: Bool {
        pthread_getspecific(workerKey) != nil
    }

    /// Parses `source` and runs `body` with the outcome on a parsing worker, blocking the
    /// calling thread until it finishes.
    ///
    /// Not for Swift concurrency contexts: it blocks the calling thread while it waits for a
    /// worker slot and for the body. Use the `async` overload there.
    public static func withDocument<T: Sendable>(
        _ source: String,
        options: ParseLimits = .default,
        _ body: @escaping @Sendable (ParseOutcome) -> T
    ) -> T {
        withDocument(source, options: options, gate: sharedGate, body)
    }

    /// Parses `source` and runs `body` with the outcome on a parsing worker, suspending
    /// (without blocking a thread) until a worker slot is free and the body has finished.
    ///
    /// Returns `nil` only if the task was cancelled before the body started; the body then
    /// never runs. A body that has started can't be stopped: it runs to completion and its
    /// result is returned even if the task was cancelled meanwhile.
    public static func withDocument<T: Sendable>(
        _ source: String,
        options: ParseLimits = .default,
        _ body: @escaping @Sendable (ParseOutcome) -> T
    ) async -> T? {
        await withDocument(source, options: options, gate: sharedGate, body)
    }

    // MARK: Internals

    static func withDocument<T: Sendable>(
        _ source: String,
        options: ParseLimits,
        gate: WorkerGate,
        _ body: @escaping @Sendable (ParseOutcome) -> T
    ) -> T {
        if isOnWorker {
            return parseAndRun(source, options, body)
        }
        let qos = callerQualityOfService(qos_class_self())
        gate.acquireBlocking()
        let result = OSAllocatedUnfairLock<T?>(initialState: nil)
        let done = DispatchSemaphore(value: 0)
        startWorker(qos: qos) {
            let value = parseAndRun(source, options, body)
            result.withLock { $0 = value }
            gate.release()
            done.signal()
        }
        done.wait()
        return result.withLock { $0.take() }!
    }

    static func withDocument<T: Sendable>(
        _ source: String,
        options: ParseLimits,
        gate: WorkerGate,
        _ body: @escaping @Sendable (ParseOutcome) -> T
    ) async -> T? {
        let qos = callerQualityOfService(Task.currentPriority)
        let ticket = gate.register()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
                // The gate starts the worker itself when a slot frees up, on the releasing
                // thread. Waiting for this task to be scheduled first could hold a slot idle
                // for as long as the task pool is busy (for example with blocking callers).
                gate.submit(
                    ticket,
                    start: {
                        startWorker(qos: qos) {
                            let value = parseAndRun(source, options, body)
                            gate.release()
                            continuation.resume(returning: value)
                        }
                    },
                    cancel: {
                        continuation.resume(returning: nil)
                    }
                )
            }
        } onCancel: {
            gate.cancel(ticket)
        }
    }

    /// Runs on the worker. The outcome, and with it every node, is released before returning.
    private static func parseAndRun<T>(
        _ source: String,
        _ options: ParseLimits,
        _ body: (ParseOutcome) -> T
    ) -> T {
        precondition(isOnWorker)
        let result: T
        do {
            let outcome = parseChecked(source, limits: options)
            result = body(outcome)
            withExtendedLifetime(outcome) {}
        }
        return result
    }

    /// The only parse in the package. Worker threads only.
    static func parseChecked(_ source: String, limits: ParseLimits = .default) -> ParseOutcome {
        precondition(isOnWorker, "Markdown is parsed only on a parsing worker")
        if let maxBytes = limits.maxBytes, source.utf8.count > maxBytes {
            return .tooLarge
        }
        let tables = TableCostBound.measure(source)
        if tables.cells > limits.maxNodes || tables.work > TableCostBound.maxWork {
            return .tooComplex
        }
        let scan = CMarkDepthScan.measure(source)
        // swift-markdown adds one level cmark doesn't have (a table body); keep one more spare.
        if scan.depth > limits.maxDepth - 2 {
            return .tooDeep(depth: scan.depth)
        }
        if scan.nodes > limits.maxNodes {
            return .tooComplex
        }
        return .document(Document(parsing: source))
    }

    private static func startWorker(qos: QualityOfService, _ work: @escaping @Sendable () -> Void) {
        let thread = Thread {
            // Any non-nil value marks the thread; nothing is ever read through it.
            pthread_setspecific(workerKey, UnsafeRawPointer(bitPattern: 1))
            work()
        }
        thread.name = "MarsDawnKit.MarkdownParsing"
        thread.stackSize = workerStackSize
        thread.qualityOfService = qos
        thread.start()
    }

    static func callerQualityOfService(_ qos: qos_class_t) -> QualityOfService {
        qos == QOS_CLASS_USER_INTERACTIVE ? .userInteractive : .userInitiated
    }

    static func callerQualityOfService(_ priority: TaskPriority) -> QualityOfService {
        priority.rawValue >= UInt8(QOS_CLASS_USER_INTERACTIVE.rawValue) ? .userInteractive : .userInitiated
    }
}

private let workerKey: pthread_key_t = {
    var key = pthread_key_t()
    let status = pthread_key_create(&key, nil)
    precondition(status == 0, "pthread_key_create failed: \(status)")
    return key
}()

// MARK: - Depth pre-scan

/// Measures a document's nesting depth and node count with cmark-gfm directly, without recursion.
enum CMarkDepthScan {
    /// The depth of the deepest node, counting the document node as 1.
    static func maximumDepth(of source: String) -> Int {
        measure(source).depth
    }

    /// The depth of the deepest node (the document node counts as 1) and the number of nodes.
    /// Both are `Int.max` if cmark fails to allocate, so a failure is always rejected.
    static func measure(_ source: String) -> (depth: Int, nodes: Int) {
        // The same setup as swift-markdown's MarkupParser.parseString (swift-markdown 0.8.0):
        // TABLE_SPANS | SMART | SOURCEPOS; table, strikethrough and tasklist; fed by length.
        cmark_gfm_core_extensions_ensure_registered()
        let options = CMARK_OPT_TABLE_SPANS | CMARK_OPT_SMART | CMARK_OPT_SOURCEPOS
        guard let parser = cmark_parser_new(options) else { return (.max, .max) }
        defer { cmark_parser_free(parser) }
        cmark_parser_attach_syntax_extension(parser, cmark_find_syntax_extension("table"))
        cmark_parser_attach_syntax_extension(parser, cmark_find_syntax_extension("strikethrough"))
        cmark_parser_attach_syntax_extension(parser, cmark_find_syntax_extension("tasklist"))
        cmark_parser_feed(parser, source, source.utf8.count)
        guard let root = cmark_parser_finish(parser) else { return (.max, .max) }
        defer { cmark_node_free(root) }
        guard let iterator = cmark_iter_new(root) else { return (.max, .max) }
        defer { cmark_iter_free(iterator) }

        // Leaves get only an ENTER event and empty containers get ENTER then EXIT, so only
        // nodes with children open a level.
        var open = 0
        var deepest = 0
        var nodes = 0
        while true {
            switch cmark_iter_next(iterator) {
            case CMARK_EVENT_ENTER:
                nodes += 1
                deepest = max(deepest, open + 1)
                if cmark_node_first_child(cmark_iter_get_node(iterator)) != nil {
                    open += 1
                }
            case CMARK_EVENT_EXIT:
                if cmark_node_first_child(cmark_iter_get_node(iterator)) != nil {
                    open -= 1
                }
            case CMARK_EVENT_DONE:
                return (deepest, nodes)
            default:
                return (.max, .max)
            }
        }
    }
}

// MARK: - Table cost bound

/// An upper bound, from the source alone, on what cmark-gfm's table extension (swift-cmark
/// 0.8.0, extensions/table.c) builds and on its two superlinear loops. Linear in the source.
///
/// cmark would otherwise be the problem itself: it pads every table row to the header's
/// width (up to 524,288 padded cells per table), so 28 tables of 128 columns and 4,200
/// one-cell rows (243 KB) make 15 million nodes and take 1.5 s and 3.7 GB inside cmark alone.
/// Two table loops are quadratic besides: each empty cell (`||`) scans the cells before it
/// in its row (a 63 KB row of pipes takes 1.7 s), and each row-span marker cell (`^`) walks
/// up through the marker rows above it (2,000 rows of 64 markers, 250 KB, take 13 s).
///
/// What the bound relies on, all from table.c and blocks.c:
/// - cmark reads lines ended by `\n`, `\r\n` or `\r`. A line of only spaces and tabs is
///   blank and ends any table. So a table's delimiter row, its body rows and the paragraph
///   that holds its header all lie in one run of consecutive non-blank lines.
/// - A delimiter row is one line whose tail (after container markers) is
///   `|? marker (| marker)* |? spacechar*`, with markers made of spaces, tabs, `:` and `-`.
///   So its column count is at most 1 + the pipes in the line's trailing run of
///   `| - : space tab \v \f`, and that run holds a `-`.
/// - The header has as many columns as the delimiter row, and every body row gets exactly
///   that many cells, so a line after a delimiter candidate has at most as many cells as the
///   widest candidate before it in its run. The header row's cells are counted at the
///   delimiter line.
/// - A row is parsed cell by cell, and the cells start over on each line. A row with `p`
///   pipes has at most `p + 1` cells, and its empty-cell loop runs at most `(p + 1)^2 / 2`
///   times. A line is parsed as a row at most three times (a failed continuation check, then
///   twice as part of a header paragraph; or a continuation check and a row), so each line in
///   a run with a delimiter candidate is charged `2 (p + 1)^2`.
/// - A marker cell is exactly `^` after trimming, so it is followed, past spaces, tabs, `\v`
///   and `\f`, by a pipe or the end of the line; each such `^` is counted. A marker's walk
///   goes up one row per step while the cell above is a marker, so through at most the lines
///   directly above it that hold a counted `^` (the delimiter row holds none) plus the header,
///   and each step finds the cell by walking the row, at most (columns + 1) cells.
/// - A paragraph is tried as a table header at most once (cmark marks it visited when that
///   fails), except where cmark can't turn a paragraph into a table, which can't happen in the
///   containers swift-markdown enables.
///
/// `MarkdownNestingTests` and `TableBudgetTests` check the cell bound against cmark's real
/// counts over a corpus and generated tables.
enum TableCostBound {
    /// The largest `work` accepted.
    ///
    /// Measured 2026-09-17 (release, Apple silicon): cmark spends 0.13-0.2 ns per unit of
    /// empty-cell work and 0.8-1.6 ns per unit of row-span work, so this limit keeps those
    /// loops under about 0.05 s and 0.4 s. Real tables stay far below it: 2,000 x 64 filled
    /// cells is 17 million units, 50,000 x 10 is 14 million, and 10,000 x 100 about 204 million.
    static let maxWork = 250_000_000

    /// `cells`: at most the table cells cmark creates. `work`: at most the iterations of the
    /// empty-cell and row-span loops.
    static func measure(_ source: String) -> (cells: Int, work: Int) {
        var copy = source
        return copy.withUTF8 { measure(bytes: $0) }
    }

    static func measure(bytes: UnsafeBufferPointer<UInt8>) -> (cells: Int, work: Int) {
        let newline = UInt8(ascii: "\n"), carriageReturn = UInt8(ascii: "\r")
        let pipe = UInt8(ascii: "|"), dash = UInt8(ascii: "-"), colon = UInt8(ascii: ":")
        let caret = UInt8(ascii: "^"), space = UInt8(ascii: " "), tab = UInt8(ascii: "\t")
        let verticalTab: UInt8 = 0x0B, formFeed: UInt8 = 0x0C

        var cells = 0
        var work = 0
        // State of the current run of non-blank lines.
        var widest = 0              // widest delimiter candidate so far; 0 if none
        var pendingWork = 0         // empty-cell work of lines before the first candidate
        var markerLinesAbove = 0    // consecutive lines just above that hold a marker

        func add(_ total: inout Int, _ amount: Int) {
            let (sum, overflow) = total.addingReportingOverflow(amount)
            total = overflow ? .max : sum
        }
        func product(_ values: Int...) -> Int {
            var result = 1
            for value in values {
                let (next, overflow) = result.multipliedReportingOverflow(by: value)
                if overflow { return .max }
                result = next
            }
            return result
        }

        var start = 0
        let count = bytes.count
        while start < count || (start == count && count == 0) {
            // Find the end of the line.
            var end = start
            while end < count, bytes[end] != newline, bytes[end] != carriageReturn { end += 1 }
            var next = end
            if next < count {
                next += (bytes[next] == carriageReturn && next + 1 < count && bytes[next + 1] == newline) ? 2 : 1
            }

            var pipes = 0
            var blank = true
            var markers = 0
            var index = start
            while index < end {
                let byte = bytes[index]
                if byte == pipe { pipes += 1 }
                if byte != space && byte != tab { blank = false }
                if byte == caret {
                    var after = index + 1
                    while after < end, bytes[after] == space || bytes[after] == tab
                            || bytes[after] == verticalTab || bytes[after] == formFeed {
                        after += 1
                    }
                    if after == end || bytes[after] == pipe { markers += 1 }
                }
                index += 1
            }

            if blank {
                widest = 0
                pendingWork = 0
                markerLinesAbove = 0
            } else {
                // Delimiter candidate: the trailing run of delimiter characters holds a dash.
                var runPipes = 0
                var runHasDash = false
                var back = end
                while back > start {
                    let byte = bytes[back - 1]
                    guard byte == pipe || byte == dash || byte == colon || byte == space
                        || byte == tab || byte == verticalTab || byte == formFeed else { break }
                    if byte == pipe { runPipes += 1 }
                    if byte == dash { runHasDash = true }
                    back -= 1
                }
                let columns = runHasDash ? runPipes + 1 : 0

                if widest > 0 {
                    add(&cells, widest)
                    add(&work, product(markers, widest + 1, markerLinesAbove + 1))
                }
                if columns > 0 {
                    add(&cells, columns)
                }
                let emptyCellWork = product(2, pipes + 1, pipes + 1)
                if widest > 0 || columns > 0 {
                    add(&work, pendingWork)
                    pendingWork = 0
                    add(&work, emptyCellWork)
                } else {
                    add(&pendingWork, emptyCellWork)
                }
                widest = max(widest, columns)
                markerLinesAbove = markers > 0 ? markerLinesAbove + 1 : 0
            }

            if next >= count { break }
            start = next
        }
        return (cells, work)
    }
}

// MARK: - Worker gate

/// A counting gate with FIFO hand-off, shared by blocking callers and async jobs.
///
/// A released slot goes straight to the oldest waiter: a blocked thread is woken, and an
/// async job is started right there, on the releasing thread, so a slot never waits for a
/// task to be scheduled. An async job cancelled before it gets a slot is removed and told
/// so. Every waiter is stored in exactly one place and removed under the lock before it is
/// started, cancelled or woken, so each of those happens exactly once.
final class WorkerGate: Sendable {
    typealias Action = @Sendable () -> Void

    private enum Waiter: Sendable {
        /// Registered, not yet submitted.
        case pending
        /// Cancelled before it was submitted.
        case cancelled
        case job(start: Action, cancel: Action)
        case blocked(DispatchSemaphore)
    }

    private struct State: Sendable {
        var available: Int
        var nextTicket: UInt64 = 0
        var waiters: [UInt64: Waiter] = [:]
        /// Tickets of queued jobs and blocked threads, oldest first.
        var queue: [UInt64] = []

        mutating func makeTicket() -> UInt64 {
            nextTicket += 1
            return nextTicket
        }

        mutating func takeSlotIfFree() -> Bool {
            guard available > 0, queue.isEmpty else { return false }
            available -= 1
            return true
        }
    }

    private enum Wake: Sendable {
        case start(UInt64, Action)
        case cancel(UInt64, Action)
        case signal(DispatchSemaphore)
    }

    private let state: OSAllocatedUnfairLock<State>
    /// Called once per async job as it is started (`true`) or cancelled (`false`); tests only.
    private let onWake: (@Sendable (_ ticket: UInt64, _ started: Bool) -> Void)?

    init(slots: Int, onWake: (@Sendable (_ ticket: UInt64, _ started: Bool) -> Void)? = nil) {
        precondition(slots > 0)
        state = OSAllocatedUnfairLock(initialState: State(available: slots))
        self.onWake = onWake
    }

    /// Free slots and queued waiters (test instrumentation).
    var snapshot: (available: Int, queued: Int) {
        state.withLock { ($0.available, $0.queue.count) }
    }

    /// Waits, blocking the thread, until a slot is free. Pair with `release()`.
    func acquireBlocking() {
        let semaphore = state.withLock { state -> DispatchSemaphore? in
            if state.takeSlotIfFree() { return nil }
            let semaphore = DispatchSemaphore(value: 0)
            let ticket = state.makeTicket()
            state.waiters[ticket] = .blocked(semaphore)
            state.queue.append(ticket)
            return semaphore
        }
        semaphore?.wait()
    }

    /// Reserves a ticket for an async job, so a cancellation that arrives before `submit`
    /// is not lost.
    func register() -> UInt64 {
        state.withLock { state in
            let ticket = state.makeTicket()
            state.waiters[ticket] = .pending
            return ticket
        }
    }

    /// Runs `start` once the job holds a slot (now, or later on a releasing thread), or
    /// `cancel` if the job was cancelled first. `start` must lead to exactly one `release()`.
    func submit(_ ticket: UInt64, start: @escaping Action, cancel: @escaping Action) {
        let wake = state.withLock { state -> Wake? in
            switch state.waiters[ticket] {
            case .cancelled:
                state.waiters[ticket] = nil
                return .cancel(ticket, cancel)
            case .pending:
                if state.takeSlotIfFree() {
                    state.waiters[ticket] = nil
                    return .start(ticket, start)
                }
                state.waiters[ticket] = .job(start: start, cancel: cancel)
                state.queue.append(ticket)
                return nil
            default:
                preconditionFailure("Gate ticket \(ticket) submitted twice")
            }
        }
        perform(wake)
    }

    /// Removes a job that doesn't hold a slot yet. A started job is left alone.
    func cancel(_ ticket: UInt64) {
        let wake = state.withLock { state -> Wake? in
            switch state.waiters[ticket] {
            case .pending:
                state.waiters[ticket] = .cancelled
                return nil
            case .job(_, let cancel):
                state.waiters[ticket] = nil
                state.queue.removeAll { $0 == ticket }
                return .cancel(ticket, cancel)
            default:
                return nil
            }
        }
        perform(wake)
    }

    func release() {
        let wake = state.withLock { state -> Wake? in
            while !state.queue.isEmpty {
                let ticket = state.queue.removeFirst()
                switch state.waiters.removeValue(forKey: ticket) {
                case .job(let start, _):
                    return .start(ticket, start)
                case .blocked(let semaphore):
                    return .signal(semaphore)
                default:
                    preconditionFailure("Gate queue holds ticket \(ticket) that isn't waiting")
                }
            }
            state.available += 1
            return nil
        }
        perform(wake)
    }

    private func perform(_ wake: Wake?) {
        switch wake {
        case .start(let ticket, let start):
            onWake?(ticket, true)
            start()
        case .cancel(let ticket, let cancel):
            onWake?(ticket, false)
            cancel()
        case .signal(let semaphore):
            semaphore.signal()
        case nil:
            break
        }
    }
}
