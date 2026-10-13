import XCTest

/// `preload()` must leave the backend fully warm (weights and prefix cache), since AppModel fires it on key-down.
final class GemmaPreloadTests: XCTestCase {
    func testPreloadWarmsUpAndUnloadResets() async throws {
        let backend = GemmaBackend()

        await backend.preload()
        let loaded = await backend.isLoaded
        XCTAssertTrue(loaded)
        XCTAssertTrue(backend.isWarm, "preload() must build the warm prefix, not just load weights")

        await backend.unload()
        XCTAssertFalse(backend.isWarm, "unload() must drop the warm prefix with the model")
    }
}
