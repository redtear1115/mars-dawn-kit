#if os(macOS)
import AppKit
import Foundation

/// mars-dawn#514: `marsdawn open` run several times at the same instant while MarsDawn isn't
/// running opened one file and reported `ok` for all of them. Each process asked LaunchServices
/// to launch the app with its own files; requests that arrive together, before the app is
/// registered as launching, are merged into one launch and only one request's open-documents
/// event reaches the app. `NSWorkspace.open` still returns the running app to every caller, so
/// nothing told the others their files were dropped. The app's own handler opens every file of
/// every event it gets (mars-dawn's `RevealCoordinator`); the events just never arrive.
///
/// The gate serialises the sends of `marsdawn` processes while the app is not running: the first
/// one launches it with its files, and the next one sends only after that `open` has returned,
/// when the app is launching or running and its event queues like any later one. With the app
/// already running nothing changes: no lock, the same sends as before. The lock is a `flock` on a
/// file in the user's own temporary directory, released by the kernel if a holder dies; waiting
/// for it is bounded, and past the bound the send goes ahead as it always did.
struct ColdLaunchGate {
    /// Whether the app at this URL is running (launching counts).
    var isRunning: @MainActor (URL) -> Bool
    /// Takes the cross-process lock, waiting at most `timeout`; returns how to release it, or nil
    /// if it couldn't be had in time.
    var lock: @MainActor (_ timeout: Duration) async -> (@MainActor () -> Void)?

    /// How long a process waits for the one before it to finish launching the app.
    static let lockTimeout: Duration = .seconds(30)

    /// Runs `send` behind the lock when the app at `app` isn't running, and straight away when it
    /// is. Returns whatever `send` returns, and rethrows what it throws (after releasing).
    @MainActor
    func run<T>(app: URL, _ send: @MainActor () async throws -> T) async rethrows -> T {
        guard !isRunning(app) else { return try await send() }
        let release = await lock(Self.lockTimeout)
        defer { release?() }
        return try await send()
    }

    @MainActor static let live = ColdLaunchGate(
        isRunning: { app in
            let target = app.resolvingSymlinksInPath().standardizedFileURL
            return NSWorkspace.shared.runningApplications.contains { running in
                running.bundleURL?.resolvingSymlinksInPath().standardizedFileURL == target
            }
        },
        lock: { timeout in await FileLock.acquire(at: FileLock.defaultURL, timeout: timeout) }
    )
}

/// An exclusive `flock` on a file, polled without blocking so the wait can be bounded.
enum FileLock {
    /// One per user: `$TMPDIR` is the user's own (`/var/folders/…/T/`).
    static var defaultURL: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("dev.southern-light.marsdawn.open.lock")
    }

    static let pollInterval: Duration = .milliseconds(20)

    /// The release closure once the lock is held, or nil if the file can't be opened or the lock
    /// isn't free within `timeout`.
    @MainActor
    static func acquire(at url: URL, timeout: Duration, clock: ContinuousClock = ContinuousClock()) async -> (@MainActor () -> Void)? {
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return nil }
        let deadline = clock.now + timeout
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR, clock.now < deadline else {
                close(fd)
                return nil
            }
            try? await Task.sleep(for: pollInterval)
        }
        return {
            flock(fd, LOCK_UN)
            close(fd)
        }
    }
}

/// What `Open.run()` calls through, so tests never launch a real app; production leaves it `.live`.
enum ColdLaunchEnvironment {
    @MainActor static var gate: ColdLaunchGate = .live
}
#endif
