import XCTest
@testable import Scribe

/// Ported from tests/test_recorder.py — RingBuffer cases 1:1, plus the
/// armed-capture cases run against `Recorder`'s pure `ingest`/`arm`/`disarm`
/// core using a `FakeEngineControl` in place of real AVAudioEngine hardware.
final class RingBufferTests: XCTestCase {
    // MARK: - Helpers

    /// Mirrors tests/test_recorder.py's `chunk(v, n=160)`.
    private func chunk(_ v: Float, _ n: Int = 160) -> [Float] {
        [Float](repeating: v, count: n)
    }

    /// No-op stand-in for `AVEngineControl` — never touches real hardware,
    /// so `Recorder.arm()`/`disarm()` are exercisable in unit tests. Mirrors
    /// the Python reference's `FakeStream`/`stream_factory` injection.
    private final class FakeEngineControl: EngineControl {
        var onSamples: (([Float]) -> Void)?
        private(set) var startCalls = 0
        var running = false
        var failStart = false

        var isRunning: Bool { running }

        func start() throws {
            startCalls += 1
            if failStart {
                throw RecorderError(message: "no device")
            }
            running = true
        }
    }

    // MARK: - RingBuffer

    func testRingBufferDrainConcatenates() {
        let rb = RingBuffer(maxSeconds: 1, sampleRate: 160)
        rb.append([Float](repeating: 1.0, count: 80))
        rb.append([Float](repeating: 0.0, count: 80))
        let out = rb.drain()
        XCTAssertEqual(out.count, 160)
        XCTAssertEqual(out.first, 1.0)
        XCTAssertEqual(out.last, 0.0)
        XCTAssertEqual(rb.drain().count, 0)
    }

    func testRingBufferCapsCapacity() {
        let rb = RingBuffer(maxSeconds: 1, sampleRate: 160)
        for _ in 0..<5 {
            rb.append([Float](repeating: 1.0, count: 80))
        }
        XCTAssertLessThanOrEqual(rb.drain().count, 160)
    }

    // MARK: - Armed capture core (Recorder.ingest/arm/disarm)

    func testRecorderCapturesOnlyWhileArmed() throws {
        let engineControl = FakeEngineControl()
        let r = Recorder(engineControl: engineControl)

        r.ingest(chunk(0.5))
        try r.arm()
        r.ingest(chunk(1.0))
        let pcm = r.disarm()
        r.ingest(chunk(0.7))

        XCTAssertFalse(pcm.isEmpty)
        XCTAssertTrue(pcm.allSatisfy { $0 == 1.0 })
    }

    func testArmClearsAnyPriorUndrainedCapture() throws {
        let engineControl = FakeEngineControl()
        let r = Recorder(engineControl: engineControl)

        try r.arm()
        r.ingest(chunk(0.3))
        // Re-arming without an intervening disarm() must discard whatever
        // had accumulated so far, same as the Python reference's
        // `buffer.clear()` at the top of `arm()`.
        try r.arm()
        r.ingest(chunk(1.0))
        let pcm = r.disarm()

        XCTAssertFalse(pcm.isEmpty)
        XCTAssertTrue(pcm.allSatisfy { $0 == 1.0 })
    }
}
