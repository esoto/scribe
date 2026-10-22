import XCTest

/// REPORT-ONLY (M-3 in the 1.5 plan): cleanup latency as the input grows, for the model named by
/// `CLEANUP_MODEL` (`make measure-cleanup-latency`). Latch mode makes long utterances normal,
/// and the golden set only times 10-30 word inputs. Asserts only that the model returned text.
final class CleanupLatencyByLengthTests: XCTestCase {
    private static let lengths = [20, 50, 100, 200]
    private static let runsPerLength = 3

    func testCleanupLatencyByInputLength() async throws {
        let backend = try cleanupBackendUnderTest()
        backend.setDictionary(.empty)
        let pool = try loadGoldenSet("golden.json").cases.flatMap { $0.input.split(whereSeparator: { $0.isWhitespace }) }
        try XCTSkipIf(pool.isEmpty, "golden.json has no inputs")
        let model = cleanupSpecUnderTest().id.rawValue

        // Weights and prefix cache first, then one untimed call so the first timed run isn't a cold generation.
        await backend.preload()
        _ = try await backend.clean(input(words: Self.lengths[0], from: pool))

        for words in Self.lengths {
            let text = input(words: words, from: pool)
            var timings: [Int] = []
            for _ in 0..<Self.runsPerLength {
                let t0 = Date()
                let cleaned = try await backend.clean(text)
                timings.append(Int(Date().timeIntervalSince(t0) * 1000))
                XCTAssertFalse(cleaned.isEmpty, "[\(words) words] empty output")
            }
            timings.sort()
            print("latency[\(model)] words=\(words) p50=\(timings[timings.count / 2]) ms max=\(timings[timings.count - 1]) ms")
        }
    }

    /// The golden inputs end to end, wrapping around: they hold fewer than 200 words in all.
    private func input(words: Int, from pool: [Substring]) -> String {
        (0..<words).map { String(pool[$0 % pool.count]) }.joined(separator: " ")
    }
}
