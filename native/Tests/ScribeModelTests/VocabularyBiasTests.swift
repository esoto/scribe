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
        // A realistic bias set (curated engineering pack) must not change a
        // sentence that contains none of its terms. Exercises the full CTC
        // path end to end.
        let engine = ParakeetEngine()
        engine.setBiasVocabulary(
            BiasVocabularyBuilder.build(pairs: [], glossary: [], includeCuratedPack: true))

        let en = try await engine.transcribe(loadPcm("en.wav")).lowercased()
        XCTAssertTrue(en.contains("wednesday"), "actual: \(en)")
        XCTAssertTrue(en.contains("marcos"), "actual: \(en)")
        // The rescorer must have run cleanly — .applied or .unmodified, never
        // .failed. (.noCtcModel is tolerated: offline CI can't download.)
        XCTAssertNotEqual(
            engine.lastBiasOutcomeForTesting, .failed,
            "the CTC rescorer path threw — likely a FluidAudio API mismatch")

        let es = try await engine.transcribe(loadPcm("es.wav")).lowercased()
        XCTAssertTrue(es.contains("deberíamos"), "actual: \(es)")
        XCTAssertTrue(es.contains("mediodía"), "actual: \(es)")
    }

    func testSilenceStaysEmptyUnderBiasing() async throws {
        let engine = ParakeetEngine()
        engine.setBiasVocabulary([biasTerm("Kubernetes", ["cuber netties"])])
        let text = try await engine.transcribe(loadPcm("silence.wav"))
        XCTAssertEqual(text.trimmingCharacters(in: .whitespacesAndNewlines), "")
    }
}
