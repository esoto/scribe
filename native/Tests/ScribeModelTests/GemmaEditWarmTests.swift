import XCTest

/// The edit prompt keeps its own warm prefix beside the cleanup one: `preload()` builds only cleanup's, the first
/// edit builds the other, and `unload()` drops both with the model.
final class GemmaEditWarmTests: XCTestCase {
    func testEditWarmsItsOwnPrefixOnFirstUseAndUnloadDropsBoth() async throws {
        let backend = GemmaBackend()

        await backend.preload()
        XCTAssertTrue(backend.isWarm)
        XCTAssertFalse(backend.isEditWarm, "preload() warms cleanup only, so a dictation after launch pays nothing new")
        XCTAssertEqual(backend.warmPrefixSlotsForTesting, [CleanupPrompt.systemPrompt])

        let edited = try await backend.edit(
            instruction: EditVerb.fixGrammar.instruction, text: "i has a apple and two orange", maxTokens: 200)
        XCTAssertFalse(edited.isEmpty)
        XCTAssertTrue(backend.isEditWarm)
        XCTAssertTrue(backend.isWarm, "an edit must not evict the cleanup prefix")
        XCTAssertEqual(backend.warmSystemPromptForTesting, CleanupPrompt.systemPrompt)
        XCTAssertEqual(Set(backend.warmPrefixSlotsForTesting), [CleanupPrompt.systemPrompt, EditPrompt.systemPrompt])

        let cleaned = try await backend.clean("so um the report is uh ready now")
        XCTAssertFalse(cleaned.isEmpty)

        await backend.unload()
        XCTAssertFalse(backend.isWarm)
        XCTAssertFalse(backend.isEditWarm)
        XCTAssertTrue(backend.warmPrefixSlotsForTesting.isEmpty)
    }
}
