import XCTest

/// RingBuffer behavior and Recorder's armed capture (ingest/arm/disarm) with a fake engine.
final class RingBufferTests: XCTestCase {
    private func chunk(_ v: Float, _ n: Int = 160) -> [Float] {
        [Float](repeating: v, count: n)
    }

    /// Stub engine that never touches real hardware.
    private final class FakeEngineControl: EngineControl {
        var onSamples: (([Float]) -> Void)?
        private(set) var startCalls = 0
        var running = false
        var failStart = false

        var isRunning: Bool { running }

        func prepare() {}

        func setPreferredInput(uid: String?) {}

        func start() throws {
            startCalls += 1
            if failStart {
                throw RecorderError(message: "no device")
            }
            running = true
        }

        func stop() {
            running = false
        }
    }

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
        // Re-arming must discard audio left undrained by the previous session.
        try r.arm()
        r.ingest(chunk(1.0))
        let pcm = r.disarm()

        XCTAssertFalse(pcm.isEmpty)
        XCTAssertTrue(pcm.allSatisfy { $0 == 1.0 })
    }

    /// arm() restarts an engine that died between sessions.
    func testArmRestartsDeadEngine() throws {
        let engineControl = FakeEngineControl()
        let r = Recorder(engineControl: engineControl)

        try r.arm()
        XCTAssertEqual(engineControl.startCalls, 1)

        engineControl.running = false

        XCTAssertNoThrow(try r.arm())
        XCTAssertEqual(engineControl.startCalls, 2)
    }

    /// arm() surfaces the start failure and stays disarmed (fail-closed).
    func testArmThrowsWhenEngineStartFailsAndStaysDisarmed() {
        let engineControl = FakeEngineControl()
        engineControl.failStart = true
        let r = Recorder(engineControl: engineControl)

        XCTAssertThrowsError(try r.arm())

        r.ingest(chunk(1.0))
        XCTAssertTrue(r.disarm().isEmpty)
    }
}
