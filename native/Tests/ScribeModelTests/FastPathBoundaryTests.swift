import XCTest

/// Boundary tests for the prefix-reuse fast path: inputs whose tokens may not join cleanly with the cached prefix.
final class FastPathBoundaryTests: XCTestCase {
    static let gemma = GemmaBackend()

    /// Leading inverted question mark, a risky boundary character.
    func testCleanHandlesLeadingInvertedQuestionMark() async throws {
        let cleaned = try await Self.gemma.clean(
            "¿crees que deberíamos eh enviarlo el viernes?")
        let normalized = Gates.normalize(cleaned).lowercased()

        XCTAssertTrue(normalized.contains("deberíamos"), "actual: \(cleaned)")
        XCTAssertTrue(normalized.contains("viernes"), "actual: \(cleaned)")
        XCTAssertFalse(normalized.contains(" eh "), "filler word leaked: \(cleaned)")
        XCTAssertLessThan(cleaned.count, 200, "suspiciously long output, possible runaway: \(cleaned)")
    }

    /// Leading bare digit, a risky boundary character.
    func testCleanHandlesLeadingDigit() async throws {
        let cleaned = try await Self.gemma.clean(
            "2 things we need um to review before friday")
        let normalized = Gates.normalize(cleaned).lowercased()

        // The model may spell the digit out ("Two"); accept either form.
        XCTAssertTrue(
            normalized.contains("2") || normalized.contains("two"),
            "actual: \(cleaned)")
        XCTAssertTrue(normalized.contains("friday"), "actual: \(cleaned)")
        XCTAssertFalse(normalized.contains(" um "), "filler word leaked: \(cleaned)")
        XCTAssertLessThan(cleaned.count, 200, "suspiciously long output, possible runaway: \(cleaned)")
    }

    /// Very short utterance, possibly shorter than `wrapOverlap`.
    func testCleanHandlesVeryShortSingleWordUtterance() async throws {
        let cleaned = try await Self.gemma.clean("sí")
        let normalized = Gates.normalize(cleaned).lowercased()

        XCTAssertFalse(normalized.isEmpty, "expected non-empty cleaned output for a short utterance")
        XCTAssertLessThan(cleaned.count, 200, "suspiciously long output, possible runaway: \(cleaned)")
    }
}
