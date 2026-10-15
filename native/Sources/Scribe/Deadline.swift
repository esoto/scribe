import Foundation

/// Thrown by `withDeadline` when the operation did not finish in time.
struct DeadlineExceeded: Error {}

/// Resolves with the operation's result or throws `DeadlineExceeded` after `seconds` — even when the
/// operation cannot be cancelled (CoreML and MLX model loads ignore cancellation, which is why a task-group
/// race never bounded a cold load: the group waits for its children). The operation keeps running
/// detached; a later caller gets its result through `LazyModel`. The continuation resumes at most once.
func withDeadline<T>(
    _ seconds: Double,
    _ operation: @escaping () async throws -> T
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
            Task {
                do {
                    gate.resume(.success(try await operation()))
                } catch {
                    gate.resume(.failure(error))
                }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
                gate.resume(.failure(DeadlineExceeded()))
            }
        }
    } onCancel: {
        gate.resume(.failure(CancellationError()))
    }
}

/// Resumes a continuation at most once, from whichever racing task finishes first.
final class ResumeOnce<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    func attach(_ continuation: CheckedContinuation<T, Error>) {
        lock.withLock { self.continuation = continuation }
    }

    func resume(_ result: Result<T, Error>) {
        let pending: CheckedContinuation<T, Error>? = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(with: result)
    }
}
