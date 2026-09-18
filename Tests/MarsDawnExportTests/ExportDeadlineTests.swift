#if os(macOS)
import Foundation
import Synchronization
import Testing
@testable import MarsDawnExport
@testable import MarsDawnKit

@Suite(.timeLimit(.minutes(1)))
struct ExportDeadlineTests {
    struct Timeout: Error {}
    struct Failure: Error {}

    @Test func returnsTheResultBeforeTheDeadline() async throws {
        let value = try await withExportDeadline(.now + .seconds(10), timeoutError: Timeout()) { 42 }
        #expect(value == 42)
    }

    @Test func passesErrorsThrough() async {
        await #expect(throws: Failure.self) {
            try await withExportDeadline(.now + .seconds(10), timeoutError: Timeout()) { () async throws -> Int in
                throw Failure()
            }
        }
    }

    @Test func stopsWaitingAtTheDeadlineForWorkThatCantBeStopped() async {
        let release = DispatchSemaphore(value: 0)
        let finished = Mutex(false)
        let start = ContinuousClock.now
        await #expect(throws: Timeout.self) {
            try await withExportDeadline(start + .milliseconds(200), timeoutError: Timeout()) {
                // Ignores cancellation, like a render that has already started.
                await withCheckedContinuation { continuation in
                    Thread.detachNewThread { @Sendable in
                        release.wait()
                        finished.withLock { $0 = true }
                        continuation.resume(returning: 1)
                    }
                }
            }
        }
        #expect(ContinuousClock.now - start < .seconds(3))
        #expect(!finished.withLock { $0 })
        release.signal()
    }

    @Test func aDeadlineInThePastTimesOut() async {
        await #expect(throws: Timeout.self) {
            try await withExportDeadline(.now - .seconds(1), timeoutError: Timeout()) {
                try await Task.sleep(for: .seconds(30))
                return 1
            }
        }
    }

    @Test func cancellingTheCallerStopsWaiting() async {
        let task = Task {
            try await withExportDeadline(.now + .seconds(30), timeoutError: Timeout()) {
                try await Task.sleep(for: .seconds(30))
                return 1
            }
        }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @MainActor
    @Test func tooDeepDocumentsExportAsTheirSource() async throws {
        let exporter = DocumentExporter(baseDirectory: nil, allowRemoteImages: false)
        let markdown = String(repeating: ">", count: 50_000) + " deep\n"
        try await exporter.prepare(markdown: markdown, theme: .dawn)
        let text = try await exporter.webView.evaluateJavaScript(
            #"document.querySelector("pre.source-fallback")?.textContent ?? """#
        ) as? String
        #expect(text == markdown)
    }
}
#endif
