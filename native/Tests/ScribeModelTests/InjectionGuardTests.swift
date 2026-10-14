import XCTest

/// Request-looking dictations must come back cleaned, not answered — scribe
/// pastes into whatever app has focus. One haiku case wasn't enough: a
/// quantization change alone flipped it for the same model (2026-10-10).
final class InjectionGuardTests: XCTestCase {
    func testRequestLookingDictationsAreCleanedNotAnswered() async throws {
        let backend = try cleanupBackendUnderTest()
        backend.setDictionary(.empty)
        let guardSet = try loadGoldenSet("injection_guard.json")
        _ = try await runGoldenCases(guardSet.cases, backend: backend, tag: "guard[\(cleanupSpecUnderTest().id.rawValue)]")
    }
}
