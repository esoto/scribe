import XCTest

final class GlossaryHarvesterTests: XCTestCase {
    func testTable() {
        let cases: [(input: String, expected: [String], line: UInt)] = [
            // Acronyms qualify anywhere, including sentence-initial.
            ("The report is in JSON format", ["JSON"], #line),
            ("MLX is fast", ["MLX"], #line),
            ("upload to S3 tonight", ["S3"], #line),
            // Mixed-case / code-like tokens.
            ("use XcodeGen to build", ["XcodeGen"], #line),
            ("the KVCache warms early", ["KVCache"], #line),
            ("rename it to snake_case now", ["snake_case"], #line),
            ("load gemma3 on the laptop", ["gemma3"], #line),
            // Leading-digit tokens are quantities and ordinals, not vocabulary.
            ("meeting at 10am tomorrow", [], #line),
            ("the 3rd attempt failed", [], #line),
            ("quantized to 4bit weights", [], #line),
            ("ran 5k this morning", [], #line),
            // Mid-sentence capitalized word is a proper-noun signal.
            ("deploy with Kamal tonight", ["Kamal"], #line),
            // Sentence-initial capitalized words are NOT learned.
            ("Kamal is great", [], #line),
            ("Hello world", [], #line),
            // `.`, `!`, `?`, `:` and newlines end a sentence.
            ("ship it. Kamal handles deploys", [], #line),
            ("done\nKamal is next", [], #line),
            ("note: Kamal rocks", [], #line),
            ("really? Kamal again", [], #line),
            // ...but a non-terminal previous token keeps mid-sentence status.
            ("we use Kamal, right", ["Kamal"], #line),
            // Stoplist blocks common capitalized words mid-sentence.
            ("we ship on Friday maybe", [], #line),
            ("due in September probably", [], #line),
            // Accented proper nouns work (Unicode case checks).
            ("hablé con México y Ángel", ["México", "Ángel"], #line),
            // URLs and emails are never learned.
            ("email esoto074@gmail.com please", [], #line),
            ("see https://GitHub.com for it", [], #line),
            // Length bounds: 2–30 chars, must contain a letter.
            ("A B or C4", ["C4"], #line),
            ("2026 was busy", [], #line),
            ("call SupercalifragilisticexpialidociousService maybe", [], #line),
            // Surrounding punctuation is stripped before matching.
            ("we run Kubernetes, obviously", ["Kubernetes"], #line),
            ("wrapped (MLX) tokens", ["MLX"], #line),
            ("quoted \u{201C}Parakeet\u{201D} name", ["Parakeet"], #line),
            // Deduped within one utterance, first-occurrence order kept.
            ("MLX beats MLX every time", ["MLX"], #line),
            ("pair Kamal with MLX and Kamal", ["Kamal", "MLX"], #line),
            // Degenerate inputs.
            ("", [], #line),
            ("   \n  ", [], #line),
        ]
        for c in cases {
            XCTAssertEqual(
                GlossaryHarvester.candidates(in: c.input), c.expected,
                "input: \(c.input)", line: c.line)
        }
    }
}
