import XCTest

final class DeadlineTests: XCTestCase {
    /// Never resumes and never checks for cancellation — like a cold CoreML load.
    private func hangForever() async -> Int {
        await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
        return 0
    }

    func test_returns_the_operations_result_when_it_finishes_in_time() async throws {
        let value = try await withDeadline(1.0) { 7 }
        XCTAssertEqual(value, 7)
    }

    func test_throws_deadline_exceeded_when_the_operation_never_finishes() async {
        let started = Date()
        do {
            _ = try await withDeadline(0.05) { await self.hangForever() }
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

    func test_cancelling_the_caller_throws_cancellation_error_promptly() async {
        let started = Date()
        let task = Task { () async throws -> Int in
            try await withDeadline(5.0) { await self.hangForever() }
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
}
