#if os(macOS)
import Foundation
import Testing
@testable import marsdawn

/// mars-dawn#514: `marsdawn open` started several times at once against an app that isn't running
/// must not lose files. The gate serialises the sends only while the app isn't running.
@MainActor
@Suite(.serialized)
struct ColdLaunchGateTests {
    /// Records what the gate did, in order.
    final class Log {
        var events: [String] = []
    }

    static let app = URL(fileURLWithPath: "/Applications/MarsDawn.app")

    func gate(running: Bool, lockFree: Bool, log: Log) -> ColdLaunchGate {
        ColdLaunchGate(
            isRunning: { _ in running },
            lock: { _ in
                log.events.append("lock")
                guard lockFree else { return nil }
                return { log.events.append("release") }
            }
        )
    }

    @Test func aRunningAppIsSentToWithoutTheLock() async {
        let log = Log()
        let value = await gate(running: true, lockFree: true, log: log).run(app: Self.app) {
            log.events.append("send")
            return 7
        }
        #expect(value == 7)
        #expect(log.events == ["send"], "nothing changes for a running app: \(log.events)")
    }

    @Test func anAppNotRunningIsSentToBehindTheLockAndReleasedAfter() async {
        let log = Log()
        await gate(running: false, lockFree: true, log: log).run(app: Self.app) { log.events.append("send") }
        #expect(log.events == ["lock", "send", "release"])
    }

    @Test func theLockIsReleasedWhenTheSendThrows() async {
        struct Failed: Error {}
        let log = Log()
        await #expect(throws: Failed.self) {
            try await gate(running: false, lockFree: true, log: log).run(app: Self.app) {
                log.events.append("send")
                throw Failed()
            }
        }
        #expect(log.events == ["lock", "send", "release"])
    }

    @Test func aLockNotHadInTimeStillSends() async {
        let log = Log()
        await gate(running: false, lockFree: false, log: log).run(app: Self.app) { log.events.append("send") }
        #expect(log.events == ["lock", "send"], "past the bound the send goes ahead as before")
    }

    // MARK: The file lock

    static func scratchLock() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("marsdawn-lock-test-\(UUID().uuidString)")
    }

    @Test func theFileLockIsExclusiveUntilReleased() async throws {
        let url = Self.scratchLock()
        defer { try? FileManager.default.removeItem(at: url) }
        let first = try #require(await FileLock.acquire(at: url, timeout: .seconds(1)))
        // A second open file description on the same file, as another process would have.
        let started = ContinuousClock.now
        let second = await FileLock.acquire(at: url, timeout: .milliseconds(200))
        #expect(second == nil, "the lock is held, so a second taker times out")
        #expect(ContinuousClock.now - started >= .milliseconds(200), "and waits its whole bound first")
        first()
        let third = try #require(await FileLock.acquire(at: url, timeout: .seconds(1)), "free again once released")
        third()
    }

    @Test func aWaiterGetsTheLockWhenTheHolderReleasesIt() async throws {
        let url = Self.scratchLock()
        defer { try? FileManager.default.removeItem(at: url) }
        let holder = try #require(await FileLock.acquire(at: url, timeout: .seconds(1)))
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            holder()
        }
        let started = ContinuousClock.now
        let waiter = try #require(await FileLock.acquire(at: url, timeout: .seconds(5)), "the waiter gets it after the release")
        #expect(ContinuousClock.now - started >= .milliseconds(100), "only after the holder let go")
        waiter()
    }

    @Test func theLiveLockLivesInTheUsersOwnTemporaryDirectory() {
        #expect(FileLock.defaultURL.deletingLastPathComponent().standardizedFileURL
                == FileManager.default.temporaryDirectory.standardizedFileURL)
    }
}
#endif
