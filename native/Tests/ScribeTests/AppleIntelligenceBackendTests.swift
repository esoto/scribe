import FoundationModels
import XCTest

final class AppleIntelligenceBackendTests: XCTestCase {
    @available(macOS 26.0, *)
    private func promptTexts(_ transcript: Transcript) -> [String] {
        transcript.compactMap { entry -> String? in
            guard case .prompt(let prompt) = entry else { return nil }
            return prompt.segments.compactMap { segment -> String? in
                guard case .text(let text) = segment else { return nil }
                return text.content
            }.joined()
        }
    }

    private final class Flag: @unchecked Sendable {
        var fired = false
    }

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

    func testCleanupFewShotsAreStillWrappedInTranscriptTags() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels needs macOS 26") }
        let prompts = promptTexts(AppleIntelligenceBackend.transcript(instructions: "SYS"))
        XCTAssertEqual(prompts, AFMCleanupPrompt.fewShots.map { CleanupPrompt.wrap($0.0) })
    }

    func testEditTranscriptIsInstructionsThenTheEditFewShotPairs() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels needs macOS 26") }
        let transcript = AppleIntelligenceBackend.transcript(
            instructions: EditPrompt.systemPrompt, fewShots: EditPrompt.fewShots)
        XCTAssertEqual(transcript.count, 1 + 2 * EditPrompt.fewShots.count)
        XCTAssertEqual(transcript.count, 5)
        guard case .instructions = transcript.first else { return XCTFail("first entry must be instructions") }
        guard case .response = transcript.last else { return XCTFail("last entry must be a few-shot response") }
        XCTAssertEqual(promptTexts(transcript), EditPrompt.fewShots.map { $0.0 }, "already wrapped, never wrapped twice")
        for prompt in promptTexts(transcript) {
            XCTAssertTrue(prompt.hasPrefix("<instruction>\n"), prompt)
            XCTAssertFalse(prompt.contains("<transcript>"), prompt)
        }
    }

    func testEditOptionsAreGreedyAndUseTheCallersBudget() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels needs macOS 26") }
        let budget = EditPrompt.maxTokens(verb: .toSpanish, inputTokens: 400)
        let options = AppleIntelligenceBackend.options(forEdit: budget)
        XCTAssertEqual(options.maximumResponseTokens, 800)
        XCTAssertEqual(options.temperature, 0)
    }

    func testEditWithoutAppleIntelligenceReportsItAndThrows() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels needs macOS 26") }
        try XCTSkipIf(AppleIntelligence.isAvailable, "Apple Intelligence is on here, so the unavailable path cannot run")
        let flag = Flag()
        let backend = AppleIntelligenceBackend(onUnavailable: { flag.fired = true })

        do {
            _ = try await backend.edit(instruction: EditVerb.shorter.instruction, text: "a selection", maxTokens: 200)
            XCTFail("an unavailable model must throw")
        } catch let error as CleanupError {
            XCTAssertFalse(error.message.contains("a selection"), "nothing of the selection in an error")
        }
        XCTAssertTrue(flag.fired)
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
