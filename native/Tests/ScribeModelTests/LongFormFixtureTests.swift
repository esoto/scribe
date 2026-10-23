import XCTest

/// REPORT-ONLY (M-2 in the 1.5 plan): Parakeet over the long clips a latch-mode dictation can
/// reach (en90 is 75.6 s, es90 96.3 s; `audio=` says so). Spanish also reports the English share
/// of stopword hits overall and per third, because drifting into English partway through is the
/// failure long clips risk (above 0.5 in any third means drift), and prints the transcript so
/// "stays Spanish" is read, not inferred. `script_words` counts the text `say` spoke (the `.txt`
/// beside each clip), so a dropped tail shows. The only assertion is a non-empty transcript;
/// read the log (`make measure-longform`).
final class LongFormFixtureTests: XCTestCase {
    func testLongFormEnglish() async throws {
        let run = try await transcribeTimed("en90")
        print("longform[en90] words=\(wordCount(run.text)) elapsed=\(run.ms) ms audio=\(run.audio) s script_words=\(run.scriptWords)")
        XCTAssertFalse(run.text.isEmpty)
    }

    func testLongFormSpanish() async throws {
        let run = try await transcribeTimed("es90")
        let words = StopwordDrift.words(run.text)
        let overall = StopwordDrift.hits(words)
        let thirds = StopwordDrift.thirds(words).map { String(format: "%.2f", $0.ratio) }.joined(separator: "/")
        print("longform[es90] words=\(wordCount(run.text)) elapsed=\(run.ms) ms en_stopword_ratio=\(String(format: "%.2f", overall.ratio)) thirds=\(thirds) en_hits=\(overall.en) es_hits=\(overall.es) audio=\(run.audio) s script_words=\(run.scriptWords)")
        print("    es90 out: \(run.text)")
        XCTAssertFalse(run.text.isEmpty)
    }

    /// Load plus one short untimed clip before the clock starts, so `elapsed` is transcription, not
    /// download, load or the process's first inference (en90 runs first and would carry it alone).
    private func transcribeTimed(_ name: String) async throws -> (text: String, ms: Int, audio: String, scriptWords: Int) {
        let fixtures = repoRoot().appendingPathComponent("tests_models/fixtures")
        let url = fixtures.appendingPathComponent("\(name).wav")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "tests_models/fixtures/\(name).wav is missing")
        let pcm = try loadPcm("\(name).wav")
        let script = (try? String(contentsOf: fixtures.appendingPathComponent("\(name).txt"), encoding: .utf8)) ?? ""
        await FixtureTests.parakeet.preload()
        _ = try await FixtureTests.parakeet.transcribe(loadPcm("en.wav"))
        let t0 = Date()
        let text = try await FixtureTests.parakeet.transcribe(pcm)
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        // loadPcm returns FluidAudio's 16 kHz mono.
        return (text, ms, String(format: "%.1f", Double(pcm.count) / 16_000), wordCount(script))
    }

    private func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }
}
