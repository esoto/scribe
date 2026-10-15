import XCTest

final class DeadlineTests: XCTestCase {
    /// Never resumes and never checks for cancellation — like a cold CoreML load.
    private static func hangForever() async -> Int {
        await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in }
        return 0
    }

    func test_returns_the_operations_result_when_it_finishes_in_time() async throws {
        let value = try await withDeadline(1.0) { 7 }
        XCTAssertEqual(value, 7)
    }

    func test_throws_deadline_exceeded_when_the_operation_never_finishes() async {
        let started = Date()
        do {
            _ = try await withDeadline(0.05) { await Self.hangForever() }
            XCTFail("expected DeadlineExceeded")
        } catch is DeadlineExceeded {
            XCTAssertLessThan(Date().timeIntervalSince(started), 1.0)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func test_propagates_the_operations_error() async {
        struct Boom: Error {}
        do {
            _ = try await withDeadline(1.0) { () async throws -> Int in throw Boom() }
            XCTFail("expected Boom")
        } catch is Boom {
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func test_a_caller_cancelled_before_entry_throws_cancellation_error_promptly() async {
        let started = Date()
        let task = Task { () async throws -> Int in
            // Spin until cancelled so withDeadline is always entered pre-cancelled, never racing cancel().
            while !Task.isCancelled { await Task.yield() }
            return try await withDeadline(5.0) { await Self.hangForever() }
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected CancellationError")
        } catch is CancellationError {
            XCTAssertLessThan(Date().timeIntervalSince(started), 1.0)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func test_a_caller_cancelled_mid_wait_throws_cancellation_error_promptly() async {
        let (started, signal) = AsyncStream<Void>.makeStream()
        let task = Task { () async throws -> Int in
            try await withDeadline(5.0) {
                signal.yield()   // the operation is running and withDeadline is now waiting on it
                return await Self.hangForever()
            }
        }
        for await _ in started { break }
        let cancelledAt = Date()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected CancellationError")
        } catch is CancellationError {
            XCTAssertLessThan(Date().timeIntervalSince(cancelledAt), 1.0)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func test_a_result_arriving_after_the_deadline_is_dropped_without_resuming_twice() async {
        let (finished, signal) = AsyncStream<Void>.makeStream()
        do {
            _ = try await withDeadline(0.05) { () async throws -> Int in
                try? await Task.sleep(nanoseconds: 200_000_000)
                signal.yield()
                return 7
            }
            XCTFail("expected DeadlineExceeded")
        } catch is DeadlineExceeded {
        } catch {
            XCTFail("unexpected error \(error)")
        }
        // Let the late operation finish: a second resume would trap right here.
        for await _ in finished { break }
        try? await Task.sleep(nanoseconds: 100_000_000)
    }

    /// Waits up to a second for the stream's first element; false on timeout, so a regression fails instead of hanging.
    private func arrived(_ stream: AsyncStream<Void>) async -> Bool {
        let probe = Task { () -> Bool in
            for await _ in stream { return true }
            return false
        }
        let timer = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            probe.cancel()
        }
        let result = await probe.value
        timer.cancel()
        return result
    }

    func test_deadline_cancels_a_cooperative_operation() async {
        let (cancelled, signal) = AsyncStream<Void>.makeStream()
        do {
            _ = try await withDeadline(0.05) { () async throws -> Int in
                do {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                } catch is CancellationError {
                    signal.yield()
                    throw CancellationError()
                }
                return 0
            }
            XCTFail("expected DeadlineExceeded")
        } catch is DeadlineExceeded {
        } catch {
            XCTFail("unexpected error \(error)")
        }
        let observed = await arrived(cancelled)
        XCTAssertTrue(observed, "the operation never observed cancellation after the deadline")
    }

    func test_caller_cancellation_cancels_a_cooperative_operation() async {
        let (cancelled, signal) = AsyncStream<Void>.makeStream()
        let (started, startedSignal) = AsyncStream<Void>.makeStream()
        let task = Task { () async throws -> Int in
            try await withDeadline(5.0) { () async throws -> Int in
                startedSignal.yield()
                do {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                } catch is CancellationError {
                    signal.yield()
                    throw CancellationError()
                }
                return 0
            }
        }
        for await _ in started { break }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected CancellationError")
        } catch is CancellationError {
        } catch {
            XCTFail("unexpected error \(error)")
        }
        let observed = await arrived(cancelled)
        XCTAssertTrue(observed, "the operation never observed the caller's cancellation")
    }

    func test_a_cancel_that_arrives_before_the_operation_is_tracked_cancels_it_on_track() async {
        let gate = ResumeOnce<Int>()
        gate.cancelOperation()
        let (cancelled, signal) = AsyncStream<Void>.makeStream()
        let work = Task {
            do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { signal.yield() }
        }
        gate.track(work)
        let observed = await arrived(cancelled)
        XCTAssertTrue(observed, "track ignored a cancel that arrived before it")
    }
}
