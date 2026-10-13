import XCTest

/// Model-backed Parakeet vocabulary biasing tests. The biasing-on tests download `parakeet-ctc-110m-coreml` on first run.
final class VocabularyBiasTests: XCTestCase {
    private func biasTerm(_ text: String, _ aliases: [String] = []) -> BiasTerm {
        BiasTerm(text: text, aliases: aliases)
    }

    func testEmptyVocabIsIdentity() async throws {
        let engine = ParakeetEngine()
        let text = try await engine.transcribe(loadPcm("en.wav")).lowercased()
        XCTAssertTrue(text.contains("wednesday"), "actual: \(text)")
        XCTAssertTrue(text.contains("marcos"), "actual: \(text)")
        XCTAssertEqual(engine.lastBiasOutcomeForTesting, .disabled)
    }

    func testCuratedPackDoesNotCorruptNormalSpeech() async throws {
        // Compares whole strings: checking only a few words missed Spanish corruption (bueno -> Deno).
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
        // The rescorer is keyed on the exact terms, so a mid-session change must not pin a stale one.
        let engine = ParakeetEngine()
        engine.setBiasVocabulary([biasTerm("Kubernetes")])
        _ = try await engine.transcribe(loadPcm("en.wav"))
        XCTAssertNotEqual(engine.lastBiasOutcomeForTesting, .failed)

        engine.setBiasVocabulary([biasTerm("Terraform"), biasTerm("Postgres")])
        let text = try await engine.transcribe(loadPcm("en.wav")).lowercased()
        XCTAssertNotEqual(engine.lastBiasOutcomeForTesting, .failed)
        XCTAssertTrue(text.contains("marcos"), "actual: \(text)")
    }
}
