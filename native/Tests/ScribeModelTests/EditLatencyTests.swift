import XCTest

/// REPORT-ONLY: edit time per verb at 50 and 200 words, for the model named by `CLEANUP_MODEL`
/// (`make test-models-edit`). The deadline E4 gives an edit has to come from numbers, not from the cleanup deadline.
/// The text is the first N words of the en90 script (plain prose, so the model edits rather than answers). One untimed
/// call per verb and length first, so the timed runs are not the one that builds a prompt-specific cache; then three
/// timed runs. Temperature is 0, so every run returns the same text and `accepted` is one answer for the three. Asserts
/// only that the model returned text. An edit that throws fails its own verb with an `error=<type>` line and the table
/// goes on, so one MLX error does not cost the remaining verbs.
final class EditLatencyTests: XCTestCase {
    private static let lengths = [50, 200]
    private static let runsPerLength = 3

    func testEditLatencyByVerbAndInputLength() async throws {
        let backend = try cleanupBackendUnderTest()
        backend.setDictionary(.empty)
        let script = repoRoot().appendingPathComponent("tests_models/fixtures/en90.txt")
        let pool = (try? String(contentsOf: script, encoding: .utf8))?.split(whereSeparator: { $0.isWhitespace }) ?? []
        let longest = Self.lengths.max() ?? 0
        try XCTSkipIf(pool.count < longest, "tests_models/fixtures/en90.txt is missing or has fewer than \(longest) words")
        let model = cleanupSpecUnderTest().id.rawValue

        await backend.preload()

        for verb in EditVerb.allCases {
            do {
                try await measure(verb, pool: pool, model: model, backend: backend)
            } catch {
                print(editLatencyErrorLine(model: model, verb: verb, error: error))
                XCTFail("[\(verb.rawValue)] edit threw \(String(describing: type(of: error)))")
            }
        }
    }

    private func measure(_ verb: EditVerb, pool: [Substring], model: String, backend: any CleanupModelBackend) async throws {
        for words in Self.lengths {
            let text = pool.prefix(words).map(String.init).joined(separator: " ")
            let maxTokens = EditPrompt.maxTokens(verb: verb, inputTokens: text.count / 4)
            let instruction = EditPrompt.instruction(verb: verb, selection: text)
            _ = try await backend.edit(instruction: instruction, text: text, maxTokens: maxTokens)

            var timings: [Int] = []
            var outWords = 0
            var accepted = false
            for _ in 0..<Self.runsPerLength {
                let t0 = Date()
                let edited = try await backend.edit(instruction: instruction, text: text, maxTokens: maxTokens)
                timings.append(Int(Date().timeIntervalSince(t0) * 1000))
                XCTAssertFalse(edited.isEmpty, "[\(verb.rawValue), \(words) words] empty output")
                outWords = edited.split(whereSeparator: { $0.isWhitespace }).count
                if case .accepted = EditGates.accept(verb: verb, selection: text, result: edited) { accepted = true } else { accepted = false }
            }
            timings.sort()
            print("edit_latency[\(model)] verb=\(verb.rawValue) words=\(words) p50=\(timings[timings.count / 2]) ms max=\(timings[timings.count - 1]) ms out_words=\(outWords) accepted=\(accepted)")
        }
    }
}
