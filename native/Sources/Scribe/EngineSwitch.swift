import Foundation

/// Pure engine-switch rules, kept out of `AppModel` so the tricky cases are unit-testable.
enum EngineSwitch {
    enum Action: Equatable {
        case ignore
        case revert
        case begin
    }

    /// Compares against `pending ?? active`; `active` alone is stale mid-switch.
    static func action(selecting name: String, active: String, pending: String?) -> Action {
        guard name != (pending ?? active) else { return .ignore }
        return name == active ? .revert : .begin
    }

    /// Unload a cancelled switch's preload unless a newer selection owns it, or it stays resident unowned.
    static func shouldUnloadSuperseded(_ name: String, active: String, pending: String?) -> Bool {
        name != active && name != pending
    }
}
