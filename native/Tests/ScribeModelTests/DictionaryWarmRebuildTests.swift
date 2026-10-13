import XCTest

/// The warm prefix is keyed on the rendered prompt; an equal snapshot must not invalidate it.
final class DictionaryWarmRebuildTests: XCTestCase {
    func testWarmPrefixFollowsDictionarySnapshot() async throws {
        let backend = GemmaBackend()

        await backend.preload()
        XCTAssertTrue(backend.isWarm)
        XCTAssertEqual(backend.warmSystemPromptForTesting, CleanupPrompt.systemPrompt)

        let pair = ReplacementPair(
            original: "camel", replacement: "kamal", addedAt: Date(timeIntervalSince1970: 0))

        backend.setDictionary(DictionarySnapshot(pairs: [pair], glossary: []))
        await backend.preload()
        XCTAssertEqual(
            backend.warmSystemPromptForTesting, CleanupPrompt.systemPrompt,
            "editing a replacement pair must not cost a prefix rebuild")

        let snapshot = DictionarySnapshot(pairs: [pair], glossary: ["Parakeet"])
        backend.setDictionary(snapshot)
        await backend.preload()
        XCTAssertTrue(backend.isWarm)
        let warmPrompt = try XCTUnwrap(backend.warmSystemPromptForTesting)
        XCTAssertTrue(warmPrompt.contains("\"Parakeet\""))
        XCTAssertFalse(warmPrompt.contains("kamal"))

        let cleaned = try await backend.clean(
            "so um the parakeet config is uh ready now")
        XCTAssertFalse(cleaned.isEmpty)

        backend.setDictionary(snapshot)
        await backend.preload()
        XCTAssertEqual(backend.warmSystemPromptForTesting, warmPrompt)

        backend.setDictionary(.empty)
        await backend.preload()
        XCTAssertEqual(backend.warmSystemPromptForTesting, CleanupPrompt.systemPrompt)

        await backend.unload()
    }
}
