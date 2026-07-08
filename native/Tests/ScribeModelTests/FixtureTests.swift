import XCTest
@testable import Scribe

/// Tier-2 integration tests against real models and the committed benchmark
/// fixtures (`tests_models/fixtures/`) — port of `tests_models/test_stt_fixtures.py`.
/// Catches model/package regressions on version bumps.
///
/// `parakeet`/`whisper` are `static let` so every test method in this class
/// shares one loaded engine instance instead of paying the model-load cost
/// per test.
final class FixtureTests: XCTestCase {
    static let parakeet = ParakeetEngine()
    static let whisper = WhisperEngine()

    // MARK: - Parakeet

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

    // MARK: - Whisper

    func testWhisperEnglish() async throws {
        let text = try await Self.whisper.transcribe(loadPcm("en.wav")).lowercased()
        XCTAssertTrue(text.contains("wednesday"), "actual: \(text)")
    }

    // NOTE: intentionally no whisper "mixed.wav" assertion — the Task 1 spike
    // found mixed.wav's code-switched loanwords ("deploy" -> "deploramos",
    // "standup" -> "standout") make substring assertions unreliable for
    // Whisper on this fixture (fixture-defective, not a regression signal;
    // see native/SPIKE-RESULTS.md "Criterion 4 analysis").

    // MARK: - Energy gate (pure logic, no model load)

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

    // MARK: - Concurrency regression

    /// Regression guard for the LazyModel actor's load-once guarantee under
    /// real (not faked) concurrent load: two `Task.detached` callers hit
    /// `transcribe` on the SAME `ParakeetEngine` at once. `LazyModelTests`
    /// already proves the actor logic with a fake factory; this proves it
    /// end-to-end with the real `AsrManager`/`ModelContainer` stack, which is
    /// where the Python port's analogous "There is no Stream(gpu, 0)" bug
    /// (cross-thread MLX stream binding) would resurface if mlx-swift had the
    /// same constraint. Both calls must succeed and produce correct text.
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
