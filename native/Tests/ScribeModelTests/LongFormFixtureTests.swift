import XCTest

/// REPORT-ONLY (M-2 in the 1.5 plan): Parakeet over the 90-second clips a latch-mode
/// dictation can reach. Prints wall time and, for Spanish, the English share of the
/// stopword hits, because drifting into English is the failure long clips risk (above
/// 0.5 means drift). The only assertion is a non-empty transcript; read the numbers in
/// the log (`make measure-longform`).
final class LongFormFixtureTests: XCTestCase {
    func testLongFormEnglish() async throws {
        let (text, ms) = try await transcribeTimed("en90.wav")
        print("longform[en90] words=\(wordCount(text)) elapsed=\(ms) ms")
        XCTAssertFalse(text.isEmpty)
    }

    func testLongFormSpanish() async throws {
        let (text, ms) = try await transcribeTimed("es90.wav")
        let ratio = String(format: "%.2f", englishStopwordRatio(text))
        print("longform[es90] words=\(wordCount(text)) elapsed=\(ms) ms en_stopword_ratio=\(ratio)")
        XCTAssertFalse(text.isEmpty)
    }

    /// Loads the model before the clock starts so `elapsed` is transcription, not download or load.
    private func transcribeTimed(_ name: String) async throws -> (text: String, ms: Int) {
        let url = repoRoot().appendingPathComponent("tests_models/fixtures/\(name)")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "tests_models/fixtures/\(name) is missing")
        let pcm = try loadPcm(name)
        await FixtureTests.parakeet.preload()
        let t0 = Date()
        let text = try await FixtureTests.parakeet.transcribe(pcm)
        return (text, Int(Date().timeIntervalSince(t0) * 1000))
    }

    private func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    /// English hits over English + Spanish hits, from the gate's own lists. Words in both lists ("a") are
    /// skipped so they can't pull a Spanish transcript toward 0.5. Splits on non-letters because the
    /// transcript is punctuated and the gate's whitespace split would miss "the,".
    private func englishStopwordRatio(_ text: String) -> Double {
        let words = text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        let english = words.filter { Gates.enStopwords.contains($0) && !Gates.esStopwords.contains($0) }.count
        let spanish = words.filter { Gates.esStopwords.contains($0) && !Gates.enStopwords.contains($0) }.count
        return english + spanish == 0 ? 0 : Double(english) / Double(english + spanish)
    }
}
