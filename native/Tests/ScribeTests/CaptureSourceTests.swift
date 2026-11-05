import XCTest

/// Whether the microphone the engine is on is the one the person chose, and the words that say so.
final class CaptureSourceTests: XCTestCase {
    private let usb = BoundInput(uid: "usb", name: "USB Mic")
    private let headset = BoundInput(uid: "headset", name: "Headset")

    func testAnEngineOnTheChosenMicrophoneMatches() {
        let source = CaptureSource(bound: usb, preferredUID: "usb", defaultUID: "builtin")
        XCTAssertEqual(source, CaptureSource(name: "USB Mic", matchesSelection: true))
    }

    func testAnEngineOnAnotherMicrophoneThanTheChosenOneDoesNotMatch() {
        let source = CaptureSource(bound: headset, preferredUID: "usb", defaultUID: "headset")
        XCTAssertEqual(source, CaptureSource(name: "Headset", matchesSelection: false))
    }

    func testNoChoiceMatchesWhileTheEngineIsOnTheSystemDefault() {
        let source = CaptureSource(bound: usb, preferredUID: nil, defaultUID: "usb")
        XCTAssertTrue(source.matchesSelection)
    }

    func testNoChoiceDoesNotMatchWhenTheEngineIsOffTheSystemDefault() {
        let source = CaptureSource(bound: headset, preferredUID: nil, defaultUID: "usb")
        XCTAssertFalse(source.matchesSelection)
    }

    func testNoChoiceCannotBeWrongWhenTheSystemDefaultCannotBeRead() {
        let source = CaptureSource(bound: headset, preferredUID: nil, defaultUID: nil)
        XCTAssertTrue(source.matchesSelection)
    }

    func testAChoiceIsJudgedAgainstItselfNotAgainstTheSystemDefault() {
        let source = CaptureSource(bound: usb, preferredUID: "usb", defaultUID: nil)
        XCTAssertTrue(source.matchesSelection)
    }

    func testCaptionBeforeAnyRecordingSaysSo() {
        XCTAssertEqual(CaptureSource.caption(nil), "Not recorded yet")
    }

    func testCaptionNamesTheMicrophone() {
        XCTAssertEqual(
            CaptureSource.caption(CaptureSource(name: "USB Mic", matchesSelection: true)),
            "Capturing from: USB Mic")
    }

    func testCaptionSaysWhenItIsNotTheChosenMicrophone() {
        XCTAssertEqual(
            CaptureSource.caption(CaptureSource(name: "Headset", matchesSelection: false)),
            "Capturing from: Headset — not the microphone you chose")
    }
}
