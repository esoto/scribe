import XCTest


/// Pins the key-down preload contract: `preload()` must leave the backend
/// fully warm (weights loaded AND prefix cache built), because AppModel
/// fires it on key-down specifically so the first post-idle dictation's
/// cleanup pays only the generation — not load + warm-up + first-use
/// kernel compilation.
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
