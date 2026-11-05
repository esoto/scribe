import XCTest

/// Whether the microphone the engine is on is the one the person chose, and the words that say so.
final class CaptureSourceTests: XCTestCase {
    private let usb = BoundInput(uid: "usb", name: "USB Mic")
    private let headset = BoundInput(uid: "headset", name: "Headset")
    private let builtIn = BoundInput(uid: "builtin", name: "MacBook Pro Microphone")
    private let aggregate = BoundInput(uid: "CADefaultDeviceAggregate-4242-0", name: "CADefaultDeviceAggregate-4242-0")

    private func source(_ name: String, _ matches: Bool) -> CaptureStatus {
        .source(CaptureSource(name: name, matchesSelection: matches))
    }

    // MARK: - Where the engine is

    func testAnEngineOnTheChosenMicrophoneMatches() {
        let status = CaptureStatus(bound: usb, preferredUID: "usb", defaultInput: builtIn)
        XCTAssertEqual(status, source("USB Mic", true))
    }

    func testAnEngineOnAnotherMicrophoneThanTheChosenOneDoesNotMatch() {
        let status = CaptureStatus(bound: headset, preferredUID: "usb", defaultInput: headset)
        XCTAssertEqual(status, source("Headset", false))
    }

    func testNoChoiceMatchesWhileTheEngineIsOnTheSystemDefault() {
        let status = CaptureStatus(bound: usb, preferredUID: nil, defaultInput: usb)
        XCTAssertEqual(status, source("USB Mic", true))
    }

    func testNoChoiceDoesNotMatchWhenTheEngineIsOffTheSystemDefault() {
        let status = CaptureStatus(bound: headset, preferredUID: nil, defaultInput: usb)
        XCTAssertEqual(status, source("Headset", false), "a real device is named as it is, never as the default")
    }

    func testNoChoiceCannotBeWrongWhenTheSystemDefaultCannotBeRead() {
        let status = CaptureStatus(bound: headset, preferredUID: nil, defaultInput: nil)
        XCTAssertEqual(status, source("Headset", true))
    }

    func testAChoiceIsJudgedAgainstItselfNotAgainstTheSystemDefault() {
        let status = CaptureStatus(bound: usb, preferredUID: "usb", defaultInput: nil)
        XCTAssertEqual(status, source("USB Mic", true))
    }

    func testAnEngineWhoseInputCannotBeReadIsUnknownNotUnrecorded() {
        XCTAssertEqual(CaptureStatus(bound: nil, preferredUID: "usb", defaultInput: builtIn), .unknown)
        XCTAssertEqual(CaptureStatus(bound: nil, preferredUID: nil, defaultInput: nil), .unknown)
    }

    // MARK: - CoreAudio's default-device aggregate

    func testTheDefaultAggregateIsTheSystemDefaultInputWhenNoMicrophoneIsChosen() {
        let status = CaptureStatus(bound: aggregate, preferredUID: nil, defaultInput: builtIn)
        XCTAssertEqual(status, source("MacBook Pro Microphone", true))
    }

    func testTheDefaultAggregateStandsForTheDefaultInputWhenThatIsTheChosenMicrophone() {
        let status = CaptureStatus(bound: aggregate, preferredUID: "builtin", defaultInput: builtIn)
        XCTAssertEqual(status, source("MacBook Pro Microphone", true))
    }

    func testTheDefaultAggregateIsNotTheChosenMicrophoneWhenTheDefaultIsAnotherOne() {
        let status = CaptureStatus(bound: aggregate, preferredUID: "usb", defaultInput: builtIn)
        XCTAssertEqual(status, source("MacBook Pro Microphone", false), "named after the default, not the aggregate")
    }

    func testTheDefaultAggregateWithoutAReadableDefaultIsUnknownRatherThanNamedAfterItself() {
        XCTAssertEqual(CaptureStatus(bound: aggregate, preferredUID: nil, defaultInput: nil), .unknown)
    }

    // MARK: - The words

    func testCaptionBeforeAnyRecordingSaysSo() {
        XCTAssertEqual(CaptureStatus.notRecordedYet.caption, "Not recorded yet")
    }

    func testCaptionSaysWhenTheInputCouldNotBeRead() {
        XCTAssertEqual(CaptureStatus.unknown.caption, "Capturing from: unknown — the input could not be read")
    }

    func testCaptionNamesTheMicrophone() {
        XCTAssertEqual(source("USB Mic", true).caption, "Capturing from: USB Mic")
    }

    func testCaptionSaysWhenItIsNotTheChosenMicrophone() {
        XCTAssertEqual(
            source("Headset", false).caption, "Capturing from: Headset — not the microphone you chose")
    }

    func testOnlyAnEngineOnAnotherMicrophoneIsAMismatch() {
        XCTAssertTrue(source("Headset", false).isMismatch)
        XCTAssertFalse(source("USB Mic", true).isMismatch)
        XCTAssertFalse(CaptureStatus.unknown.isMismatch)
        XCTAssertFalse(CaptureStatus.notRecordedYet.isMismatch)
    }
}
