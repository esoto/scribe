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

    func testActionsGrantedOffersNothing() {
        let statuses: [TCCStatus?] = [nil, .notDetermined, .denied, .authorized]
        for grant in Grant.allCases {
            for status in statuses {
                XCTAssertEqual(OnboardingState.actions(for: grant, granted: true, microphoneStatus: status), [])
            }
        }
    }

    func testActionsMicrophoneNotDeterminedOffersOnlyRequest() {
        let result = OnboardingState.actions(for: .microphone, granted: false, microphoneStatus: .notDetermined)
        XCTAssertEqual(result, [.request])
    }

    func testActionsMicrophoneDeniedOffersOnlyOpenSystemSettings() {
        let result = OnboardingState.actions(for: .microphone, granted: false, microphoneStatus: .denied)
        XCTAssertEqual(result, [.openSystemSettings])
    }

    func testActionsMicrophoneAuthorizedButNotGrantedOffersNothing() {
        let result = OnboardingState.actions(for: .microphone, granted: false, microphoneStatus: .authorized)
        XCTAssertEqual(result, [])
    }

    func testActionsMicrophoneWithoutProbeOffersBoth() {
        let result = OnboardingState.actions(for: .microphone, granted: false, microphoneStatus: nil)
        XCTAssertEqual(result, [.request, .openSystemSettings])
    }

    func testActionsAccessibilityNotGrantedOffersBoth() {
        let result = OnboardingState.actions(for: .accessibility, granted: false, microphoneStatus: nil)
        XCTAssertEqual(result, [.request, .openSystemSettings])
    }

    func testActionsInputMonitoringNotGrantedOffersBoth() {
        let result = OnboardingState.actions(for: .inputMonitoring, granted: false, microphoneStatus: nil)
        XCTAssertEqual(result, [.request, .openSystemSettings])
    }

    func testActionsIgnoreMicrophoneStatusForOtherGrants() {
        let statuses: [TCCStatus?] = [.notDetermined, .denied, .authorized]
        for grant in [Grant.accessibility, .inputMonitoring] {
            for status in statuses {
                XCTAssertEqual(
                    OnboardingState.actions(for: grant, granted: false, microphoneStatus: status),
                    [.request, .openSystemSettings])
            }
        }
    }

    func testNotificationsAccessibilityLabelNamesNotifications() {
        XCTAssertEqual(OnboardingState.notificationsAccessibilityLabel(.request), "Request Notifications access")
        XCTAssertEqual(
            OnboardingState.notificationsAccessibilityLabel(.openSystemSettings), "Open Notifications settings")
    }

    func testTitleNamesEachGrant() {
        XCTAssertEqual(OnboardingState.title(.microphone), "Microphone")
        XCTAssertEqual(OnboardingState.title(.accessibility), "Accessibility")
        XCTAssertEqual(OnboardingState.title(.inputMonitoring), "Input Monitoring")
    }

    func testNotificationsSettingsUrl() {
        XCTAssertEqual(
            OnboardingState.notificationsSettingsUrl.absoluteString,
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
    }

    func testButtonTitleRequest() {
        XCTAssertEqual(OnboardingState.buttonTitle(.request), "Request")
    }

    func testButtonTitleOpenSystemSettings() {
        XCTAssertEqual(OnboardingState.buttonTitle(.openSystemSettings), "Open System Settings")
    }

    func testAccessibilityLabelRequestNamesGrant() {
        XCTAssertEqual(OnboardingState.accessibilityLabel(.request, for: .microphone), "Request Microphone access")
    }

    func testAccessibilityLabelOpenSettingsNamesGrant() {
        XCTAssertEqual(
            OnboardingState.accessibilityLabel(.openSystemSettings, for: .inputMonitoring),
            "Open Input Monitoring settings")
    }

    func testModelsRowSttDownloadTakesPrecedence() {
        let row = OnboardingState.modelsRow(
            sttDownload: "Downloading speech model", cleanupStatus: "Loading cleanup", loading: true)
        XCTAssertEqual(row.detail, "Downloading speech model")
        XCTAssertFalse(row.ready)
    }

    func testModelsRowCleanupStatusWhileLoading() {
        let row = OnboardingState.modelsRow(sttDownload: nil, cleanupStatus: "Loading cleanup", loading: true)
        XCTAssertEqual(row.detail, "Loading cleanup")
        XCTAssertFalse(row.ready)
    }

    func testModelsRowLoadingWithNoStatusIsNotReady() {
        // A load from disk reports nothing, so the flag alone must hold the row back.
        let row = OnboardingState.modelsRow(sttDownload: nil, cleanupStatus: nil, loading: true)
        XCTAssertEqual(row.detail, "Loading models…")
        XCTAssertFalse(row.ready)
    }

    func testModelsRowStatusWithoutLoadingIsAFailureAndStaysReady() {
        let row = OnboardingState.modelsRow(
            sttDownload: nil, cleanupStatus: "Couldn't load Gemma — still using Apple Intelligence", loading: false)
        XCTAssertEqual(row.detail, "Couldn't load Gemma — still using Apple Intelligence")
        XCTAssertTrue(row.ready)
    }

    func testModelsRowReadyWhenNothingInProgress() {
        let row = OnboardingState.modelsRow(sttDownload: nil, cleanupStatus: nil, loading: false)
        XCTAssertEqual(row.detail, "Ready")
        XCTAssertTrue(row.ready)
    }

    func testNotificationsDetailNotDetermined() {
        XCTAssertEqual(
            OnboardingState.notificationsDetail(.notDetermined),
            "Needed to tell you when a dictation fails.")
    }

    func testNotificationsDetailDenied() {
        XCTAssertEqual(
            OnboardingState.notificationsDetail(.denied),
            "Off — scribe can't tell you when a dictation fails.")
    }

    func testNotificationsDetailAuthorized() {
        XCTAssertEqual(
            OnboardingState.notificationsDetail(.authorized),
            "On — scribe tells you when a dictation fails.")
    }

    func testNotificationsActionsNotDetermined() {
        XCTAssertEqual(OnboardingState.notificationsActions(.notDetermined), [.request])
    }

    func testNotificationsActionsDenied() {
        XCTAssertEqual(OnboardingState.notificationsActions(.denied), [.openSystemSettings])
    }

    func testNotificationsActionsAuthorized() {
        XCTAssertEqual(OnboardingState.notificationsActions(.authorized), [])
    }

    func testGlyphRecordingValue() {
        XCTAssertEqual(glyphAccessibilityValue(.recording, progress: nil, needsAttention: false), "recording")
    }

    func testGlyphProcessingValue() {
        XCTAssertEqual(glyphAccessibilityValue(.processing, progress: nil, needsAttention: false), "transcribing")
    }

    func testGlyphErrorValue() {
        XCTAssertEqual(glyphAccessibilityValue(.error, progress: nil, needsAttention: false), "error")
    }

    func testGlyphIdleValue() {
        XCTAssertEqual(glyphAccessibilityValue(.idle, progress: nil, needsAttention: false), "idle")
    }

    func testGlyphIdleNeedsAttentionValue() {
        XCTAssertEqual(glyphAccessibilityValue(.idle, progress: nil, needsAttention: true), "needs attention")
    }

    func testGlyphIdleDownloadingValueRoundsDownPercent() {
        XCTAssertEqual(
            glyphAccessibilityValue(.idle, progress: 0.42, needsAttention: false),
            "downloading, 42 percent")
    }

    func testGlyphValueNeedsAttentionBeatsDownload() {
        XCTAssertEqual(glyphAccessibilityValue(.idle, progress: 0.42, needsAttention: true), "needs attention")
    }

    func testGlyphValueActiveStateBeatsNeedsAttention() {
        XCTAssertEqual(glyphAccessibilityValue(.recording, progress: 0.42, needsAttention: true), "recording")
    }

    func testGlyphIdleFinishedDownloadIsIdle() {
        XCTAssertEqual(glyphAccessibilityValue(.idle, progress: 1.0, needsAttention: false), "idle")
    }
}
