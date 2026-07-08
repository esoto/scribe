import XCTest
@testable import Scribe

/// Counting fake factory — records how many times it was invoked and can be
/// told to fail on demand, so tests can assert load-once/reload/error-vs-
/// swallow behavior without touching any real model.
private final class CountingFactory: @unchecked Sendable {
    private(set) var calls = 0
    var shouldFail = false

    func make() async throws -> String {
        calls += 1
        if shouldFail {
            throw TestError(message: "factory failed")
        }
        return "model-\(calls)"
    }
}

final class LazyModelTests: XCTestCase {
    func testNotLoadedInitially() async {
        let factory = CountingFactory()
        let model = LazyModel(label: "test") { try await factory.make() }
        let loaded = await model.isLoaded
        XCTAssertFalse(loaded)
        XCTAssertEqual(factory.calls, 0)
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
            // expected
        }
        let loaded = await model.isLoaded
        XCTAssertFalse(loaded)
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
}
