import Foundation

/// Pure decision helpers for engine switching — same pattern as `Gates`:
/// `AppModel.switchEngine` owns the tasks and side effects, these own the
/// rules, so the tricky cases (switch-back mid-preload, rapid A→B→C) are
/// testable without constructing an `AppModel`.
enum EngineSwitch {
    enum Action: Equatable {
        /// Selection is already the effective target — nothing to do.
        case ignore
        /// Selection returns to the committed engine while a switch is in
        /// flight — cancel the pending switch, load/commit nothing.
        case revert
        /// Start switching to the selected engine.
        case begin
    }

    /// What selecting `name` from the menu should do. `active` is the
    /// committed engine; `pending` is the in-flight switch target, nil when
    /// no switch is in flight. Comparing against `pending ?? active` (not
    /// just `active`, which is stale mid-switch) is what makes re-selecting
    /// the current engine cancel an unwanted in-flight switch instead of
    /// being silently ignored.
    static func action(selecting name: String, active: String, pending: String?) -> Action {
        guard name != (pending ?? active) else { return .ignore }
        return name == active ? .revert : .begin
    }

    /// Whether a superseded (cancelled) switch task that just finished
    /// preloading `name` should unload it: yes unless a newer selection
    /// committed it or is in flight to it — otherwise the speculative load
    /// would stay resident with no owner until the idle unloader runs.
    static func shouldUnloadSuperseded(_ name: String, active: String, pending: String?) -> Bool {
        name != active && name != pending
    }
}
