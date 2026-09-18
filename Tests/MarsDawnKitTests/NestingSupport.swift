import Foundation
import Markdown
import Synchronization
@testable import MarsDawnKit

/// Markdown shapes that really nest, one container or inline level per repetition.
enum NestingShape: String, CaseIterable, Sendable {
    case blockQuotes
    case indentedLists
    case images
    case emphasis
    case alternatingEmphasis
    case inlineAttributes
    case quotedLists

    /// Repetitions used for the "far too deep" inputs.
    var deepCount: Int {
        switch self {
        case .indentedLists: 2_000   // about 4 MB: each line is indented one level further
        case .quotedLists: 1_000     // about 2 MB, three levels per line
        default: 20_000
        }
    }

    func source(_ n: Int) -> String {
        switch self {
        case .blockQuotes:
            return String(repeating: ">", count: n) + " a\n"
        case .indentedLists:
            var text = ""
            for level in 0..<n {
                text += String(repeating: "  ", count: level) + "- a\n"
            }
            return text
        case .images:
            return String(repeating: "![", count: n) + "x" + String(repeating: "](u)", count: n) + "\n"
        case .emphasis:
            return String(repeating: "*", count: n) + "a" + String(repeating: "*", count: n) + "\n"
        case .alternatingEmphasis:
            let openers = ["*a ", "_a ", "~~a "]
            let closers = [" a*", " a_", " a~~"]
            // Built in steps: Xcode 26's type checker gives up on the single expression.
            let open: String = (0..<n).map { openers[$0 % 3] }.joined()
            let close: String = (0..<n).reversed().map { closers[$0 % 3] }.joined()
            return open + "x" + close + "\n"
        case .inlineAttributes:
            return String(repeating: "^[", count: n) + "x" + String(repeating: "](u)", count: n) + "\n"
        case .quotedLists:
            var text = ""
            for level in 0..<n {
                text += String(repeating: ">   ", count: level) + "> - a\n"
            }
            return text
        }
    }

    /// The deepest input of this shape whose pre-scan depth is at most `depth`.
    func source(depthAtMost depth: Int) -> (source: String, depth: Int) {
        var best = (source: source(1), depth: CMarkDepthScan.maximumDepth(of: source(1)))
        var n = 1
        while true {
            n += 1
            let candidate = source(n)
            let candidateDepth = CMarkDepthScan.maximumDepth(of: candidate)
            if candidateDepth > depth { return best }
            best = (candidate, candidateDepth)
        }
    }
}

/// Runs `work` on a new thread with a small stack (512 KB, like a cooperative-pool thread)
/// and waits for it.
func onSmallStackThread<T: Sendable>(stackSize: Int = 512 << 10, _ work: @escaping @Sendable () -> T) -> T {
    let result = Mutex<T?>(nil)
    let done = DispatchSemaphore(value: 0)
    let thread = Thread {
        let value = work()
        result.withLock { $0 = value }
        done.signal()
    }
    thread.stackSize = stackSize
    thread.start()
    done.wait()
    return result.withLock { $0.take() }!
}

/// The peak stack in bytes that `work` uses, measured on the calling thread.
///
/// The unused stack below this frame is painted with a pattern, `work` runs, and the
/// lowest address that no longer holds the pattern is how far the deepest call reached.
/// The bottom 64 KB is left alone (guard page and thread bookkeeping) and so is the 8 KB
/// just below this frame, so an answer is only ever a slight under-count of the region
/// searched, never an over-count of what was used.
///
/// Returns nil if the painted region was used up, which means the answer would be a lower
/// bound rather than a measurement.
func peakStackUsage(_ work: () -> Void) -> Int? {
    let top = pthread_get_stackaddr_np(pthread_self())
    let size = pthread_get_stacksize_np(pthread_self())
    var marker = 0
    let frame = withUnsafeMutablePointer(to: &marker) { UnsafeMutableRawPointer($0) }
    let paintLow = top.advanced(by: -size + (64 << 10))
    let paintHigh = frame.advanced(by: -(8 << 10))
    let painted = paintLow.distance(to: paintHigh)
    guard painted > 0 else { return nil }
    memset(paintLow, 0xA5, painted)

    work()

    let bytes = paintLow.assumingMemoryBound(to: UInt8.self)
    var index = 0
    while index < painted, bytes[index] == 0xA5 { index += 1 }
    // Index 0 means the deepest call reached past the paint, so this is not a measurement.
    guard index > 0 else { return nil }
    return paintLow.advanced(by: index).distance(to: top)
}

/// The depth of a swift-markdown tree (the document counts as 1), walked with an explicit stack.
func swiftMarkdownDepth(_ root: any Markup) -> Int {
    var deepest = 0
    var stack: [(any Markup, Int)] = [(root, 1)]
    while let item = stack.popLast() {
        let (node, depth) = item
        deepest = max(deepest, depth)
        for child in node.children {
            stack.append((child, depth + 1))
        }
    }
    return deepest
}

/// A one-shot latch that test bodies block on.
final class Latch: Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let waiters: Int

    init(waiters: Int) { self.waiters = waiters }

    func wait() { semaphore.wait() }

    func open() {
        for _ in 0..<waiters { semaphore.signal() }
    }
}

/// A thread-safe counter keyed by an ID.
final class Counter<Key: Hashable & Sendable>: Sendable {
    private let counts = Mutex<[Key: Int]>([:])

    func add(_ key: Key) {
        counts.withLock { $0[key, default: 0] += 1 }
    }

    var values: [Key: Int] {
        counts.withLock { $0 }
    }
}

/// A task executor whose jobs can be held back, to stand in for a saturated task pool.
final class SuspendableExecutor: TaskExecutor {
    private let queue = DispatchQueue(label: "SuspendableExecutor")

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        queue.async { [self] in
            job.runSynchronously(on: asUnownedTaskExecutor())
        }
    }

    func suspend() { queue.suspend() }
    func resume() { queue.resume() }
}

/// Polls `condition` until it holds or `timeout` passes.
func eventually(timeout: Duration = .seconds(10), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return condition()
}
