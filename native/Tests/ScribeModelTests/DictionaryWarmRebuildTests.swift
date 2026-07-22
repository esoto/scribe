import XCTest

/// Pins the dictionary/warm-prefix contract: the prefix cache is keyed on
/// the rendered system prompt, so a dictionary snapshot change must rebuild
/// it exactly once (on the next preload/clean), and an unchanged snapshot
/// must never invalidate it — otherwise every dictation silently pays the
/// full uncached prompt render.
final class DictionaryWarmRebuildTests: XCTestCase {
    func testWarmPrefixFollowsDictionarySnapshot() async throws {
        let backend = GemmaBackend()

        // Cold start with an empty dictionary → warm prompt is the base one.
        await backend.preload()
        XCTAssertTrue(backend.isWarm)
        XCTAssertEqual(backend.warmSystemPromptForTesting, CleanupPrompt.systemPrompt)

        // Publishing a snapshot makes the prefix stale; preload rebuilds it
        // for the new prompt.
        let snapshot = DictionarySnapshot(
            pairs: [
                ReplacementPair(
                    original: "camel", replacement: "kamal",
                    addedAt: Date(timeIntervalSince1970: 0))
            ],
            glossary: ["Parakeet"])
        backend.setDictionary(snapshot)
        await backend.preload()
        XCTAssertTrue(backend.isWarm)
        let warmPrompt = try XCTUnwrap(backend.warmSystemPromptForTesting)
        XCTAssertTrue(warmPrompt.contains("\"Parakeet\""))
        XCTAssertTrue(warmPrompt.contains("write \"camel\" as \"kamal\""))

        // Cleaning with the dictionary-augmented prompt still produces
        // sane output (and must not fall back on a prefix mismatch).
        let cleaned = try await backend.clean(
            "so um the parakeet config is uh ready now")
        XCTAssertFalse(cleaned.isEmpty)

        // Republishing an EQUAL snapshot must not invalidate the prefix.
        backend.setDictionary(snapshot)
        await backend.preload()
        XCTAssertEqual(backend.warmSystemPromptForTesting, warmPrompt)

        // Back to empty → rebuilds with the base prompt again.
        backend.setDictionary(.empty)
        await backend.preload()
        XCTAssertEqual(backend.warmSystemPromptForTesting, CleanupPrompt.systemPrompt)

        await backend.unload()
    }
}
