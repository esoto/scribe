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
