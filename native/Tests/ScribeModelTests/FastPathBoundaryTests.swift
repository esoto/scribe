import XCTest
@testable import Scribe

/// Regression coverage for the FAST-tier per-call boundary guard added to
/// `GemmaBackend.generateCleaned` (see the adversarial-review fix for the
/// prefix-reuse optimization, native/.superpowers/sdd/cleanup-perf-report.md
/// "Prompt-prefix KV-cache reuse"). BPE tokenization at the fixed-prefix /
/// incremental-content JOIN is not guaranteed concatenative for every input
/// — a leading digit, a leading Spanish "¿"/"¡", a very short single-word
/// utterance, or a leading emoji could in principle tokenize the shared
/// `<start_of_turn>user\n<transcript>\n` open-wrap text differently than the
/// two EN/ES warm-up samples did, which would silently corrupt the prompt
/// if the fixed `wrapOverlap` strip were trusted unconditionally.
///
/// These inputs specifically target that JOIN boundary (both start with the
/// exact character classes called out as risky) and run through the real,
/// unmodified `clean()` path end-to-end — exercising whichever tier
/// (FAST-with-guard-passing, or the guard's fallback to
/// `runFreshGeneration`) the guard actually selects for this input, on this
/// tokenizer, today. Either way the assertions below only pass if the
/// prompt fed to the model was correct: a corrupted prefix/content join
/// would either produce garbled or off-topic output (failing the content
/// assertions) or a runaway generation that never finds `<end_of_turn>`
/// (failing the length assertion — see GemmaBackend.swift's
/// `extraEOSTokens` doc comment for why a broken prompt/stop-token setup
/// historically ran to the token ceiling instead of stopping quickly).
///
/// `gemma` is a fresh instance (not shared with `GoldenEvalTests`) so this
/// suite exercises the FULL lazy warm-up + parity-gate path itself, not a
/// pre-warmed backend.
final class FastPathBoundaryTests: XCTestCase {
    static let gemma = GemmaBackend()

    /// Spanish input starting with an inverted question mark — one of the
    /// C1 risk inputs (a leading punctuation character with no ASCII
    /// equivalent, unlike English's opening characters).
    func testCleanHandlesLeadingInvertedQuestionMark() async throws {
        let cleaned = try await Self.gemma.clean(
            "¿crees que deberíamos eh enviarlo el viernes?")
        let normalized = Gates.normalize(cleaned).lowercased()

        XCTAssertTrue(normalized.contains("deberíamos"), "actual: \(cleaned)")
        XCTAssertTrue(normalized.contains("viernes"), "actual: \(cleaned)")
        XCTAssertFalse(normalized.contains(" eh "), "filler word leaked: \(cleaned)")
        // A corrupted prefix/content join (or the pre-Task-16 missing-EOS
        // bug) manifests as a runaway generation that never stops cleanly —
        // guard against that regressing silently by bounding output length
        // instead of asserting only content substrings.
        XCTAssertLessThan(cleaned.count, 200, "suspiciously long output, possible runaway: \(cleaned)")
    }

    /// English input starting with a bare digit — the other explicitly
    /// called-out C1 risk input.
    func testCleanHandlesLeadingDigit() async throws {
        let cleaned = try await Self.gemma.clean(
            "2 things we need um to review before friday")
        let normalized = Gates.normalize(cleaned).lowercased()

        // The model may legitimately spell the leading digit out ("Two")
        // as part of ordinary cleanup — that's not a boundary corruption,
        // so accept either form. What this test guards against is a
        // corrupted/garbled prompt from a bad boundary strip, not the
        // model's stylistic digit-vs-word choice.
        XCTAssertTrue(
            normalized.contains("2") || normalized.contains("two"),
            "actual: \(cleaned)")
        XCTAssertTrue(normalized.contains("friday"), "actual: \(cleaned)")
        XCTAssertFalse(normalized.contains(" um "), "filler word leaked: \(cleaned)")
        XCTAssertLessThan(cleaned.count, 200, "suspiciously long output, possible runaway: \(cleaned)")
    }

    /// A very short, single-word utterance — the third C1 risk case (fewer
    /// tokens than `wrapOverlap` is possible here, which is also what the
    /// existing `guard !tokens.isEmpty` in `generateCleaned` defends
    /// against separately).
    func testCleanHandlesVeryShortSingleWordUtterance() async throws {
        let cleaned = try await Self.gemma.clean("sí")
        let normalized = Gates.normalize(cleaned).lowercased()

        XCTAssertFalse(normalized.isEmpty, "expected non-empty cleaned output for a short utterance")
        XCTAssertLessThan(cleaned.count, 200, "suspiciously long output, possible runaway: \(cleaned)")
    }
}
