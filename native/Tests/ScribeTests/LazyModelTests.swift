import XCTest

/// Fake factory that counts invocations and can be told to fail or delay.
private final class CountingFactory: @unchecked Sendable {
    private(set) var calls = 0
    var shouldFail = false
    var delay: Duration?

    func make() async throws -> String {
        if let delay {
            try? await Task.sleep(for: delay)
        }
        calls += 1
        if shouldFail {
            throw TestError(message: "factory failed")
        }
        return "model-\(calls)"
    }
}

/// Thread-safe line collector: LazyModel logs from its load task, not the test's thread.
private final class LogSink: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func append(_ line: String) { lock.withLock { storage.append(line) } }
    var lines: [String] { lock.withLock { storage } }
}

final class LazyModelTests: XCTestCase {
    func testNotLoadedInitially() async {
        let factory = CountingFactory()
        let model = LazyModel(label: "test") { try await factory.make() }
        let loaded = await model.isLoaded
        XCTAssertFalse(loaded)
        XCTAssertEqual(factory.calls, 0)
    }

    func testPeekReturnsTheResidentModelAndNeverStartsALoad() async throws {
        let factory = CountingFactory()
        let model = LazyModel(label: "test") { try await factory.make() }

        let cold = await model.peek()
        XCTAssertNil(cold)
        XCTAssertEqual(factory.calls, 0)

        _ = try await model.get()
        let warm = await model.peek()
        XCTAssertEqual(warm, "model-1")

        await model.unload()
        let unloaded = await model.peek()
        XCTAssertNil(unloaded)
        XCTAssertEqual(factory.calls, 1)
    }

    func testGetLoadsOnceAcrossMultipleCalls() async throws {
        let factory = CountingFactory()
        let model = LazyModel(label: "test") { try await factory.make() }

        let first = try await model.get()
        let second = try await model.get()

        XCTAssertEqual(first, "model-1")
        XCTAssertEqual(second, "model-1")
        XCTAssertEqual(factory.calls, 1)
        let loaded = await model.isLoaded
        XCTAssertTrue(loaded)
    }

    func testUnloadThenGetReloads() async throws {
        let factory = CountingFactory()
        let model = LazyModel(label: "test") { try await factory.make() }

        _ = try await model.get()
        await model.unload()
        let loaded = await model.isLoaded
        XCTAssertFalse(loaded)

        let second = try await model.get()
        XCTAssertEqual(second, "model-2")
        XCTAssertEqual(factory.calls, 2)
    }

    func testPreloadLoads() async {
        let factory = CountingFactory()
        let model = LazyModel(label: "test") { try await factory.make() }

        await model.preload()

        let loaded = await model.isLoaded
        XCTAssertTrue(loaded)
        XCTAssertEqual(factory.calls, 1)
    }

    func testGetPropagatesFactoryError() async {
        let factory = CountingFactory()
        factory.shouldFail = true
        let model = LazyModel(label: "test") { try await factory.make() }

        do {
            _ = try await model.get()
            XCTFail("expected get() to throw")
        } catch {
        }
        let loaded = await model.isLoaded
        XCTAssertFalse(loaded)
    }

    func testConcurrentGetLoadsOnlyOnce() async throws {
        let factory = CountingFactory()
        factory.delay = .milliseconds(100)
        let model = LazyModel(label: "test") { try await factory.make() }

        async let a = model.get()
        async let b = model.get()
        let (first, second) = try await (a, b)

        XCTAssertEqual(first, "model-1")
        XCTAssertEqual(second, "model-1")
        XCTAssertEqual(factory.calls, 1)
        let loaded = await model.isLoaded
        XCTAssertTrue(loaded)
    }

    func testPreloadSwallowsFactoryError() async {
        let factory = CountingFactory()
        factory.shouldFail = true
        let model = LazyModel(label: "test") { try await factory.make() }

        await model.preload() // must not throw / crash

        let loaded = await model.isLoaded
        XCTAssertFalse(loaded)
        XCTAssertEqual(factory.calls, 1)
    }

    func testFailedPreloadLogsTheLabelAndTheError() async {
        let factory = CountingFactory()
        factory.shouldFail = true
        let sink = LogSink()
        let model = LazyModel(label: "parakeet", onLog: { sink.append($0) }) { try await factory.make() }

        await model.preload()

        XCTAssertEqual(sink.lines.count, 1, "\(sink.lines)")
        let line = sink.lines.first ?? ""
        XCTAssertTrue(line.contains("parakeet"), line)
        XCTAssertTrue(line.contains("preload failed"), line)
        XCTAssertTrue(line.contains("factory failed"), line)
    }

    func testSuccessfulLoadLogsItsLabelAndDuration() async {
        let factory = CountingFactory()
        let sink = LogSink()
        let model = LazyModel(label: "whisper", onLog: { sink.append($0) }) { try await factory.make() }

        await model.preload()

        XCTAssertEqual(sink.lines.count, 1, "\(sink.lines)")
        let line = sink.lines.first ?? ""
        XCTAssertTrue(line.hasPrefix("whisper loaded in "), line)
    }

    func testLoadForPreloadReturnsNilAndLogsInsteadOfThrowing() async {
        let factory = CountingFactory()
        factory.shouldFail = true
        let sink = LogSink()
        let model = LazyModel(label: "cleanup", onLog: { sink.append($0) }) { try await factory.make() }

        let loaded = await model.loadForPreload()

        XCTAssertNil(loaded)
        XCTAssertEqual(sink.lines.count, 1, "\(sink.lines)")
        XCTAssertEqual(factory.calls, 1, "logging a failure must not trigger a second load attempt")
    }

    func testLoadForPreloadReturnsTheModelOnSuccess() async {
        let factory = CountingFactory()
        let model = LazyModel(label: "cleanup") { try await factory.make() }

        let loaded = await model.loadForPreload()

        XCTAssertEqual(loaded, "model-1")
    }
}
