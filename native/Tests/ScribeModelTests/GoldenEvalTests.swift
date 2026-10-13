import XCTest

/// **THE PARITY GATE**, for whichever cleanup model `CLEANUP_MODEL` names
/// (default Gemma 3). Every case must pass before that model's prompt or
/// weights change — and before it can become the default.
final class GoldenEvalTests: XCTestCase {
    func testGoldenEvalAllCasesPass() async throws {
        let backend = try cleanupBackendUnderTest()
        backend.setDictionary(.empty)
        let golden = try loadGoldenSet("golden.json")
        _ = try await runGoldenCases(golden.cases, backend: backend, tag: "golden[\(cleanupSpecUnderTest().id.rawValue)]")
    }
}
