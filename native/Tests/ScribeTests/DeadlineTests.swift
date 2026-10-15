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
}
