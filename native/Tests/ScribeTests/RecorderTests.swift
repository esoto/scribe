import XCTest


/// Engine-lifecycle tests for `Recorder`: the microphone must be live only
/// between arm() and disarm(), and prewarm() must preallocate without
/// capturing — so the OS mic indicator is lit only while a dictation is
/// actually recording. The armed ring-buffer capture core is covered in
/// RingBufferTests.swift.
final class RecorderTests: XCTestCase {
    /// Fake `EngineControl` tracking lifecycle calls — the seam exists for
    /// exactly this (see the protocol's doc comment in Recorder.swift).
    private final class FakeEngineControl: EngineControl {
        var onSamples: (([Float]) -> Void)?

        private(set) var isRunning = false
        private(set) var prepareCalls = 0
        private(set) var startCalls = 0
        private(set) var stopCalls = 0
        private(set) var preferredInputs: [String?] = []

        func setPreferredInput(uid: String?) {
            preferredInputs.append(uid)
        }

        func prepare() {
            prepareCalls += 1
        }

        func start() throws {
            startCalls += 1
            isRunning = true
        }

        func stop() {
            stopCalls += 1
            isRunning = false
        }
    }

    private var engine: FakeEngineControl!
    private var recorder: Recorder!

    override func setUp() {
        super.setUp()
        engine = FakeEngineControl()
        recorder = Recorder(engineControl: engine)
    }

    func testArmStartsEngine() throws {
        try recorder.arm()
        XCTAssertTrue(engine.isRunning)
        XCTAssertEqual(engine.startCalls, 1)
    }

    func testDisarmStopsEngine() throws {
        try recorder.arm()
        _ = recorder.disarm()
        XCTAssertFalse(engine.isRunning)
        XCTAssertEqual(engine.stopCalls, 1)
    }

    func testEveryDictationCycleReleasesTheMic() throws {
        for expected in 1...3 {
            try recorder.arm()
            XCTAssertTrue(engine.isRunning)
            _ = recorder.disarm()
            XCTAssertFalse(engine.isRunning)
            XCTAssertEqual(engine.startCalls, expected)
            XCTAssertEqual(engine.stopCalls, expected)
        }
    }

    func testDisarmWithoutArmDoesNotTouchEngine() {
        _ = recorder.disarm()
        XCTAssertEqual(engine.stopCalls, 0)
    }

    func testPrewarmPreparesWithoutStarting() throws {
        try recorder.prewarm()
        XCTAssertEqual(engine.prepareCalls, 1)
        XCTAssertFalse(engine.isRunning)
        XCTAssertEqual(engine.startCalls, 0)
    }

    func testPrewarmIsNoopWhileEngineRuns() throws {
        try recorder.arm()
        try recorder.prewarm()
        XCTAssertEqual(engine.prepareCalls, 0)
    }

    func testPreferredInputPassesThroughToEngine() {
        recorder.setPreferredInput(uid: "BuiltInMicrophoneDevice")
        recorder.setPreferredInput(uid: nil)
        XCTAssertEqual(engine.preferredInputs, ["BuiltInMicrophoneDevice", nil])
    }

    func testDisarmStopsCaptureAndReturnsSamples() throws {
        try recorder.arm()
        engine.onSamples?([0.1, 0.2])
        XCTAssertEqual(recorder.disarm(), [0.1, 0.2])
        engine.onSamples?([0.3])
        try recorder.arm()
        XCTAssertEqual(recorder.disarm(), [])
    }
}
