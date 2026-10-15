import XCTest

// Sources/Scribe compiles into this module; importing the app module too makes PipelineState ambiguous.

final class MenuBarHelpersTests: XCTestCase {
    func testGlyphs() {
        XCTAssertEqual(glyphFor(.idle), "\u{25E6}")
        XCTAssertEqual(glyphFor(.recording), "\u{25CF}")
        XCTAssertEqual(glyphFor(.processing), "\u{22EF}")
        XCTAssertEqual(glyphFor(.error), "\u{26A0}")
    }

    func testMenuBarGlyphShowsDownloadProgressOnlyWhileIdle() {
        XCTAssertEqual(menuBarGlyph(.idle, progress: nil, needsAttention: false), glyphFor(.idle))
        XCTAssertEqual(menuBarGlyph(.idle, progress: 0.42, needsAttention: false), "42%")
        XCTAssertEqual(menuBarGlyph(.idle, progress: 0, needsAttention: false), "0%")
        // 1.0 means the download finished and the load phase began.
        XCTAssertEqual(menuBarGlyph(.idle, progress: 1.0, needsAttention: false), glyphFor(.idle))
        // A live pipeline state must win over a background download.
        XCTAssertEqual(menuBarGlyph(.recording, progress: 0.5, needsAttention: false), glyphFor(.recording))
        XCTAssertEqual(menuBarGlyph(.error, progress: 0.5, needsAttention: false), glyphFor(.error))
    }

    func testTruncate() {
        XCTAssertEqual(truncateLabel("corto"), "corto")
        let long = String(repeating: "x", count: 60)
        XCTAssertEqual(truncateLabel(long), String(repeating: "x", count: 39) + "\u{2026}")
    }

    func testMenuStatusTextPrefersTheSttDownloadWhileIdleOrTranscribing() {
        let dl = "Downloading Parakeet Ultra… 42%"
        XCTAssertEqual(menuStatusText(.idle, sttDownload: dl, cleanupStatus: "Loading Gemma…", attention: nil), dl)
        XCTAssertEqual(menuStatusText(.idle, sttDownload: nil, cleanupStatus: "Loading Gemma…", attention: nil), "Loading Gemma…")
        XCTAssertNil(menuStatusText(.idle, sttDownload: nil, cleanupStatus: nil, attention: nil))
        XCTAssertEqual(menuStatusText(.processing, sttDownload: dl, cleanupStatus: nil, attention: nil), dl)
        XCTAssertEqual(menuStatusText(.processing, sttDownload: nil, cleanupStatus: nil, attention: nil), "Transcribing…")
        XCTAssertEqual(menuStatusText(.recording, sttDownload: dl, cleanupStatus: nil, attention: nil), "Recording…")
        XCTAssertEqual(menuStatusText(.error, sttDownload: dl, cleanupStatus: nil, attention: nil), "Error — check log")
    }

    func testMenuBarGlyphWarnsOnlyWhileIdleAndAttentionIsNeeded() {
        XCTAssertEqual(menuBarGlyph(.idle, progress: nil, needsAttention: true), "\u{26A0}")
        // Attention beats a background download: a missing permission is the thing to fix first.
        XCTAssertEqual(menuBarGlyph(.idle, progress: 0.42, needsAttention: true), "\u{26A0}")
        XCTAssertEqual(menuBarGlyph(.recording, progress: nil, needsAttention: true), glyphFor(.recording))
        XCTAssertEqual(menuBarGlyph(.processing, progress: nil, needsAttention: true), glyphFor(.processing))
        XCTAssertEqual(menuBarGlyph(.error, progress: nil, needsAttention: true), glyphFor(.error))
    }

    func testMenuStatusTextShowsAttentionOnlyWhileIdle() {
        let warning = "Accessibility is off — open Setup / Doctor…"
        let dl = "Downloading Parakeet Ultra… 42%"
        XCTAssertEqual(menuStatusText(.idle, sttDownload: dl, cleanupStatus: "Loading Gemma…", attention: warning), warning)
        XCTAssertEqual(menuStatusText(.idle, sttDownload: nil, cleanupStatus: nil, attention: warning), warning)
        XCTAssertEqual(menuStatusText(.recording, sttDownload: nil, cleanupStatus: nil, attention: warning), "Recording…")
        XCTAssertEqual(menuStatusText(.processing, sttDownload: nil, cleanupStatus: nil, attention: warning), "Transcribing…")
        XCTAssertEqual(menuStatusText(.error, sttDownload: nil, cleanupStatus: nil, attention: warning), "Error — check log")
    }

    func testAttentionTextIsNilWhenEveryPermissionIsGranted() {
        XCTAssertNil(attentionText(for: GrantStatus(microphone: true, accessibility: true, inputMonitoring: true)))
    }

    func testAttentionTextNamesTheMissingPermission() {
        XCTAssertEqual(
            attentionText(for: GrantStatus(microphone: true, accessibility: false, inputMonitoring: true)),
            "Accessibility is off — open Setup / Doctor…")
        XCTAssertEqual(
            attentionText(for: GrantStatus(microphone: false, accessibility: true, inputMonitoring: true)),
            "Microphone is off — open Setup / Doctor…")
        XCTAssertEqual(
            attentionText(for: GrantStatus(microphone: true, accessibility: true, inputMonitoring: false)),
            "Input Monitoring is off — open Setup / Doctor…")
    }

    func testAttentionTextReportsTheFirstMissingPermissionInSetupOrder() {
        XCTAssertEqual(
            attentionText(for: GrantStatus(microphone: false, accessibility: false, inputMonitoring: false)),
            "Microphone is off — open Setup / Doctor…")
        XCTAssertEqual(
            attentionText(for: GrantStatus(microphone: true, accessibility: false, inputMonitoring: false)),
            "Accessibility is off — open Setup / Doctor…")
    }
}
