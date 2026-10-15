import XCTest

final class OnboardingStateTests: XCTestCase {
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

    func testGrantChangePublishesOnlyWhenTheStatusDiffers() {
        let all = GrantStatus(microphone: true, accessibility: true, inputMonitoring: true)
        XCTAssertFalse(GrantChange(from: all, to: all).publish)
        XCTAssertTrue(
            GrantChange(from: all, to: GrantStatus(microphone: true, accessibility: false, inputMonitoring: true)).publish)
    }

    func testGrantChangeFlagsOnlyFalseToTrueFlipsOfMicAndInputMonitoring() {
        let none = GrantStatus(microphone: false, accessibility: false, inputMonitoring: false)
        let all = GrantStatus(microphone: true, accessibility: true, inputMonitoring: true)

        let granted = GrantChange(from: none, to: all)
        XCTAssertTrue(granted.microphoneNewlyGranted)
        XCTAssertTrue(granted.inputMonitoringNewlyGranted)

        // Revocation and steady state must not re-run the reactions.
        let revoked = GrantChange(from: all, to: none)
        XCTAssertFalse(revoked.microphoneNewlyGranted)
        XCTAssertFalse(revoked.inputMonitoringNewlyGranted)
        let steady = GrantChange(from: all, to: all)
        XCTAssertFalse(steady.microphoneNewlyGranted)
        XCTAssertFalse(steady.inputMonitoringNewlyGranted)
    }

    func testGrantChangeIgnoresAccessibilityFlipsForReactions() {
        let off = GrantStatus(microphone: true, accessibility: false, inputMonitoring: true)
        let on = GrantStatus(microphone: true, accessibility: true, inputMonitoring: true)
        let change = GrantChange(from: off, to: on)
        XCTAssertTrue(change.publish)
        XCTAssertFalse(change.microphoneNewlyGranted)
        XCTAssertFalse(change.inputMonitoringNewlyGranted)
    }
}
