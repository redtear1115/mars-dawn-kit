#if os(macOS)
import AppKit
import Foundation
import Testing
import notify
@testable import marsdawn

// PLAN #69 slice B: `open --folder` reports what happened to the folder it asked MarsDawn to
// show. These tests never touch `notifyd` or launch a real app: `FolderStatusOpener` and
// `FolderStatusNotifier` are seams (see `FolderStatusRequest.swift`), and every test here injects
// fakes for both.

// MARK: - A manual, injectable monotonic clock

/// A `Clock` whose `sleep(until:tolerance:)` jumps straight to the requested instant instead of
/// waiting, so deadline tests are instant and deterministic. `now` only moves when `sleep` is
/// called (or `advance` directly), so a test can assert what the waiter saw at each tick.
final class ManualClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
    }

    private(set) var current = Instant(offset: .zero)
    var minimumResolution: Duration { .zero }
    var now: Instant { current }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        current = deadline
    }
}

// MARK: - Fakes for the notifier and the opener

/// A fake Darwin-notification channel: `state` is whatever a test (or a fake poster, standing in
/// for another process) sets on it before or during the fake open. Never touches `notifyd`.
@MainActor
final class FakeNotifyChannel {
    var state: UInt64 = 0
    var registeredName: String?
    var registerStatus: UInt32 = 0 // NOTIFY_STATUS_OK
    var cancelled = false

    /// The token the CLI registered, read back out of the Darwin notification name
    /// (`dev.southern-light.marsdawn.folder.<token>`), the same way a verifier would.
    var registeredToken: String? {
        guard let name = registeredName, let range = name.range(of: "folder.") else { return nil }
        return String(name[range.upperBound...])
    }

    var notifier: FolderStatusNotifier {
        FolderStatusNotifier(
            registerCheck: { [weak self] name in
                self?.registeredName = name
                return (self?.registerStatus ?? 0, 1)
            },
            state: { [weak self] _ in self?.state ?? 0 },
            cancel: { [weak self] _ in self?.cancelled = true }
        )
    }
}

/// A fake opener that records what it was asked to send, and — like a fake poster standing in
/// for the app posting back while `NSWorkspace.open` is still running — can set state on a
/// `FakeNotifyChannel` before returning.
@MainActor
final class FakeOpener {
    var calls = 0
    var lastURLs: [URL] = []
    var lastApp: URL?
    var lastEventPresent = false
    /// Set by a test to simulate a poster: runs just before `open` returns.
    var onOpen: (() -> Void)?

    var opener: FolderStatusOpener {
        FolderStatusOpener(open: { [weak self] urls, app, configuration in
            self?.calls += 1
            self?.lastURLs = urls
            self?.lastApp = app
            self?.lastEventPresent = configuration.appleEvent != nil
            self?.onOpen?()
        })
    }
}

@MainActor
private func folder() -> URL {
    URL(fileURLWithPath: "/tmp/folder-status-\(UUID().uuidString)", isDirectory: true)
}

@MainActor
private func app() -> URL {
    URL(fileURLWithPath: "/tmp/MarsDawn-\(UUID().uuidString).app", isDirectory: true)
}

// MARK: - The code table

@MainActor
struct FolderStatusCodeTableTests {
    @Test func everyCodeInThePlansTableMapsToItsStatus() throws {
        let expected: [UInt64: (FolderStatus, FolderWaitingFor?)] = [
            1: (.attached, nil),
            2: (.needsUser, .confirmation),
            3: (.declined, nil),
            4: (.failed, nil),
            6: (.needsUser, .folderChoice),
            7: (.attachedDifferentFolder, nil),
            8: (.full, nil),
            9: (.unavailable, nil),
        ]
        for (code, expectation) in expected {
            let mapped = try #require(FolderStatusCode.status(for: code))
            #expect(mapped.status == expectation.0, "code \(code)")
            #expect(mapped.waitingFor == expectation.1, "code \(code)")
        }
        // Rev 1's code 5 ("capability off") is removed: it must not be in the table.
        #expect(FolderStatusCode.status(for: 5) == nil)
        #expect(FolderStatusCode.status(for: 0) == nil)
    }

    @Test func terminalAndNonTerminalPartitionTheTable() {
        #expect(FolderStatusCode.terminal == [1, 3, 4, 7, 8, 9])
        #expect(FolderStatusCode.nonTerminal == [2, 6])
        #expect(FolderStatusCode.terminal.isDisjoint(with: FolderStatusCode.nonTerminal))
    }
}

// MARK: - Waiting and the deadline

@MainActor
struct FolderStatusWaiterTests {
    @Test func aTerminalCodeEndsTheWaitAtOnce() async throws {
        let channel = FakeNotifyChannel()
        channel.state = 1
        let clock = ManualClock()
        let outcome = await FolderStatusWaiter.wait(notifier: channel.notifier, token: 1, seconds: 30, clock: clock)
        #expect(outcome.status == .attached)
        #expect(outcome.waitingFor == nil)
        // It returned on the very first read: the clock never had to advance to the deadline.
        #expect(clock.now.offset == .zero)
    }

    @Test func aNonTerminalCodeKeepsWaitingUntilTheDeadlineThenReportsNeedsUser() async throws {
        let channel = FakeNotifyChannel()
        channel.state = 2 // broad-folder confirmation sheet shown
        let clock = ManualClock()
        let outcome = await FolderStatusWaiter.wait(notifier: channel.notifier, token: 1, seconds: 10, clock: clock)
        #expect(outcome.status == .needsUser)
        #expect(outcome.waitingFor == .confirmation)
        #expect(clock.now.offset >= .seconds(10))
    }

    @Test func code6AtTheDeadlineReportsFolderChoice() async throws {
        let channel = FakeNotifyChannel()
        channel.state = 6 // NSOpenPanel fallback shown
        let clock = ManualClock()
        let outcome = await FolderStatusWaiter.wait(notifier: channel.notifier, token: 1, seconds: 5, clock: clock)
        #expect(outcome.status == .needsUser)
        #expect(outcome.waitingFor == .folderChoice)
    }

    @Test func state0AtTheDeadlineIsUnknown() async throws {
        let channel = FakeNotifyChannel()
        // state stays 0: nothing ever posted.
        let clock = ManualClock()
        let outcome = await FolderStatusWaiter.wait(notifier: channel.notifier, token: 1, seconds: 2, clock: clock)
        #expect(outcome.status == .unknown)
        #expect(outcome.waitingFor == nil)
    }

    /// A code arriving *after* a non-terminal one, but before the deadline, wins: the wait
    /// doesn't latch onto the first thing it saw, or wait out the full budget once a terminal
    /// code shows up. `state` here starts non-terminal (2) and only turns terminal (4) on its
    /// third read, simulating the sheet resolving partway through the wait.
    @Test func aTerminalCodeAfterANonTerminalOneStillWinsBeforeTheDeadline() async throws {
        var reads = 0
        let notifier = FolderStatusNotifier(
            registerCheck: { _ in (0, 1) },  // NOTIFY_STATUS_OK
            state: { _ in
                reads += 1
                return reads < 3 ? 2 : 4
            },
            cancel: { _ in }
        )
        let clock = ManualClock()
        let outcome = await FolderStatusWaiter.wait(notifier: notifier, token: 1, seconds: 10, clock: clock)
        #expect(outcome.status == .failed)
        #expect(reads == 3)
        // It resolved after two ticks, well short of the full 10 s deadline.
        #expect(clock.now.offset < .seconds(10))
    }
}

// MARK: - The capability gate and byte-identity (compatibility table)

@MainActor
struct FolderStatusRequestGateTests {
    /// Old app, or a new app the caller didn't ask to wait for: no token, no custom event —
    /// exactly today's `open --folder`. This is the acceptance-3 / red-control-B shape at the
    /// unit level.
    @Test func oldAppPathSendsNoTokenAndReportsNoStatus() async throws {
        let channel = FakeNotifyChannel()
        let opener = FakeOpener()
        let result = try await FolderStatusRequest.send(
            folder: folder(), app: app(), wait: 2, capable: false,
            configuration: NSWorkspace.OpenConfiguration(),
            opener: opener.opener, notifier: channel.notifier
        )
        #expect(result.status == nil)
        #expect(result.waitingFor == nil)
        #expect(opener.calls == 1)
        #expect(!opener.lastEventPresent)
        #expect(channel.registeredName == nil, "no token means no registration at all")
    }

    /// `--wait 0`: capable app, but the caller opted out of waiting. Same as the old-app path —
    /// byte-identical to before this slice, captured through the opener seam.
    @Test func waitZeroIsByteIdenticalToToday() async throws {
        let channel = FakeNotifyChannel()
        let opener = FakeOpener()
        let target = folder()
        let result = try await FolderStatusRequest.send(
            folder: target, app: app(), wait: 0, capable: true,
            configuration: NSWorkspace.OpenConfiguration(),
            opener: opener.opener, notifier: channel.notifier
        )
        #expect(result.status == nil)
        #expect(opener.calls == 1)
        #expect(opener.lastURLs == [target])
        #expect(!opener.lastEventPresent, "no configuration.appleEvent: byte-identical to today")
        #expect(channel.registeredName == nil)
    }

    /// P7: a fake poster that posts synchronously *during* the open (before `send` ever polls)
    /// still gives `attached` — the waiter decides by the state's value, not by whether it
    /// changed since a particular look.
    @Test func aPosterDuringTheOpenStillGivesAttached() async throws {
        let channel = FakeNotifyChannel()
        let opener = FakeOpener()
        opener.onOpen = { channel.state = 1 }
        let result = try await FolderStatusRequest.send(
            folder: folder(), app: app(), wait: 5, capable: true,
            configuration: NSWorkspace.OpenConfiguration(),
            opener: opener.opener, notifier: channel.notifier
        )
        #expect(result.status == .attached)
        #expect(channel.cancelled, "notify_cancel runs on every exit")
    }

    /// Registration itself is before the open (plan [P7]).
    @Test func registrationHappensBeforeTheOpen() async throws {
        let channel = FakeNotifyChannel()
        let opener = FakeOpener()
        var registeredBeforeOpen = false
        opener.onOpen = { registeredBeforeOpen = channel.registeredName != nil }
        channel.state = 1 // resolve immediately once polled, so the test doesn't wait
        _ = try await FolderStatusRequest.send(
            folder: folder(), app: app(), wait: 5, capable: true,
            configuration: NSWorkspace.OpenConfiguration(),
            opener: opener.opener, notifier: channel.notifier
        )
        #expect(registeredBeforeOpen)
    }

    /// The capable + wait > 0 path sends the canonicalized folder with the custom event present.
    @Test func capableAndWaitingSendsTheCustomEvent() async throws {
        let channel = FakeNotifyChannel()
        let opener = FakeOpener()
        channel.state = 1
        let target = try makeRealFolder()
        defer { try? FileManager.default.removeItem(at: target) }
        _ = try await FolderStatusRequest.send(
            folder: target, app: app(), wait: 5, capable: true,
            configuration: NSWorkspace.OpenConfiguration(),
            opener: opener.opener, notifier: channel.notifier
        )
        #expect(opener.lastEventPresent)
        #expect(channel.registeredToken?.count == 32)
    }

    private func makeRealFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("folder-status-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

// MARK: - `--wait` validation (exit 2)

@MainActor
struct WaitOptionTests {
    private func exitCode(_ body: () async throws -> Void) async -> Int32? {
        do {
            try await body()
            return nil
        } catch {
            return cliExitCode(for: error)
        }
    }

    @Test func defaultsToTwoAndAcceptsTheFullRange() throws {
        let a = try MarsDawnCommand.Open.parse(["/tmp/whatever.md"])
        #expect(a.wait == 2)
        for value in [0, 1, 30] {
            _ = try MarsDawnCommand.Open.parse(["--wait", "\(value)", "/tmp/whatever.md"])
        }
    }

    /// `run()` throws `WaitRangeFailure` directly, as the very first thing it does — before
    /// resolving targets, folders or the app — so nothing is sent for an out-of-range `--wait`.
    /// (Not `validate()`: ArgumentParser wraps whatever that throws in its own internal
    /// `CommandError`, which loses `WaitRangeFailure`'s own exit code behind its generic
    /// fallback. See the comment on the `--wait` check in `Commands.swift`.)
    @Test func outOfRangeIsExitCodeTwo() async throws {
        for value in [31, 100] {
            let code = await exitCode { _ = try await MarsDawnCommand.Open.parse(["--wait", "\(value)", "/tmp/x.md"]).run() }
            #expect(code == WaitRangeFailure.exitCode, "value \(value)")
        }
        #expect(WaitRangeFailure.exitCode == 2)
    }

    /// A negative `--wait` is also out of range, but ArgumentParser itself refuses `-1` as an
    /// option value (it reads as another flag, not a value) before `run()` is ever reached —
    /// still a usage error, just ArgumentParser's own 64 rather than `WaitRangeFailure`'s 2.
    /// Documented here so the gap isn't mistaken for untested.
    @Test func aNegativeWaitIsRefusedByArgumentParserItself() throws {
        #expect(throws: (any Error).self) { try MarsDawnCommand.Open.parse(["--wait", "-1", "/tmp/x.md"]) }
    }

    @Test func theMessageNamesTheRange() {
        let failure = WaitRangeFailure(value: 42)
        #expect(failure.message.contains("0"))
        #expect(failure.message.contains("30"))
        #expect(failure.message.contains("42"))
    }
}

// MARK: - Token hygiene: the token never reaches JSON or text output

@MainActor
struct TokenHygieneTests {
    /// Plan L1 / acceptance 5: the token is never in the `--json` fields or the text line, the
    /// exact code `Open.run()` uses to build both.
    @Test func theTokenNeverAppearsInTheFieldsOrTheLine() async throws {
        let channel = FakeNotifyChannel()
        let opener = FakeOpener()
        channel.state = 2 // needsUser, so the token stays live a little longer before resolving
        let clock = ManualClock()
        let target = folder()
        let result = try await FolderStatusRequest.send(
            folder: target, app: app(), wait: 3, capable: true,
            configuration: NSWorkspace.OpenConfiguration(),
            opener: opener.opener, notifier: channel.notifier, clock: clock
        )
        let token = try #require(channel.registeredToken)
        #expect(token.count == 32)

        let fields = MarsDawnCommand.Open.folderFields(path: target.path, result: result)
        let line = MarsDawnCommand.Open.folderLine(path: target.path, result: result)
        let jsonData = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        let json = String(decoding: jsonData, as: UTF8.self)

        #expect(!json.contains(token))
        #expect(!line.contains(token))
        // And the plan's own vocabulary is what's there instead.
        #expect(json.contains("needsUser"))
        #expect(line.contains("needsUser"))
    }

    @Test func theTokenIsThirtyTwoLowercaseHexCharacters() {
        for _ in 0..<20 {
            let token = FolderStatusToken.generate()
            #expect(token.count == 32)
            #expect(token.allSatisfy { "0123456789abcdef".contains($0) })
        }
    }
}

// MARK: - Red controls

@MainActor
struct FolderStatusRedControlTests {
    /// Red control (B): a notifier whose state never reflects the token (as if the app never
    /// read or honoured it) gives `unknown`, the same as an app that never posted at all.
    @Test func ignoringTheTokenGivesUnknown() async throws {
        let channel = FakeNotifyChannel() // state stays 0 forever: nothing "honours" the token
        let opener = FakeOpener()
        let clock = ManualClock()
        let result = try await FolderStatusRequest.send(
            folder: folder(), app: app(), wait: 3, capable: true,
            configuration: NSWorkspace.OpenConfiguration(),
            opener: opener.opener, notifier: channel.notifier, clock: clock
        )
        #expect(result.status == .unknown)
    }

    /// A planted control of my own: a `registerCheck` that fails falls back to the plain path
    /// (no token, no wait) rather than hanging or crashing — the same shape as an old app or
    /// `--wait 0`, proven by the *same* assertions.
    @Test func aFailedRegistrationFallsBackToThePlainPath() async throws {
        let channel = FakeNotifyChannel()
        channel.registerStatus = 99 // anything other than NOTIFY_STATUS_OK
        let opener = FakeOpener()
        let result = try await FolderStatusRequest.send(
            folder: folder(), app: app(), wait: 5, capable: true,
            configuration: NSWorkspace.OpenConfiguration(),
            opener: opener.opener, notifier: channel.notifier
        )
        #expect(result.status == nil)
        #expect(!opener.lastEventPresent)
        #expect(!channel.cancelled, "cancel is only for a token that was actually registered")
    }
}
#endif
