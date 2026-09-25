#if os(macOS)
import AppKit
import Foundation
import Security
import notify

// PLAN #69 slice B: `open --folder` learns what happened to the folder it asked MarsDawn to
// show, instead of only reporting that it asked (`"requested": true`). See
// `docs/../../MarsDawn 協作/計畫/PLAN-69-cli-folder-reply.md` (rev 3.1) for the full design; this
// file is the CLI half. The app half (token parsing, the in-flight map, the posts) is slice A,
// in the private app repo.

// MARK: - Canonical folder path

/// The on-disk spelling of a folder: `realpath`, then `F_GETPATH` on an `O_RDONLY|O_DIRECTORY`
/// descriptor, which gives the volume's own stored case and normalization (plan Design, "Both
/// sides canonicalise"). Used only for the token-carrying custom event; the plain, no-token path
/// keeps sending exactly what it always has, so `--wait 0` and an old app stay byte-identical.
enum CanonicalFolderPath {
    static func canonicalize(_ url: URL) -> URL {
        guard let resolved = realpath(url.path, nil) else { return url }
        defer { free(resolved) }
        let realPath = String(cString: resolved)
        let descriptor = open(realPath, O_RDONLY | O_DIRECTORY)
        guard descriptor >= 0 else { return URL(fileURLWithPath: realPath, isDirectory: true) }
        defer { close(descriptor) }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(descriptor, F_GETPATH, &buffer) == 0 else {
            return URL(fileURLWithPath: realPath, isDirectory: true)
        }
        let length = buffer.firstIndex(of: 0) ?? buffer.count
        let bytes = buffer[..<length].map { UInt8(bitPattern: $0) }
        return URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self), isDirectory: true)
    }
}

// MARK: - Token

/// Plan L1: 16 bytes from `SecRandomCopyBytes`, written as lowercase hex. Never printed or
/// logged; kept out of argv and the environment; carried only in the custom Apple Event.
enum FolderStatusToken {
    static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed (\(status))")
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - The custom event

/// The `aevt`/`odoc` event that carries the one folder and the token, the same shape as
/// `RevealEvent`'s file events: a direct-object list plus our own keyword.
enum FolderStatusEvent {
    /// `'mdRq'`, typeUTF8Text, exactly the 32 hex characters of the token.
    static let tokenKeyword = AEKeyword(fourCharCode: "mdRq")

    static func openFolder(url: URL, token: String) -> NSAppleEventDescriptor? {
        let event = NSAppleEventDescriptor.appleEvent(
            withEventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEOpenDocuments),
            targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        let list = NSAppleEventDescriptor.list()
        list.insert(NSAppleEventDescriptor(fileURL: url), at: 1)
        event.setParam(list, forKeyword: AEKeyword(keyDirectObject))
        let tokenData = Data(token.utf8)
        guard let tokenDescriptor = tokenData.withUnsafeBytes({ buffer in
            NSAppleEventDescriptor(descriptorType: DescType(typeUTF8Text), bytes: buffer.baseAddress, length: buffer.count)
        }) else { return nil }
        event.setParam(tokenDescriptor, forKeyword: tokenKeyword)
        return event
    }
}

// MARK: - Outcome vocabulary

/// The CLI's JSON `status`. `attached`, `declined`, `failed`, `attachedDifferentFolder`, `full`
/// and `unavailable` are terminal app outcomes; `needsUser` is what a non-terminal code (2 or 6)
/// becomes once the deadline passes with nothing terminal after it; `unknown` is state 0 at the
/// deadline, or anything the CLI never sent a token for.
enum FolderStatus: String {
    case attached
    case needsUser
    case declined
    case failed
    case attachedDifferentFolder
    case full
    case unavailable
    case unknown
}

/// JSON `waitingFor`, present only alongside `needsUser`.
enum FolderWaitingFor: String {
    case confirmation
    case folderChoice
}

/// The plan's code table (Design, "Outcome codes"). Codes 1, 3, 4, 7, 8 and 9 are terminal:
/// posted once and end the wait at once. Codes 2 and 6 are seen but kept waiting; only if the
/// deadline arrives with no terminal code after them do they resolve to `needsUser`.
enum FolderStatusCode {
    static let terminal: Set<UInt64> = [1, 3, 4, 7, 8, 9]
    static let nonTerminal: Set<UInt64> = [2, 6]

    static func status(for code: UInt64) -> (status: FolderStatus, waitingFor: FolderWaitingFor?)? {
        switch code {
        case 1: return (.attached, nil)
        case 2: return (.needsUser, .confirmation)
        case 3: return (.declined, nil)
        case 4: return (.failed, nil)
        case 6: return (.needsUser, .folderChoice)
        case 7: return (.attachedDifferentFolder, nil)
        case 8: return (.full, nil)
        case 9: return (.unavailable, nil)
        default: return nil
        }
    }
}

// MARK: - Darwin notifications (a seam, so tests never touch notifyd)

/// The three Darwin-notification calls this needs, as closures, so tests can feed the waiter
/// values without a real `notifyd` round trip (and without ever posting a real event to a real
/// app). `.live` is what production uses.
struct FolderStatusNotifier {
    var registerCheck: @MainActor (String) -> (status: UInt32, token: Int32)
    var state: @MainActor (Int32) -> UInt64
    var cancel: @MainActor (Int32) -> Void

    @MainActor static let live = FolderStatusNotifier(
        registerCheck: { name in
            var token: Int32 = 0
            let status = notify_register_check(name, &token)
            return (status, token)
        },
        state: { token in
            var state: UInt64 = 0
            _ = notify_get_state(token, &state)
            return state
        },
        cancel: { token in notify_cancel(token) }
    )
}

/// How the folder actually gets sent, so tests never launch a real app through `NSWorkspace`.
struct FolderStatusOpener {
    var open: @MainActor (_ urls: [URL], _ app: URL, _ configuration: NSWorkspace.OpenConfiguration) async throws -> Void

    @MainActor static let live = FolderStatusOpener(open: { urls, app, configuration in
        _ = try await NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: configuration)
    })
}

// MARK: - Waiting

/// Plan L4: polls `notifier`'s state for `token` until a terminal code arrives or `seconds`
/// elapses on `clock`, a monotonic clock (the caller starts it only after `NSWorkspace.open`
/// returns, so a cold launch isn't counted against the wait). Because posts can coalesce, every
/// wake decides from the *value* currently in the state, not from whether it changed since the
/// last look — so a poster that already set the terminal state before the first poll (P7: a fake
/// poster posting synchronously during the open) is caught on the very first read.
enum FolderStatusWaiter {
    struct Outcome {
        var status: FolderStatus
        var waitingFor: FolderWaitingFor?
    }

    @MainActor
    static func wait<C: Clock>(
        notifier: FolderStatusNotifier,
        token: Int32,
        seconds: Int,
        clock: C,
        tick: Duration = .milliseconds(50)
    ) async -> Outcome where C.Duration == Duration {
        let deadline = clock.now.advanced(by: .seconds(seconds))
        while true {
            let state = notifier.state(token)
            if FolderStatusCode.terminal.contains(state), let (status, waitingFor) = FolderStatusCode.status(for: state) {
                return Outcome(status: status, waitingFor: waitingFor)
            }
            if clock.now >= deadline {
                if FolderStatusCode.nonTerminal.contains(state), let (status, waitingFor) = FolderStatusCode.status(for: state) {
                    return Outcome(status: status, waitingFor: waitingFor)
                }
                // State 0 (or anything not in the table) at the deadline: unknown.
                return Outcome(status: .unknown, waitingFor: nil)
            }
            let nextWake = min(clock.now.advanced(by: tick), deadline)
            try? await clock.sleep(until: nextWake, tolerance: nil)
        }
    }
}

/// What `Open.run()` actually calls through, so tests can replace both without touching
/// `NSWorkspace` or `notifyd` — the same pattern as `MarsDawnApp.locate`. Production leaves both
/// at `.live`.
enum FolderStatusEnvironment {
    @MainActor static var opener: FolderStatusOpener = .live
    @MainActor static var notifier: FolderStatusNotifier = .live
}

// MARK: - Orchestration

/// The whole slice-B request: send the folder, and, when the app and the caller both opt in,
/// wait for its outcome.
enum FolderStatusRequest {
    struct Result {
        /// nil when no token was sent (capability off, or `--wait 0`): the plain, `requested`-
        /// only path, byte-identical to before this slice.
        var status: FolderStatus?
        var waitingFor: FolderWaitingFor?
    }

    /// Sends `folder` to `app` with `configuration`. When `capable` (the app declares
    /// `MarsDawnReportsFolderStatus`) and `wait > 0`, a one-time token rides a custom event
    /// (plan H1a) and this waits up to `wait` seconds for the app's outcome. Otherwise it sends
    /// exactly what `open --folder` always has: no custom `appleEvent`, so a capture of the sent
    /// event is byte-identical to today's.
    @MainActor
    static func send<C: Clock>(
        folder: URL,
        app: URL,
        wait: Int,
        capable: Bool,
        configuration: NSWorkspace.OpenConfiguration,
        opener: FolderStatusOpener = .live,
        notifier: FolderStatusNotifier = .live,
        clock: C
    ) async throws -> Result where C.Duration == Duration {
        guard capable, wait > 0 else {
            try await opener.open([folder], app, configuration)
            return Result(status: nil, waitingFor: nil)
        }

        let token = FolderStatusToken.generate()
        let name = "dev.southern-light.marsdawn.folder.\(token)"
        // Plan [P7]: register before NSWorkspace.open, so no post between registration and the
        // open can be missed.
        let (registerStatus, notifyToken) = notifier.registerCheck(name)
        guard registerStatus == NOTIFY_STATUS_OK else {
            // A channel that can't be registered can never report back; fall back to the plain
            // event rather than waiting on nothing.
            try await opener.open([folder], app, configuration)
            return Result(status: nil, waitingFor: nil)
        }
        defer { notifier.cancel(notifyToken) }

        let canonical = CanonicalFolderPath.canonicalize(folder)
        guard let event = FolderStatusEvent.openFolder(url: canonical, token: token) else {
            try await opener.open([folder], app, configuration)
            return Result(status: nil, waitingFor: nil)
        }
        configuration.appleEvent = event
        try await opener.open([folder], app, configuration)

        // The deadline starts only now: a cold launch isn't counted against the wait.
        let outcome = await FolderStatusWaiter.wait(notifier: notifier, token: notifyToken, seconds: wait, clock: clock)
        return Result(status: outcome.status, waitingFor: outcome.waitingFor)
    }

    /// The production entry point: a real, monotonic `ContinuousClock`. Tests call the generic
    /// `send(...)` above directly with a `ManualClock` instead.
    @MainActor
    static func send(
        folder: URL,
        app: URL,
        wait: Int,
        capable: Bool,
        configuration: NSWorkspace.OpenConfiguration,
        opener: FolderStatusOpener = .live,
        notifier: FolderStatusNotifier = .live
    ) async throws -> Result {
        try await send(
            folder: folder, app: app, wait: wait, capable: capable, configuration: configuration,
            opener: opener, notifier: notifier, clock: ContinuousClock()
        )
    }
}
#endif
