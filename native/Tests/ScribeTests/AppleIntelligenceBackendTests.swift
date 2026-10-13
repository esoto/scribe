import FoundationModels
import XCTest

final class AppleIntelligenceBackendTests: XCTestCase {
    func testTranscriptIsInstructionsThenFewShotPairs() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels needs macOS 26") }
        let transcript = AppleIntelligenceBackend.transcript(instructions: "SYS")
        XCTAssertEqual(transcript.count, 1 + 2 * AFMCleanupPrompt.fewShots.count)
        guard case .instructions = transcript.first else { return XCTFail("first entry must be instructions") }
        guard case .response = transcript.last else { return XCTFail("last entry must be a few-shot response") }
    }

    func testOptionsAreGreedyAndBoundedLikeGemma() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels needs macOS 26") }
        let options = AppleIntelligenceBackend.options(for: String(repeating: "a", count: 2000))
        XCTAssertEqual(options.maximumResponseTokens, CleanupPrompt.maxTokens(inputTokens: 500))
        XCTAssertEqual(options.temperature, 0)
    }

    func testInstructionsRenderTheDictionaryLikeGemma() {
        let snap = DictionarySnapshot(pairs: [], glossary: ["Kamal"])
        XCTAssertEqual(AFMCleanupPrompt.instructions(with: snap), CleanupPrompt.systemPrompt(with: snap))
    }

    func testHoldsNoMemory() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels needs macOS 26") }
        XCTAssertFalse(AppleIntelligenceBackend().holdsMemory)
    }

    func testUnavailableReasonIsNilExactlyWhenAvailable() {
        XCTAssertEqual(AppleIntelligence.unavailableReason == nil, AppleIntelligence.isAvailable)
    }
}
