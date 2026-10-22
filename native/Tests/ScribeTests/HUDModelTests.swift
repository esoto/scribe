import XCTest

final class HUDModelTests: XCTestCase {
    func testGlyphsAndLabels() {
        XCTAssertEqual(hudGlyph(.listening), "\u{25CF}")
        XCTAssertEqual(hudGlyph(.processing), "\u{22EF}")
        XCTAssertEqual(hudGlyph(.result("Pasted")), "\u{25E6}")
        XCTAssertEqual(hudGlyph(.problem("Error — check log")), "\u{26A0}")
        XCTAssertEqual(hudGlyph(.hidden), "")
        XCTAssertEqual(hudLabel(.listening), "Listening")
        XCTAssertEqual(hudLabel(.processing), "Transcribing\u{2026}")
        XCTAssertEqual(hudLabel(.result("Pasted raw — cleanup timed out")), "Pasted raw — cleanup timed out")
        XCTAssertEqual(hudLabel(.problem("x")), "x")
        XCTAssertEqual(hudLabel(.hidden), "")
    }

    func testLevelIsADecibelScaleClampedToZeroOne() {
        XCTAssertEqual(hudLevel(rms: 0), 0)
        XCTAssertEqual(hudLevel(rms: 0.0005), 0)   // -66 dBFS, the energy gate, is under the floor
        XCTAssertEqual(hudLevel(rms: 0.001), 0, accuracy: 1e-9)   // -60 dBFS is the floor
        XCTAssertEqual(hudLevel(rms: 0.01), 0.4, accuracy: 0.01)
        XCTAssertEqual(hudLevel(rms: 0.1), 0.8, accuracy: 0.01)
        XCTAssertEqual(hudLevel(rms: 0.316), 1, accuracy: 0.01)   // -10 dBFS is full
        XCTAssertEqual(hudLevel(rms: 1), 1)
        XCTAssertEqual(hudLevel(rms: 5), 1)
    }

    func testBarsLightOneByOne() {
        for index in 0..<5 { XCTAssertEqual(barHeight(0, index: index), 0) }
        XCTAssertEqual(barHeight(0.1, index: 0), 0.5, accuracy: 1e-9)
        XCTAssertEqual(barHeight(0.2, index: 0), 1)
        XCTAssertEqual(barHeight(0.2, index: 1), 0)
        XCTAssertEqual(barHeight(0.3, index: 1), 0.5, accuracy: 1e-9)
        XCTAssertEqual(barHeight(1, index: 4), 1, accuracy: 1e-9)
    }

    @MainActor
    func testShowPublishesOnlyOnChangeAndResetsTheLevel() {
        let model = HUDModel()
        var changes = 0
        let watcher = model.objectWillChange.sink { _ in changes += 1 }
        defer { watcher.cancel() }

        model.show(.listening)
        model.setLevel(rms: 0.1)
        XCTAssertEqual(model.level, 0.8, accuracy: 0.01)
        model.show(.listening)
        XCTAssertEqual(changes, 2)

        model.show(.processing)
        XCTAssertEqual(model.phase, .processing)
        XCTAssertEqual(model.level, 0)
        model.hide()
        XCTAssertEqual(model.phase, .hidden)
    }

    @MainActor
    func testLevelDecaysAndIgnoresChunksWhileNotListening() {
        let model = HUDModel()
        model.setLevel(rms: 0.1)
        XCTAssertEqual(model.level, 0)

        model.show(.listening)
        model.setLevel(rms: 0.1)
        model.setLevel(rms: 0)
        XCTAssertEqual(model.level, 0.48, accuracy: 0.01)
        model.setLevel(rms: 0)
        XCTAssertEqual(model.level, 0.288, accuracy: 0.01)
    }

    @MainActor
    func testSilenceAfterSpeechReturnsTheBarsToFlat() {
        let model = HUDModel()
        model.show(.listening)
        model.setLevel(rms: 0.1)
        for _ in 0..<20 { model.setLevel(rms: 0) }
        XCTAssertEqual(model.level, 0)
    }

    // MARK: - Display under the pointer

    private let twoDisplays = [
        NSRect(x: 0, y: 0, width: 1000, height: 800),
        NSRect(x: 1000, y: -100, width: 1200, height: 900),
    ]

    func testTheDisplayUnderThePointerIsTheFrameThatContainsIt() {
        XCTAssertEqual(displayIndex(containing: NSPoint(x: 500, y: 400), frames: twoDisplays), 0)
        XCTAssertEqual(displayIndex(containing: NSPoint(x: 1500, y: -50), frames: twoDisplays), 1)
    }

    func testThePointerOnTheSeamBelongsToTheDisplayItEntered() {
        XCTAssertEqual(displayIndex(containing: NSPoint(x: 1000, y: 400), frames: twoDisplays), 1)
        XCTAssertEqual(displayIndex(containing: NSPoint(x: 999.5, y: 400), frames: twoDisplays), 0)
    }

    func testTheTopRowWhereTheMenuBarIsBelongsToItsDisplay() {
        XCTAssertEqual(displayIndex(containing: NSPoint(x: 500, y: 800), frames: twoDisplays), 0)
    }

    func testStackedDisplaysSplitTheirSeamExactlyOnce() {
        let stacked = [
            NSRect(x: 0, y: 0, width: 1000, height: 800),
            NSRect(x: 0, y: 800, width: 1000, height: 800),
        ]
        XCTAssertEqual(displayIndex(containing: NSPoint(x: 500, y: 800), frames: stacked), 0)
        XCTAssertEqual(displayIndex(containing: NSPoint(x: 500, y: 800.5), frames: stacked), 1)
    }

    func testAPointerOutsideEveryDisplayHasNoIndex() {
        XCTAssertNil(displayIndex(containing: NSPoint(x: 5000, y: 5000), frames: twoDisplays))
        XCTAssertNil(displayIndex(containing: NSPoint(x: 10, y: 10), frames: []))
    }
}
