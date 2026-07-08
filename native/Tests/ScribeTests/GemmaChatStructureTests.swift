import MLXLMCommon
import XCTest
@testable import Scribe

/// Regression guard for the exact 8/10-message bug fixed in Task 15
/// (see GemmaBackend.buildChat's doc comment): leaving the few-shot user
/// turns unwrapped weakened the "never translate" instruction because only
/// the final query carried the <transcript> markup the examples never
/// demonstrated. `GemmaBackend.buildChat(for:)` is the pure, MLX-session-free
/// seam these assertions drive directly.
final class GemmaChatStructureTests: XCTestCase {
    func testBuildChatProducesExactlyEightMessages() {
        let chat = GemmaBackend.buildChat(for: "hello there")
        // 1 system + 3 few-shot pairs (2 messages each) + 1 final user query.
        XCTAssertEqual(chat.count, 1 + 2 * CleanupPrompt.fewShots.count + 1)
        XCTAssertEqual(chat.count, 8)
    }

    func testFirstMessageIsSystemPrompt() {
        let chat = GemmaBackend.buildChat(for: "hello there")
        XCTAssertEqual(chat[0].role, .system)
        XCTAssertEqual(chat[0].content, CleanupPrompt.systemPrompt)
    }

    func testEveryUserTurnIsWrappedInTranscriptTags() {
        // Covers the exact regression: ALL user turns — the 3 few-shot user
        // turns AND the final query — must be wrapped, not just the query.
        let chat = GemmaBackend.buildChat(for: "the final query")
        let userTurns = chat.filter { $0.role == .user }
        XCTAssertEqual(userTurns.count, CleanupPrompt.fewShots.count + 1)
        for turn in userTurns {
            XCTAssertTrue(turn.content.hasPrefix("<transcript>\n"), "unwrapped user turn: \(turn.content)")
            XCTAssertTrue(turn.content.hasSuffix("\n</transcript>"), "unwrapped user turn: \(turn.content)")
        }
    }

    func testFewShotPairsMatchCleanupPromptInOrder() {
        let chat = GemmaBackend.buildChat(for: "the final query")
        // messages[1...6] are the 3 few-shot (user, assistant) pairs, in order.
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
        let chat = GemmaBackend.buildChat(for: "the final query")
        let last = chat[chat.count - 1]
        XCTAssertEqual(last.role, .user)
        XCTAssertEqual(last.content, CleanupPrompt.wrap("the final query"))
    }
}
