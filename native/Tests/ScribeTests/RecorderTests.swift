import XCTest


/// The mic is live only between arm() and disarm(); prewarm() prepares without capturing.
final class RecorderTests: XCTestCase {
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

    func testLevelReportsEachChunkOnlyWhileArmed() throws {
        var levels: [Double] = []
        recorder.onLevel = { levels.append($0) }

        engine.onSamples?([Float](repeating: 0.5, count: 160))
        XCTAssertEqual(levels, [])

        try recorder.arm()
        engine.onSamples?([Float](repeating: 0.5, count: 160))
        engine.onSamples?([Float](repeating: 0.0, count: 160))
        XCTAssertEqual(levels.count, 2)
        XCTAssertEqual(levels[0], 0.5, accuracy: 1e-6)
        XCTAssertEqual(levels[1], 0)

        _ = recorder.disarm()
        engine.onSamples?([Float](repeating: 0.5, count: 160))
        XCTAssertEqual(levels.count, 2)
    }
}
