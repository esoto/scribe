import XCTest

// `Sources/Scribe` compiles directly into the `ScribeTests` module (see
// project.yml), so `glyphFor`/`truncateLabel`/`PipelineState` are already
// visible here without an import. `@testable import Scribe` is deliberately
// omitted: it would additionally pull in the separately built `Scribe` app
// module's own copy of these same top-level symbols, and `glyphFor(.idle)`
// below needs to pick a single overload — with both copies in scope, the
// call becomes genuinely ambiguous (two distinct `PipelineState` types, one
// per module, both offering a `.idle` case).

// Ported 1:1 from tests/test_menubar_helpers.py.
final class MenuBarHelpersTests: XCTestCase {
    func testGlyphs() {
        XCTAssertEqual(glyphFor(.idle), "\u{25E6}")
        XCTAssertEqual(glyphFor(.recording), "\u{25CF}")
        XCTAssertEqual(glyphFor(.processing), "\u{22EF}")
        XCTAssertEqual(glyphFor(.error), "\u{26A0}")
    }

    func testTruncate() {
        XCTAssertEqual(truncateLabel("corto"), "corto")
        let long = String(repeating: "x", count: 60)
        XCTAssertEqual(truncateLabel(long), String(repeating: "x", count: 39) + "\u{2026}")
    }
}
