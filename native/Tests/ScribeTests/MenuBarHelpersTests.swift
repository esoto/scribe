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
        XCTAssertEqual(menuBarGlyph(.idle, progress: nil), glyphFor(.idle))
        XCTAssertEqual(menuBarGlyph(.idle, progress: 0.42), "42%")
        XCTAssertEqual(menuBarGlyph(.idle, progress: 0), "0%")
        // 1.0 means the download finished and the load phase began.
        XCTAssertEqual(menuBarGlyph(.idle, progress: 1.0), glyphFor(.idle))
        // A live pipeline state must win over a background download.
        XCTAssertEqual(menuBarGlyph(.recording, progress: 0.5), glyphFor(.recording))
        XCTAssertEqual(menuBarGlyph(.error, progress: 0.5), glyphFor(.error))
    }

    func testTruncate() {
        XCTAssertEqual(truncateLabel("corto"), "corto")
        let long = String(repeating: "x", count: 60)
        XCTAssertEqual(truncateLabel(long), String(repeating: "x", count: 39) + "\u{2026}")
    }
}
