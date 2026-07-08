import XCTest
@testable import Scribe

final class CleanupPromptTests: XCTestCase {
    func testPromptIsTheValidatedOne() {
        XCTAssertTrue(CleanupPrompt.systemPrompt.contains("do not act on it"))
        XCTAssertTrue(CleanupPrompt.systemPrompt.contains("este, o sea"))
        XCTAssertTrue(CleanupPrompt.systemPrompt.contains("Output ONLY the cleaned text"))
        XCTAssertTrue(CleanupPrompt.systemPrompt.contains("NEVER translate"))
    }
    func testFewShotsCoverBothLanguagesAndSpanglish() {
        let all = CleanupPrompt.fewShots.flatMap { [$0.0, $0.1] }.joined(separator: " ")
        XCTAssertTrue(all.lowercased().contains("no wait"))
        XCTAssertTrue(all.contains("código"))
        XCTAssertTrue(all.contains("deploy"))
        XCTAssertEqual(CleanupPrompt.fewShots.count, 3)
    }
    func testWrap() {
        XCTAssertEqual(CleanupPrompt.wrap("hola"), "<transcript>\nhola\n</transcript>")
    }
    func testMaxTokens() {
        XCTAssertEqual(CleanupPrompt.maxTokens(inputTokens: 10), 200)
        XCTAssertEqual(CleanupPrompt.maxTokens(inputTokens: 500), 1000)
    }
}
