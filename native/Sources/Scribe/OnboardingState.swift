import Foundation

enum Grant: String, CaseIterable {
    case microphone
    case accessibility
    case inputMonitoring
}

struct GrantStatus: Equatable {
    var microphone: Bool
    var accessibility: Bool
    var inputMonitoring: Bool
}

/// What a fresh probe means for the published grants. Only a false→true flip of mic or Input Monitoring needs a reaction.
struct GrantChange: Equatable {
    let publish: Bool
    let microphoneNewlyGranted: Bool
    let inputMonitoringNewlyGranted: Bool

    init(from old: GrantStatus, to fresh: GrantStatus) {
        publish = fresh != old
        microphoneNewlyGranted = fresh.microphone && !old.microphone
        inputMonitoringNewlyGranted = fresh.inputMonitoring && !old.inputMonitoring
    }
}

enum OnboardingStep: Equatable {
    case request(Grant)
    case done
}

enum OnboardingState {
    static func missing(_ s: GrantStatus) -> [Grant] {
        var result: [Grant] = []
        if !s.microphone {
            result.append(.microphone)
        }
        if !s.accessibility {
            result.append(.accessibility)
        }
        if !s.inputMonitoring {
            result.append(.inputMonitoring)
        }
        return result
    }

    static func nextStep(_ s: GrantStatus) -> OnboardingStep {
        let missingPerms = missing(s)
        if let first = missingPerms.first {
            return .request(first)
        }
        return .done
    }

    static func summary(_ s: GrantStatus) -> String {
        let granted = [s.microphone, s.accessibility, s.inputMonitoring].filter { $0 }.count
        return "\(granted) of 3 permissions granted"
    }

    static func settingsUrl(for grant: Grant) -> URL {
        let base = "x-apple.systempreferences:com.apple.preference.security"
        let pane: String
        switch grant {
        case .microphone:
            pane = "Privacy_Microphone"
        case .accessibility:
            pane = "Privacy_Accessibility"
        case .inputMonitoring:
            pane = "Privacy_ListenEvent"
        }
        let urlString = "\(base)?\(pane)"
        return URL(string: urlString)!
    }
}

/// The microphone probe is tri-state; Accessibility and Input Monitoring only answer yes or no.
enum TCCStatus: Equatable {
    case notDetermined, denied, authorized
}

enum NotificationAuthorization: Equatable {
    case notDetermined, denied, authorized
}

enum PermissionAction: Equatable {
    case request, openSystemSettings
}

extension OnboardingState {
    /// Which buttons a Setup row offers. "Request" is dead once the system has an answer, so a denied microphone
    /// gets only the System Settings route; the two boolean probes keep both until granted.
    static func actions(for grant: Grant, granted: Bool, microphoneStatus: TCCStatus?) -> [PermissionAction] {
        guard !granted else { return [] }
        if grant == .microphone, let microphoneStatus {
            switch microphoneStatus {
            case .notDetermined: return [.request]
            case .denied: return [.openSystemSettings]
            case .authorized: return []
            }
        }
        return [.request, .openSystemSettings]
    }

    static func title(_ grant: Grant) -> String {
        switch grant {
        case .microphone: return "Microphone"
        case .accessibility: return "Accessibility"
        case .inputMonitoring: return "Input Monitoring"
        }
    }

    static func buttonTitle(_ action: PermissionAction) -> String {
        action == .request ? "Request" : "Open System Settings"
    }

    /// VoiceOver label: the same two button titles repeat on every row, so each names its grant.
    static func accessibilityLabel(_ action: PermissionAction, for grant: Grant) -> String {
        action == .request ? "Request \(title(grant)) access" : "Open \(title(grant)) settings"
    }

    /// The Models row: a download or load in progress, else ready. `ready` gates the "Hold … and speak" test field.
    static func modelsRow(sttDownload: String?, cleanupStatus: String?) -> (detail: String, ready: Bool) {
        if let sttDownload { return (sttDownload, false) }
        if let cleanupStatus { return (cleanupStatus, false) }
        return ("Ready", true)
    }

    static func notificationsDetail(_ status: NotificationAuthorization) -> String {
        switch status {
        case .notDetermined: return "Needed to tell you when a dictation fails."
        case .denied: return "Off — scribe can't tell you when a dictation fails."
        case .authorized: return "On — scribe tells you when a dictation fails."
        }
    }

    static func notificationsActions(_ status: NotificationAuthorization) -> [PermissionAction] {
        switch status {
        case .notDetermined: return [.request]
        case .denied: return [.openSystemSettings]
        case .authorized: return []
        }
    }

    static let notificationsSettingsUrl = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!
}

/// VoiceOver value for the menu bar glyph, which otherwise reads as "white bullet" or "warning sign".
func glyphAccessibilityValue(_ state: PipelineState, progress: Double?, needsAttention: Bool) -> String {
    switch state {
    case .recording: return "recording"
    case .processing: return "transcribing"
    case .error: return "error"
    case .idle:
        if needsAttention { return "needs attention" }
        if let progress, progress < 1 { return "downloading, \(Int((progress * 100).rounded(.down))) percent" }
        return "idle"
    }
}
