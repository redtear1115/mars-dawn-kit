#if os(macOS)
import Foundation
import Synchronization

/// Runs `operation`, but stops waiting for it at `deadline` and throws `timeoutError`.
///
/// An operation that can't be stopped keeps running after the deadline; it is cancelled and
/// its result is discarded. Cancelling the calling task stops waiting too.
func withExportDeadline<T: Sendable>(
    _ deadline: ContinuousClock.Instant,
    timeoutError: any Error & Sendable,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let race = DeadlineRace<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            race.begin(continuation)
            race.track(Task {
                do {
                    race.finish(.success(try await operation()))
                } catch {
                    race.finish(.failure(error))
                }
            })
            race.track(Task {
                try? await Task.sleep(until: deadline, clock: .continuous)
                race.finish(.failure(timeoutError))
            })
        }
    } onCancel: {
        race.finish(.failure(CancellationError()))
    }
}

/// The first `finish` resumes the waiter; later ones are ignored. Finishing cancels both tasks.
private final class DeadlineRace<T: Sendable>: Sendable {
    private struct State {
        var continuation: CheckedContinuation<T, any Error>?
        var pending: Result<T, any Error>?
        var finished = false
        var tasks: [Task<Void, Never>] = []
    }

    private let state = Mutex(State())

    func begin(_ continuation: CheckedContinuation<T, any Error>) {
        let early = state.withLock { state -> Result<T, any Error>? in
            if let pending = state.pending {
                state.pending = nil
                return pending
            }
            state.continuation = continuation
            return nil
        }
        if let early {
            continuation.resume(with: early)
        }
    }

    func track(_ task: Task<Void, Never>) {
        let finished = state.withLock { state in
            if !state.finished { state.tasks.append(task) }
            return state.finished
        }
        if finished { task.cancel() }
    }

    func finish(_ result: Result<T, any Error>) {
        let (continuation, tasks) = state.withLock { state -> (CheckedContinuation<T, any Error>?, [Task<Void, Never>]) in
            guard !state.finished else { return (nil, []) }
            state.finished = true
            let tasks = state.tasks
            state.tasks = []
            guard let continuation = state.continuation else {
                // Cancelled before the waiter was set up.
                state.pending = result
                return (nil, tasks)
            }
            state.continuation = nil
            return (continuation, tasks)
        }
        continuation?.resume(with: result)
        tasks.forEach { $0.cancel() }
    }
}
#endif
