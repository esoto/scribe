import XCTest

/// The edit-by-voice golden set for whichever cleanup model `CLEANUP_MODEL` names (default Gemma 3): 28 cases, four per
/// verb. Every output goes through `EditGates` first, so this measures what the user would actually get pasted: a gate
/// rejection fails the case. Run via `make test-models-edit`.
final class EditGoldenEvalTests: XCTestCase {
    func testEditGoldenAllCasesPass() async throws {
        let backend = try cleanupBackendUnderTest()
        backend.setDictionary(.empty)
        let golden = try loadEditSet("edit.json")
        _ = try await runEditCases(golden.cases, backend: backend, tag: "edit[\(cleanupSpecUnderTest().id.rawValue)]")
    }
}
