import Foundation
import Markdown
import Synchronization
import Testing
@testable import MarsDawnKit

struct MarkdownParsingWorkerTests {
    @Test func bodiesRunOnABigStackWorkerAndNowhereElse() {
        #expect(!MarkdownParsing.isOnWorker)
        let (onWorker, stackSize, systemStackSize) = MarkdownParsing.withDocument("a") { _ in
            (MarkdownParsing.isOnWorker, Thread.current.stackSize, pthread_get_stacksize_np(pthread_self()))
        }
        #expect(onWorker)
        #expect(stackSize == 64 << 20)
        #expect(systemStackSize >= 64 << 20)
        #expect(!MarkdownParsing.isOnWorker)

        let secondStack = MarkdownParsing.withDocument("a") { _ in Thread.current.stackSize }
        #expect(secondStack == MarkdownParsing.workerStackSize)
    }

    @Test func asyncBodiesRunOnAWorkerToo() async throws {
        let stackSize = try #require(await MarkdownParsing.withDocument("a") { _ in
            MarkdownParsing.isOnWorker ? pthread_get_stacksize_np(pthread_self()) : 0
        })
        #expect(stackSize >= 64 << 20)
    }

    @Test func workersTakeTheCallersQualityOfServiceAtLeastUserInitiated() async {
        #expect(MarkdownParsing.callerQualityOfService(QOS_CLASS_BACKGROUND) == .userInitiated)
        #expect(MarkdownParsing.callerQualityOfService(QOS_CLASS_UTILITY) == .userInitiated)
        #expect(MarkdownParsing.callerQualityOfService(QOS_CLASS_USER_INTERACTIVE) == .userInteractive)
        #expect(MarkdownParsing.callerQualityOfService(TaskPriority.background) == .userInitiated)
        #expect(MarkdownParsing.callerQualityOfService(TaskPriority.high) == .userInitiated)
        #expect(MarkdownParsing.callerQualityOfService(TaskPriority(rawValue: 33)) == .userInteractive)

        let fromInteractiveThread = onSmallStackThread {
            pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0)
            return MarkdownParsing.withDocument("a") { _ in Thread.current.qualityOfService }
        }
        #expect(fromInteractiveThread == .userInteractive)
        let fromBackground = await Task.detached(priority: .background) {
            await MarkdownParsing.withDocument("a") { _ in Thread.current.qualityOfService }
        }.value
        #expect(fromBackground == .userInitiated)
    }

    @Test func parsingOffTheWorkerTraps() async {
        #expect(!MarkdownParsing.isOnWorker)
        await #expect(processExitsWith: .failure) {
            _ = MarkdownParsing.parseChecked("# a")
        }
    }

    @Test func parsesTheDocumentForTheBody() {
        let summary = MarkdownParsing.withDocument("# Title\n\n> quote\n") { outcome -> String in
            guard case .document(let document) = outcome else { return "no document" }
            return document.children.map { String(describing: type(of: $0)) }.joined(separator: ",")
        }
        #expect(summary == "Heading,BlockQuote")
    }

    @Test func nestedCallsRunInlineEvenWithEverySlotTaken() {
        let gate = WorkerGate(slots: 1)
        let finished = DispatchSemaphore(value: 0)
        let inner = Mutex<(Bool, String)?>(nil)
        Thread.detachNewThread {
            let value = MarkdownParsing.withDocument("outer", options: .default, gate: gate) { _ in
                // The only slot is ours; a nested call must not wait for one.
                MarkdownParsing.withDocument("*inner*", options: .default, gate: gate) { outcome -> (Bool, String) in
                    guard case .document(let document) = outcome else { return (false, "") }
                    return (MarkdownParsing.isOnWorker, document.format())
                }
            }
            inner.withLock { $0 = value }
            finished.signal()
        }
        #expect(finished.wait(timeout: .now() + 10) == .success, "nested withDocument deadlocked")
        let value = inner.withLock { $0 }
        #expect(value?.0 == true)
        #expect(value?.1 == "*inner*")

        // The shared gate as well, and the public entry point.
        let shared = MarkdownParsing.withDocument("a") { _ in
            MarkdownParsing.withDocument("b") { _ in MarkdownParsing.withDocument("c") { _ in 3 } }
        }
        #expect(shared == 3)
        #expect(gate.snapshot == (available: 1, queued: 0))
    }

    @Test func onlyTheParsingFileParses() throws {
        let sources = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        #expect(files.count > 5)
        var hits: [String: Int] = [:]
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let count = text.components(separatedBy: "Document(parsing:").count - 1
            if count > 0 { hits[file.lastPathComponent] = count }
        }
        #expect(hits == ["MarkdownParsing.swift": 1])
    }
}

/// The two-slot gate: FIFO hand-off, cancellation of waiters, exactly-once resumption.
struct WorkerGateTests {
    @Test func cancellingAWaiterReturnsNilPromptlyAndNeverRunsItsBody() async throws {
        let resumes = Counter<UInt64>()
        let gate = WorkerGate(slots: 2) { ticket, _ in resumes.add(ticket) }
        let latch = Latch(waiters: 2)
        let started = Counter<Int>()
        let cancelledBodyRan = Mutex(false)

        let holders = (1...2).map { index in
            Task.detached {
                await MarkdownParsing.withDocument("a", options: .default, gate: gate) { _ in
                    started.add(index)
                    latch.wait()
                    return index
                }
            }
        }
        #expect(await eventually { started.values.count == 2 })

        let pending = Task.detached {
            await MarkdownParsing.withDocument("a", options: .default, gate: gate) { _ in
                cancelledBodyRan.withLock { $0 = true }
                return 3
            }
        }
        let waiting = Task.detached {
            await MarkdownParsing.withDocument("a", options: .default, gate: gate) { _ in 4 }
        }
        #expect(await eventually { gate.snapshot.queued == 2 })

        let cancelledAt = ContinuousClock.now
        pending.cancel()
        let pendingValue = await pending.value
        #expect(pendingValue == nil)
        #expect(ContinuousClock.now - cancelledAt < .seconds(2))
        #expect(gate.snapshot == (available: 0, queued: 1))

        latch.open()
        #expect(await holders[0].value == 1)
        #expect(await holders[1].value == 2)
        #expect(await waiting.value == 4)
        #expect(!cancelledBodyRan.withLock { $0 })
        #expect(gate.snapshot == (available: 2, queued: 0))
        // Four async jobs: two started at once, one cancelled while queued and one started
        // on release. Each was started or cancelled exactly once.
        #expect(resumes.values.values.allSatisfy { $0 == 1 })
        #expect(resumes.values.count == 4)
    }

    /// Regression: a slot handed to an async caller used to wait until that caller's task was
    /// scheduled. With the task pool full of blocking callers, that never happened, and every
    /// caller waited forever. Here the async caller's executor is suspended instead.
    @Test func aSlotHandedToAnAsyncCallerNeverWaitsForItsExecutor() async {
        let gate = WorkerGate(slots: 1)
        let latch = Latch(waiters: 1)
        let holding = Counter<Int>()
        let finished = Counter<String>()
        Thread.detachNewThread {
            _ = MarkdownParsing.withDocument("h", options: .default, gate: gate) { _ in
                holding.add(0)
                latch.wait()
                return 0
            }
            finished.add("holder")
        }
        #expect(await eventually { !holding.values.isEmpty })

        let executor = SuspendableExecutor()
        let bodyRan = Counter<Int>()
        let waiter = Task(executorPreference: executor) {
            await MarkdownParsing.withDocument("w", options: .default, gate: gate) { _ in
                bodyRan.add(0)
                return 7
            }
        }
        #expect(await eventually { gate.snapshot.queued == 1 })

        executor.suspend()
        latch.open()
        #expect(await eventually { finished.values["holder"] == 1 })
        // The waiter's body runs, and its slot comes back, while its executor can't run anything.
        #expect(await eventually { !bodyRan.values.isEmpty })
        Thread.detachNewThread {
            _ = MarkdownParsing.withDocument("b", options: .default, gate: gate) { _ in 8 }
            finished.add("blocking caller")
        }
        #expect(await eventually { finished.values["blocking caller"] == 1 }, "the slot stayed with a suspended task")
        executor.resume()
        #expect(await waiter.value == 7)
        #expect(gate.snapshot == (available: 1, queued: 0))
    }

    /// The same deadlock end to end: blocking callers on every task-pool thread, async
    /// callers queued among them.
    @Test(.timeLimit(.minutes(1)))
    func blockingCallersFillingTheTaskPoolDontStallAsyncCallers() async {
        let gate = WorkerGate(slots: 2)
        let callers = ProcessInfo.processInfo.activeProcessorCount * 4
        let document = String(repeating: "- item *text*\n", count: 2_000)
        let total = await withTaskGroup(of: Int.self) { group in
            for index in 0..<callers {
                group.addTask {
                    let count: @Sendable (ParseOutcome) -> Int = { outcome in
                        guard case .document(let parsed) = outcome else { return 0 }
                        return parsed.childCount
                    }
                    if index.isMultiple(of: 2) {
                        return Self.blockingParse(document, gate: gate, count)
                    }
                    return await MarkdownParsing.withDocument(document, options: .default, gate: gate, count) ?? 0
                }
            }
            return await group.reduce(0, +)
        }
        #expect(total == callers)
        #expect(gate.snapshot == (available: 2, queued: 0))
    }

    private static func blockingParse(
        _ source: String, gate: WorkerGate, _ body: @escaping @Sendable (ParseOutcome) -> Int
    ) -> Int {
        MarkdownParsing.withDocument(source, options: .default, gate: gate, body)
    }

    @Test func alreadyCancelledTasksNeverStart() async {
        let gate = WorkerGate(slots: 2)
        let ran = Mutex(false)
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return await MarkdownParsing.withDocument("a", options: .default, gate: gate) { _ in
                ran.withLock { $0 = true }
                return 1
            }
        }
        #expect(await task.value == nil)
        #expect(!ran.withLock { $0 })
        #expect(gate.snapshot == (available: 2, queued: 0))
    }

    @Test func cancellationRacingCompletionResumesEachWaiterOnce() async {
        let resumes = Counter<UInt64>()
        let gate = WorkerGate(slots: 1) { ticket, _ in resumes.add(ticket) }
        var outcomes = (cancelled: 0, completed: 0)
        for iteration in 0..<1_000 {
            let latch = Latch(waiters: 1)
            let holding = Counter<Int>()
            let holder = Task.detached {
                await MarkdownParsing.withDocument("h", options: .default, gate: gate) { _ in
                    holding.add(0)
                    latch.wait()
                    return 0
                }
            }
            _ = await eventually { !holding.values.isEmpty }
            let racer = Task.detached {
                await MarkdownParsing.withDocument("r", options: .default, gate: gate) { _ in iteration }
            }
            if iteration % 2 == 0 {
                _ = await eventually { gate.snapshot.queued == 1 }
            }
            // Cancel and complete at the same moment.
            await withTaskGroup(of: Void.self) { group in
                group.addTask { racer.cancel() }
                group.addTask { latch.open() }
            }
            #expect(await holder.value == 0)
            switch await racer.value {
            case nil: outcomes.cancelled += 1
            case let value?:
                #expect(value == iteration)
                outcomes.completed += 1
            }
        }
        #expect(outcomes.cancelled + outcomes.completed == 1_000)
        #expect(gate.snapshot == (available: 1, queued: 0))
        #expect(resumes.values.values.allSatisfy { $0 == 1 }, "a waiter was resumed twice")
    }

    @Test func blockingAndAsyncWaitersShareOneQueue() async {
        let gate = WorkerGate(slots: 2)
        let latch = Latch(waiters: 8)
        let running = Counter<Int>()
        let active = Mutex((now: 0, peak: 0))
        let bodies = (0..<8).map { index in
            Task.detached {
                let body: @Sendable (ParseOutcome) -> Int = { _ in
                    active.withLock { $0.now += 1; $0.peak = max($0.peak, $0.now) }
                    running.add(index)
                    latch.wait()
                    active.withLock { $0.now -= 1 }
                    return index
                }
                if index.isMultiple(of: 2) {
                    // Blocking callers wait on threads of their own, not on the task pool.
                    return await withCheckedContinuation { continuation in
                        Thread.detachNewThread {
                            continuation.resume(returning: MarkdownParsing.withDocument("x", options: .default, gate: gate, body))
                        }
                    }
                }
                return await MarkdownParsing.withDocument("x", options: .default, gate: gate, body) ?? -1
            }
        }
        #expect(await eventually { running.values.count == 2 })
        #expect(await eventually { gate.snapshot.queued == 6 })
        latch.open()
        var values: [Int] = []
        for body in bodies { values.append(await body.value) }
        #expect(values == Array(0..<8))
        #expect(active.withLock { $0.peak } == 2)
        #expect(gate.snapshot == (available: 2, queued: 0))
    }
}

/// Overhead of the guarded entry point (F16/F18). Soft bounds in debug builds.
@Suite(.serialized)
struct MarkdownParsingTimingTests {
    #if DEBUG
    static let slack = 10.0
    #else
    static let slack = 1.0
    #endif

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    static let sampleDocument = """
    # Release notes

    Some **bold** text, a [link](https://example.com), `code` and ~~gone~~.

    - [x] one
    - [ ] two
      > quoted *text*

    | a | b |
    |---|---|
    | 1 | 2 |

    ```swift
    let value = 1 < 2
    ```


    """

    @Test func smallDocumentsStayCheap() {
        let clock = ContinuousClock()
        let count = 500
        let elapsed = clock.measure {
            for _ in 0..<count { _ = MarkdownRenderer.render(Self.sampleDocument) }
        }
        let perCall = Self.seconds(elapsed) / Double(count)
        print("K1 timing: small document render \(String(format: "%.3f", perCall * 1000)) ms per call")
        #expect(perCall < 0.005 * Self.slack)
    }

    @Test func fiveMegabyteDocument() {
        let repeats = 5_000_000 / Self.sampleDocument.utf8.count + 1
        let source = String(repeating: Self.sampleDocument, count: repeats)
        let clock = ContinuousClock()
        var scanDepth = 0
        let scan = clock.measure { scanDepth = CMarkDepthScan.maximumDepth(of: source) }
        var result: MarkdownRenderer.RenderResult?
        let total = clock.measure { result = MarkdownRenderer.renderResult(source) }
        print("K1 timing: \(source.utf8.count / 1_000_000) MB document: pre-scan \(Self.seconds(scan)) s, guarded render \(Self.seconds(total)) s")
        #expect(scanDepth == 7)  // document > list > item > quote > paragraph > emphasis > text
        #expect(result?.fallback == nil)
        #expect(Self.seconds(total) < 3 * Self.slack)
    }

    @Test func deepestAcceptedDocumentWithAFiveMegabytePayload() {
        // Plain text and inline HTML only: emphasis would add a level.
        let line = "lorem ipsum dolor sit amet & <consectetur>\n"
        let payload = String(repeating: line, count: 5_000_000 / line.utf8.count + 1)
        let shallow = "> start\n" + payload
        let deep = String(repeating: ">", count: ParseLimits.default.maxDepth - 5) + " start\n" + payload
        #expect(CMarkDepthScan.maximumDepth(of: deep) == ParseLimits.default.maxDepth - 2)

        let clock = ContinuousClock()
        var result: MarkdownRenderer.RenderResult?
        let shallowTime = clock.measure { _ = onSmallStackThread { MarkdownRenderer.render(shallow) } }
        let deepTime = clock.measure {
            result = onSmallStackThread { MarkdownRenderer.renderResult(deep) }
        }
        print("K1 timing: 5 MB payload at depth 4 \(Self.seconds(shallowTime)) s, at depth \(ParseLimits.default.maxDepth - 2) \(Self.seconds(deepTime)) s")
        #expect(result?.fallback == nil)
        #expect(result?.html.hasSuffix(String(repeating: "</blockquote>\n", count: 3)) == true)
        // About 1 s in release, nearly all of it the payload itself: nesting must not add much.
        #expect(Self.seconds(deepTime) < 1.5 * Self.slack)
        #expect(Self.seconds(deepTime) < 1.5 * Self.seconds(shallowTime) + 0.25)
    }
}
