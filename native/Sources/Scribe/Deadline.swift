import Foundation

/// Thrown by `withDeadline` when the operation did not finish in time.
struct DeadlineExceeded: Error {}

/// Resolves with the operation's result or throws `DeadlineExceeded` after `seconds` — even when the
/// operation cannot be cancelled (CoreML and MLX model loads ignore cancellation, which is why a task-group
/// race never bounded a cold load: the group waits for its children). When the deadline fires or the caller
/// is cancelled, the operation's task is cancelled too: harmless for uncancellable work, and what frees the
/// model for a cooperative backend (Gemma's token loop holds the MLX model mutex until it observes
/// cancellation). An uncancellable late operation keeps running in its own task; a later caller gets its
/// result through `LazyModel`. The continuation resumes at most once.
func withDeadline<T: Sendable>(
    _ seconds: Double,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let gate = ResumeOnce<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            gate.attach(continuation)
            // onCancel may already have fired before attach; honour a pre-cancelled caller.
            if Task.isCancelled {
                gate.resume(.failure(CancellationError()))
                return
            }
            let work = Task {
                do {
                    gate.resume(.success(try await operation()))
                } catch {
                    gate.resume(.failure(error))
                }
            }
            gate.track(work)
            Task {
                try? await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
                // Resume before cancelling, or the operation's CancellationError could win the gate.
                gate.resume(.failure(DeadlineExceeded()))
                gate.cancelOperation()
            }
        }
    } onCancel: {
        gate.resume(.failure(CancellationError()))
        gate.cancelOperation()
    }
}

/// Resumes a continuation at most once, from whichever racing task finishes first, and cancels the
/// operation's task once the race is decided against it.
final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var work: Task<Void, Never>?
    private var cancelRequested = false

    func attach(_ continuation: CheckedContinuation<T, Error>) {
        lock.withLock { self.continuation = continuation }
    }

    /// Stores the operation's task. onCancel can run between attach and here, so a cancel that already
    /// arrived is applied at once.
    func track(_ task: Task<Void, Never>) {
        let cancelNow: Bool = lock.withLock {
            work = task
            return cancelRequested
        }
        if cancelNow {
            task.cancel()
        }
    }

    func cancelOperation() {
        let task: Task<Void, Never>? = lock.withLock {
            cancelRequested = true
            return work
        }
        task?.cancel()
    }

    func resume(_ result: Result<T, Error>) {
        let pending: CheckedContinuation<T, Error>? = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(with: result)
    }
}
