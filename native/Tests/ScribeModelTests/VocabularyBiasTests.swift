import XCTest

/// Model-backed tests for Parakeet vocabulary biasing. What these CAN prove:
/// (1) no regression — biasing never corrupts ordinary speech; (2) the full
/// CTC path runs without error (the `lastBiasOutcomeForTesting` seam defeats
/// the graceful do/catch that would otherwise hide a broken rescorer).
///
/// What they CANNOT prove: that a specific mishearing is fixed — no committed
/// fixture contains an engineering term Parakeet mishears in a bias-fixable
/// way, and the shared WAVs are co-asserted by the Python suite. The
/// "cloud" → "Claude" fix is validated only by the user's live voice.
///
/// The biasing-on tests download the auxiliary `parakeet-ctc-110m-coreml`
/// model on first run.
final class VocabularyBiasTests: XCTestCase {
    private func biasTerm(_ text: String, _ aliases: [String] = []) -> BiasTerm {
        BiasTerm(text: text, aliases: aliases)
    }

    func testEmptyVocabIsIdentity() async throws {
        // No bias vocabulary set → the fixture transcription is unchanged and
        // no CTC model is loaded.
        let engine = ParakeetEngine()
        let text = try await engine.transcribe(loadPcm("en.wav")).lowercased()
        XCTAssertTrue(text.contains("wednesday"), "actual: \(text)")
        XCTAssertTrue(text.contains("marcos"), "actual: \(text)")
        XCTAssertEqual(engine.lastBiasOutcomeForTesting, .disabled)
    }

    func testCuratedPackDoesNotCorruptNormalSpeech() async throws {
        // The curated pack must not change ANY word of a sentence that
        // contains none of its terms — asserted on the WHOLE string, not a
        // couple of words. An earlier version checked only "marcos"/"wednesday"
        // and so missed "bueno"→"Deno" / "mañana"→"Grafana" corruption in
        // Spanish. This is the regression guard for the threshold clamp.
        let plain = ParakeetEngine()
        let biased = ParakeetEngine()
        biased.setBiasVocabulary(
            BiasVocabularyBuilder.build(pairs: [], glossary: [], includeCuratedPack: true))

        for name in ["en.wav", "es.wav", "mixed.wav"] {
            let pcm = try loadPcm(name)
            let p = try await plain.transcribe(pcm)
            let b = try await biased.transcribe(pcm)
            XCTAssertEqual(b, p, "curated-pack biasing changed \(name):\n  plain:  \(p)\n  biased: \(b)")
            XCTAssertNotEqual(
                biased.lastBiasOutcomeForTesting, .failed,
                "the CTC rescorer path threw — likely a FluidAudio API mismatch")
        }
    }

    func testSilenceStaysEmptyUnderBiasing() async throws {
        let engine = ParakeetEngine()
        engine.setBiasVocabulary([biasTerm("Kubernetes", ["cuber netties"])])
        let text = try await engine.transcribe(loadPcm("silence.wav"))
        XCTAssertEqual(text.trimmingCharacters(in: .whitespacesAndNewlines), "")
    }

    func testVocabularyChangeTakesEffectAcrossDictations() async throws {
        // Regression for the cache-key fix: the rescorer trio is keyed on the
        // exact terms, so a mid-session vocab change is honored on the next
        // dictation rather than pinning a stale rescorer.
        let engine = ParakeetEngine()
        engine.setBiasVocabulary([biasTerm("Kubernetes")])
        _ = try await engine.transcribe(loadPcm("en.wav"))
        XCTAssertNotEqual(engine.lastBiasOutcomeForTesting, .failed)

        engine.setBiasVocabulary([biasTerm("Terraform"), biasTerm("Postgres")])
        let text = try await engine.transcribe(loadPcm("en.wav")).lowercased()
        // The new vocabulary was rebuilt cleanly (not stale, not thrown) and
        // still doesn't corrupt the sentence.
        XCTAssertNotEqual(engine.lastBiasOutcomeForTesting, .failed)
        XCTAssertTrue(text.contains("marcos"), "actual: \(text)")
    }
}
