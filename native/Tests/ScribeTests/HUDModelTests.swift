import XCTest

final class HUDModelTests: XCTestCase {
    func testGlyphsAndLabels() {
        XCTAssertEqual(hudGlyph(.listening), "\u{25CF}")
        XCTAssertEqual(hudGlyph(.processing), "\u{22EF}")
        XCTAssertEqual(hudGlyph(.result("Pasted")), "\u{25E6}")
        XCTAssertEqual(hudGlyph(.hidden), "")
        XCTAssertEqual(hudLabel(.listening), "Listening")
        XCTAssertEqual(hudLabel(.processing), "Transcribing\u{2026}")
        XCTAssertEqual(hudLabel(.result("Pasted raw — cleanup timed out")), "Pasted raw — cleanup timed out")
        XCTAssertEqual(hudLabel(.hidden), "")
    }

    func testLevelIsADecibelScaleClampedToZeroOne() {
        XCTAssertEqual(hudLevel(rms: 0), 0)
        XCTAssertEqual(hudLevel(rms: 0.0005), 0)   // below -50 dBFS: the energy gate's idea of silence
        XCTAssertEqual(hudLevel(rms: 0.01), 0.2, accuracy: 0.01)
        XCTAssertEqual(hudLevel(rms: 0.1), 0.6, accuracy: 0.01)
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
        XCTAssertEqual(model.level, 0.6, accuracy: 0.01)
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
        XCTAssertEqual(model.level, 0.36, accuracy: 0.01)
        model.setLevel(rms: 0)
        XCTAssertEqual(model.level, 0.216, accuracy: 0.01)
    }
}
