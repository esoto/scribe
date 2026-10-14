import MLXLMCommon
import XCTest

/// Guards the 8-message chat layout: few-shot user turns must be wrapped in <transcript> too.
final class GemmaChatStructureTests: XCTestCase {
    func testBuildChatProducesExactlyEightMessages() {
        let chat = GemmaBackend.buildChat(for: "hello there", systemPrompt: CleanupPrompt.systemPrompt)
        XCTAssertEqual(chat.count, 1 + 2 * CleanupPrompt.fewShots.count + 1)
        XCTAssertEqual(chat.count, 8)
    }

    func testFirstMessageIsSystemPrompt() {
        let chat = GemmaBackend.buildChat(for: "hello there", systemPrompt: CleanupPrompt.systemPrompt)
        XCTAssertEqual(chat[0].role, .system)
        XCTAssertEqual(chat[0].content, CleanupPrompt.systemPrompt)
    }

    func testEveryUserTurnIsWrappedInTranscriptTags() {
        // Every user turn, few-shot and final query alike, must be wrapped.
        let chat = GemmaBackend.buildChat(for: "the final query", systemPrompt: CleanupPrompt.systemPrompt)
        let userTurns = chat.filter { $0.role == .user }
        XCTAssertEqual(userTurns.count, CleanupPrompt.fewShots.count + 1)
        for turn in userTurns {
            XCTAssertTrue(turn.content.hasPrefix("<transcript>\n"), "unwrapped user turn: \(turn.content)")
            XCTAssertTrue(turn.content.hasSuffix("\n</transcript>"), "unwrapped user turn: \(turn.content)")
        }
    }

    func testFewShotPairsMatchCleanupPromptInOrder() {
        let chat = GemmaBackend.buildChat(for: "the final query", systemPrompt: CleanupPrompt.systemPrompt)
        for (index, pair) in CleanupPrompt.fewShots.enumerated() {
            let userMessage = chat[1 + index * 2]
            let assistantMessage = chat[2 + index * 2]

            XCTAssertEqual(userMessage.role, .user)
            XCTAssertEqual(userMessage.content, CleanupPrompt.wrap(pair.0))

            XCTAssertEqual(assistantMessage.role, .assistant)
            XCTAssertEqual(assistantMessage.content, pair.1)
        }
    }

    func testLastMessageIsTheWrappedQuery() {
        let chat = GemmaBackend.buildChat(for: "the final query", systemPrompt: CleanupPrompt.systemPrompt)
        let last = chat[chat.count - 1]
        XCTAssertEqual(last.role, .user)
        XCTAssertEqual(last.content, CleanupPrompt.wrap("the final query"))
    }

    func testSystemMessageIsExactlyTheProvidedPrompt() {
        // The warm-prefix cache is keyed on the prompt string; pass it through verbatim.
        let prompt = CleanupPrompt.systemPrompt(
            with: DictionarySnapshot(
                pairs: [
                    ReplacementPair(
                        original: "camel", replacement: "kamal",
                        addedAt: Date(timeIntervalSince1970: 0))
                ],
                glossary: ["MLX", "Parakeet"]))
        let chat = GemmaBackend.buildChat(for: "hello", systemPrompt: prompt)
        XCTAssertEqual(chat[0].role, .system)
        XCTAssertEqual(chat[0].content, prompt)
        XCTAssertTrue(chat[0].content.contains("\"MLX\", \"Parakeet\""))
        XCTAssertFalse(chat[0].content.contains("kamal"), "pairs never reach the prompt")
    }
}
