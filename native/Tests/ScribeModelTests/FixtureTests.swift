import XCTest

/// Integration tests against real models and the committed fixtures in `tests_models/fixtures/`.
final class FixtureTests: XCTestCase {
    static let parakeet = ParakeetEngine()
    static let whisper = WhisperEngine()

    func testParakeetEnglish() async throws {
        let text = try await Self.parakeet.transcribe(loadPcm("en.wav")).lowercased()
        XCTAssertTrue(text.contains("wednesday"), "actual: \(text)")
        XCTAssertTrue(text.contains("marcos"), "actual: \(text)")
    }

    func testParakeetSpanish() async throws {
        let text = try await Self.parakeet.transcribe(loadPcm("es.wav")).lowercased()
        XCTAssertTrue(text.contains("deberíamos"), "actual: \(text)")
        XCTAssertTrue(text.contains("mediodía"), "actual: \(text)")
    }

    func testParakeetSilenceIsEmpty() async throws {
        let text = try await Self.parakeet.transcribe(loadPcm("silence.wav"))
        XCTAssertEqual(text.trimmingCharacters(in: .whitespacesAndNewlines), "")
    }

    func testWhisperEnglish() async throws {
        let text = try await Self.whisper.transcribe(loadPcm("en.wav")).lowercased()
        XCTAssertTrue(text.contains("wednesday"), "actual: \(text)")
    }

    // No whisper mixed.wav assertion: its code-switched loanwords make substring checks unreliable.

    func testEnergyGateBlocksSilence() throws {
        let pcm = try loadPcm("silence.wav")
        XCTAssertFalse(Gates.passesEnergyGate(pcm, threshold: 0.0005))
    }

    func testEnergyGatePassesVoicedFixtures() throws {
        for name in ["en.wav", "es.wav", "mixed.wav"] {
            let pcm = try loadPcm(name)
            XCTAssertTrue(Gates.passesEnergyGate(pcm, threshold: 0.0005), name)
        }
    }

    /// Guards the LazyModel load-once guarantee under real concurrent load on one engine.
    func testConcurrentTranscribeOnSameEngineBothSucceed() async throws {
        let enPcm = try loadPcm("en.wav")
        let esPcm = try loadPcm("es.wav")

        async let first = Task.detached { try await Self.parakeet.transcribe(enPcm) }.value
        async let second = Task.detached { try await Self.parakeet.transcribe(esPcm) }.value
        let (enText, esText) = try await (first, second)

        let enLower = enText.lowercased()
        XCTAssertTrue(enLower.contains("wednesday"), "actual: \(enText)")
        XCTAssertTrue(enLower.contains("marcos"), "actual: \(enText)")

        let esLower = esText.lowercased()
        XCTAssertTrue(esLower.contains("deberíamos"), "actual: \(esText)")
        XCTAssertTrue(esLower.contains("mediodía"), "actual: \(esText)")
    }
}
