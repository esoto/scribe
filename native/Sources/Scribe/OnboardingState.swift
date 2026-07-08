import Foundation

enum Grant: String, CaseIterable {
    case microphone
    case accessibility
    case inputMonitoring
}

struct GrantStatus {
    var microphone: Bool
    var accessibility: Bool
    var inputMonitoring: Bool
}

enum OnboardingStep: Equatable {
    case request(Grant)
    case done
}

/// Pure logic for the first-run permission flow.
enum OnboardingState {
    /// Returns missing permissions in stable order: microphone, accessibility, inputMonitoring.
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

    /// Returns the next step in the onboarding flow.
    /// Returns .request for the first missing permission, or .done if all are granted.
    static func nextStep(_ s: GrantStatus) -> OnboardingStep {
        let missingPerms = missing(s)
        if let first = missingPerms.first {
            return .request(first)
        }
        return .done
    }

    /// Returns a human-readable summary of the permission status.
    /// Format: "N of 3 permissions granted"
    static func summary(_ s: GrantStatus) -> String {
        let granted = [s.microphone, s.accessibility, s.inputMonitoring].filter { $0 }.count
        return "\(granted) of 3 permissions granted"
    }

    /// Returns the deep-link URL to the macOS system preferences for the given permission.
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
        // Force unwrap is safe because we control the URL string
        return URL(string: urlString)!
    }
}
