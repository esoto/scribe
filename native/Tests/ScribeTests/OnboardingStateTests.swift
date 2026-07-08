import XCTest
@testable import Scribe

final class OnboardingStateTests: XCTestCase {
    // MARK: - missing(_:)

    func testMissingAllFalse() {
        let status = GrantStatus(microphone: false, accessibility: false, inputMonitoring: false)
        let result = OnboardingState.missing(status)
        XCTAssertEqual(result, [.microphone, .accessibility, .inputMonitoring])
    }

    func testMissingMicrophoneOnly() {
        let status = GrantStatus(microphone: false, accessibility: true, inputMonitoring: true)
        let result = OnboardingState.missing(status)
        XCTAssertEqual(result, [.microphone])
    }

    func testMissingAccessibilityOnly() {
        let status = GrantStatus(microphone: true, accessibility: false, inputMonitoring: true)
        let result = OnboardingState.missing(status)
        XCTAssertEqual(result, [.accessibility])
    }

    func testMissingInputMonitoringOnly() {
        let status = GrantStatus(microphone: true, accessibility: true, inputMonitoring: false)
        let result = OnboardingState.missing(status)
        XCTAssertEqual(result, [.inputMonitoring])
    }

    func testMissingMicrophoneAndAccessibility() {
        let status = GrantStatus(microphone: false, accessibility: false, inputMonitoring: true)
        let result = OnboardingState.missing(status)
        XCTAssertEqual(result, [.microphone, .accessibility])
    }

    func testMissingNone() {
        let status = GrantStatus(microphone: true, accessibility: true, inputMonitoring: true)
        let result = OnboardingState.missing(status)
        XCTAssertEqual(result, [])
    }

    // MARK: - nextStep(_:)

    func testNextStepAllFalse() {
        let status = GrantStatus(microphone: false, accessibility: false, inputMonitoring: false)
        let result = OnboardingState.nextStep(status)
        XCTAssertEqual(result, .request(.microphone))
    }

    func testNextStepMicrophoneOnly() {
        let status = GrantStatus(microphone: true, accessibility: false, inputMonitoring: false)
        let result = OnboardingState.nextStep(status)
        XCTAssertEqual(result, .request(.accessibility))
    }

    func testNextStepMicrophoneAndAccessibility() {
        let status = GrantStatus(microphone: true, accessibility: true, inputMonitoring: false)
        let result = OnboardingState.nextStep(status)
        XCTAssertEqual(result, .request(.inputMonitoring))
    }

    func testNextStepAllGranted() {
        let status = GrantStatus(microphone: true, accessibility: true, inputMonitoring: true)
        let result = OnboardingState.nextStep(status)
        XCTAssertEqual(result, .done)
    }

    // MARK: - summary(_:)

    func testSummaryZeroGranted() {
        let status = GrantStatus(microphone: false, accessibility: false, inputMonitoring: false)
        let result = OnboardingState.summary(status)
        XCTAssertEqual(result, "0 of 3 permissions granted")
    }

    func testSummaryOneGranted() {
        let status = GrantStatus(microphone: true, accessibility: false, inputMonitoring: false)
        let result = OnboardingState.summary(status)
        XCTAssertEqual(result, "1 of 3 permissions granted")
    }

    func testSummaryTwoGranted() {
        let status = GrantStatus(microphone: true, accessibility: true, inputMonitoring: false)
        let result = OnboardingState.summary(status)
        XCTAssertEqual(result, "2 of 3 permissions granted")
    }

    func testSummaryThreeGranted() {
        let status = GrantStatus(microphone: true, accessibility: true, inputMonitoring: true)
        let result = OnboardingState.summary(status)
        XCTAssertEqual(result, "3 of 3 permissions granted")
    }

    // MARK: - settingsUrl(for:)

    func testSettingsUrlMicrophone() {
        let url = OnboardingState.settingsUrl(for: .microphone)
        XCTAssertTrue(url.absoluteString.contains("Privacy_Microphone"))
    }

    func testSettingsUrlAccessibility() {
        let url = OnboardingState.settingsUrl(for: .accessibility)
        XCTAssertTrue(url.absoluteString.contains("Privacy_Accessibility"))
    }

    func testSettingsUrlInputMonitoring() {
        let url = OnboardingState.settingsUrl(for: .inputMonitoring)
        XCTAssertTrue(url.absoluteString.contains("Privacy_ListenEvent"))
    }

    func testSettingsUrlBaseFormat() {
        let url = OnboardingState.settingsUrl(for: .microphone)
        XCTAssertTrue(url.absoluteString.contains("x-apple.systempreferences"))
        XCTAssertTrue(url.absoluteString.contains("com.apple.preference.security"))
    }
}
