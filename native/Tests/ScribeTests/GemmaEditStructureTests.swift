import MLXLMCommon
import XCTest

/// The edit prompt is a second chat layout beside the cleanup one; these pin it without a model.
final class GemmaEditStructureTests: XCTestCase {
    private let instruction = EditVerb.toSpanish.instruction

    func testEditChatIsSystemTwoFewShotPairsAndTheQuery() {
        let chat = GemmaBackend.buildEditChat(instruction: instruction, text: "hello there")
        XCTAssertEqual(chat.count, 1 + 2 * EditPrompt.fewShots.count + 1)
        XCTAssertEqual(chat.count, 6)
    }

    func testFirstMessageIsTheEditPromptNotTheCleanupOne() {
        let chat = GemmaBackend.buildEditChat(instruction: instruction, text: "hello there")
        XCTAssertEqual(chat[0].role, .system)
        XCTAssertEqual(chat[0].content, EditPrompt.systemPrompt)
        XCTAssertNotEqual(chat[0].content, CleanupPrompt.systemPrompt)
    }

    func testEveryUserTurnIsAnEditWrap() {
        let chat = GemmaBackend.buildEditChat(instruction: instruction, text: "the final text")
        let userTurns = chat.filter { $0.role == .user }
        XCTAssertEqual(userTurns.count, EditPrompt.fewShots.count + 1)
        for turn in userTurns {
            XCTAssertTrue(turn.content.hasPrefix("<instruction>\n"), "unwrapped user turn: \(turn.content)")
            XCTAssertTrue(turn.content.hasSuffix("\n</text>"), "unwrapped user turn: \(turn.content)")
            XCTAssertFalse(turn.content.contains("<transcript>"))
        }
    }

    func testFewShotPairsMatchEditPromptInOrderAndAreNotWrappedTwice() {
        let chat = GemmaBackend.buildEditChat(instruction: instruction, text: "the final text")
        for (index, pair) in EditPrompt.fewShots.enumerated() {
            XCTAssertEqual(chat[1 + index * 2].role, .user)
            XCTAssertEqual(chat[1 + index * 2].content, pair.0, "EditPrompt.fewShots inputs are already wrapped")
            XCTAssertEqual(chat[2 + index * 2].role, .assistant)
            XCTAssertEqual(chat[2 + index * 2].content, pair.1)
        }
    }

    func testLastMessageIsTheWrappedInstructionAndText() {
        let chat = GemmaBackend.buildEditChat(instruction: instruction, text: "the final text")
        let last = chat[chat.count - 1]
        XCTAssertEqual(last.role, .user)
        XCTAssertEqual(last.content, EditPrompt.wrap(instruction: instruction, text: "the final text"))
    }

    func testTheCleanupChatIsUntouched() {
        let chat = GemmaBackend.buildChat(for: "hello there", systemPrompt: CleanupPrompt.systemPrompt)
        XCTAssertEqual(chat.count, 8)
        XCTAssertEqual(chat[0].content, CleanupPrompt.systemPrompt)
        XCTAssertFalse(chat.contains { $0.content.contains("<instruction>") })
    }

    /// Two warm-up queries whose instructions open with the same words would pin the cached prefix to those words,
    /// and every other verb would miss it. The shared leading text must stop short of any verb's instruction.
    func testWarmupQueriesShareNothingBeyondTheInstructionTag() {
        let samples = GemmaBackend.editWarmupSamples
        XCTAssertEqual(samples.count, 2)
        let queries = samples.map { EditPrompt.wrap(instruction: $0.instruction, text: $0.text) }
        let shared = String(zip(queries[0], queries[1]).prefix(while: { $0 == $1 }).map { $0.0 })
        XCTAssertEqual(shared, "<instruction>\n")
        for verb in EditVerb.allCases {
            let query = EditPrompt.wrap(instruction: verb.instruction, text: "anything")
            XCTAssertTrue(query.hasPrefix(shared), "\(verb)")
        }
    }

    func testWarmupSamplesAreRealInstructionsInTwoLanguages() {
        let samples = GemmaBackend.editWarmupSamples
        XCTAssertTrue(EditVerb.allCases.map(\.instruction).contains(samples[0].instruction))
        XCTAssertTrue(EditVerb.allCases.map(\.instruction).contains(samples[1].instruction))
        XCTAssertNotEqual(samples[0].text, samples[1].text)
    }

    /// A tokenizer or template error can quote the prompt, and the prompt holds the user's selection. The Apple
    /// Intelligence edit path already reports the type alone; this backend must give the same guarantee.
    func testAnEditFailureCarriesTheErrorTypeAndNeverItsText() {
        struct Leaky: Error, CustomStringConvertible {
            var description: String { "template failed on: the confidential selection" }
        }
        let secret = "the confidential selection"

        let structured = GemmaBackend.editFailure(Leaky())
        XCTAssertFalse(structured.message.contains(secret))
        XCTAssertTrue(structured.message.contains("Leaky"), structured.message)

        let bridged = GemmaBackend.editFailure(
            NSError(domain: "x", code: 1, userInfo: [NSLocalizedDescriptionKey: secret]))
        XCTAssertFalse(bridged.message.contains(secret))
        XCTAssertTrue(bridged.message.hasPrefix("edit failed: "), bridged.message)
    }

    func testNothingIsWarmBeforeUse() {
        let backend = GemmaBackend()
        XCTAssertFalse(backend.isWarm)
        XCTAssertFalse(backend.isEditWarm)
        XCTAssertNil(backend.warmSystemPromptForTesting)
        XCTAssertTrue(backend.warmPrefixSlotsForTesting.isEmpty)
    }

    /// A model that cannot load is reported under the edit label, by type only: `LazyModel` logs a failed load from
    /// `preload()` alone, and an edit is the first caller when the user has never dictated.
    func testAnEditThatCannotLoadTheModelLogsTheErrorTypeAndNothingElse() async {
        let logs = Locked<[String]>([])
        let backend = GemmaBackend(
            customModelPath: "/nonexistent/\(UUID().uuidString)", onLog: { line in logs.mutate { $0.append(line) } })

        do {
            _ = try await backend.edit(instruction: "Translate it to Spanish.", text: "the confidential selection", maxTokens: 20)
            XCTFail("a model that is not there cannot edit")
        } catch let error as CleanupError {
            XCTAssertTrue(error.message.hasPrefix("edit failed: "), error.message)
            XCTAssertFalse(error.message.contains("confidential"))
        } catch {
            XCTFail("the failure must arrive as a CleanupError, got \(error)")
        }

        let loadLines = logs.value.filter { $0.hasPrefix("edit: model load failed: ") }
        XCTAssertEqual(loadLines.count, 1, "\(logs.value)")
        for line in logs.value {
            XCTAssertFalse(line.contains("confidential"), line)
            XCTAssertFalse(line.contains("Translate it"), line)
        }
    }
}
