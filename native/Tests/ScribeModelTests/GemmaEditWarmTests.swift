import XCTest

/// The edit prompt keeps its own warm prefix beside the cleanup one: `preload()` builds only cleanup's, the first
/// edit builds the other, and `unload()` drops both with the model.
final class GemmaEditWarmTests: XCTestCase {
    /// `onLog` runs on the model's queue, so the collected lines need their own lock.
    private final class LogLines: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []

        func append(_ line: String) { lock.withLock { storage.append(line) } }
        var lines: [String] { lock.withLock { storage } }
    }

    /// The warm-up samples were chosen so one cached prefix serves every verb on the SAFE tier. This is the check
    /// that holds at token level, which the model-free structure tests cannot give.
    func testEveryVerbHitsTheWarmEditPrefixAndTheEditSlotStaysOnTheSafeTier() async throws {
        let log = LogLines()
        let backend = GemmaBackend(onLog: { log.append($0) })
        let selection = "i has a apple and two orange, the meeting is on monday at noon"

        for verb in EditVerb.allCases {
            let maxTokens = EditPrompt.maxTokens(verb: verb, inputTokens: selection.count / 4)
            let edited = try await backend.edit(
                instruction: EditPrompt.instruction(verb: verb, selection: selection), text: selection, maxTokens: maxTokens)
            XCTAssertFalse(edited.isEmpty, "\(verb)")
        }

        let lines = log.lines
        let ready = lines.filter { $0.hasPrefix("edit: warm prefix ready") }
        XCTAssertEqual(ready.count, 1, "one warm-up serves every verb: \(lines)")
        XCTAssertTrue(ready.first?.contains("fastPath=false") ?? false, "an edit never takes the FAST tier: \(ready)")
        XCTAssertEqual(
            lines.filter { $0.hasPrefix("edit: prefix mismatch") }, [],
            "a verb whose instruction runs into the cached prefix misses it and pays an uncached edit")
        XCTAssertEqual(
            lines.filter { $0.hasPrefix("edit: prefix-reuse disabled") || $0.hasPrefix("edit: prefix warm-up failed") },
            [])
        XCTAssertFalse(lines.contains { $0.contains(selection) }, "nothing of a selection reaches a log line")
        for verb in EditVerb.allCases {
            XCTAssertFalse(lines.contains { $0.contains(verb.instruction) }, "\(verb)")
        }
    }

    func testEditWarmsItsOwnPrefixOnFirstUseAndUnloadDropsBoth() async throws {
        let backend = GemmaBackend()

        await backend.preload()
        XCTAssertTrue(backend.isWarm)
        XCTAssertFalse(backend.isEditWarm, "preload() warms cleanup only, so a dictation after launch pays nothing new")
        XCTAssertEqual(backend.warmPrefixSlotsForTesting, [CleanupPrompt.systemPrompt])

        let edited = try await backend.edit(
            instruction: EditVerb.fixGrammar.instruction, text: "i has a apple and two orange", maxTokens: 200)
        XCTAssertFalse(edited.isEmpty)
        XCTAssertTrue(backend.isEditWarm)
        XCTAssertTrue(backend.isWarm, "an edit must not evict the cleanup prefix")
        XCTAssertEqual(backend.warmSystemPromptForTesting, CleanupPrompt.systemPrompt)
        XCTAssertEqual(Set(backend.warmPrefixSlotsForTesting), [CleanupPrompt.systemPrompt, EditPrompt.systemPrompt])

        let cleaned = try await backend.clean("so um the report is uh ready now")
        XCTAssertFalse(cleaned.isEmpty)

        await backend.unload()
        XCTAssertFalse(backend.isWarm)
        XCTAssertFalse(backend.isEditWarm)
        XCTAssertTrue(backend.warmPrefixSlotsForTesting.isEmpty)
    }
}
