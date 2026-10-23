import XCTest

/// REPORT-ONLY (M-3 in the 1.5 plan): cleanup latency as the input grows, for the model named by
/// `CLEANUP_MODEL` (`make measure-cleanup-latency`). Latch mode makes long utterances normal,
/// and the golden set only times 10-30 word inputs. The text is the first N words of the en90
/// script (`tests_models/fixtures/en90.txt`): plain dictation prose, so the model cleans rather
/// than answers (a 200-word window over the golden pool, which holds an injection case and
/// questions, made gemma4 return ten words). Asserts only that the model returned text.
final class CleanupLatencyByLengthTests: XCTestCase {
    private static let lengths = [20, 50, 100, 200]
    private static let runsPerLength = 3

    func testCleanupLatencyByInputLength() async throws {
        let backend = try cleanupBackendUnderTest()
        backend.setDictionary(.empty)
        let script = repoRoot().appendingPathComponent("tests_models/fixtures/en90.txt")
        let pool = (try? String(contentsOf: script, encoding: .utf8))?.split(whereSeparator: { $0.isWhitespace }) ?? []
        let longest = Self.lengths.max() ?? 0
        try XCTSkipIf(pool.count < longest, "tests_models/fixtures/en90.txt is missing or has fewer than \(longest) words")
        let model = cleanupSpecUnderTest().id.rawValue

        // Weights and prefix cache first, then one untimed call so the first timed run isn't a cold generation.
        await backend.preload()
        _ = try await backend.clean(input(words: Self.lengths[0], from: pool))

        for words in Self.lengths {
            let text = input(words: words, from: pool)
            var timings: [Int] = []
            var outWords = 0
            for _ in 0..<Self.runsPerLength {
                let t0 = Date()
                let cleaned = try await backend.clean(text)
                timings.append(Int(Date().timeIntervalSince(t0) * 1000))
                XCTAssertFalse(cleaned.isEmpty, "[\(words) words] empty output")
                // Temperature 0, so every run returns the same text; a short count means the model
                // answered or cut the input instead of cleaning it, and the time is not comparable.
                outWords = cleaned.split(whereSeparator: { $0.isWhitespace }).count
            }
            timings.sort()
            print("latency[\(model)] words=\(words) p50=\(timings[timings.count / 2]) ms max=\(timings[timings.count - 1]) ms out_words=\(outWords)")
        }
    }

    /// The first `words` words of the script, as one utterance.
    private func input(words: Int, from pool: [Substring]) -> String {
        pool.prefix(words).map(String.init).joined(separator: " ")
    }
}
