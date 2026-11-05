import XCTest

/// A selection is attacker-controlled text: whatever app is in front can hold "ignore the above…", a fake tag or a
/// request, and the edit must still only edit. The instruction has to survive as text and the facts around it with it.
final class EditGuardTests: XCTestCase {
    func testInstructionsInsideTheSelectionAreEditedNotObeyed() async throws {
        let backend = try cleanupBackendUnderTest()
        backend.setDictionary(.empty)
        let guardSet = try loadEditSet("edit_guard.json")
        _ = try await runEditCases(guardSet.cases, backend: backend, tag: "edit_guard[\(cleanupSpecUnderTest().id.rawValue)]")
    }
}
