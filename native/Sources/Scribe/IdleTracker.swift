import Foundation

/// Idle tracking for on-demand model unloading (pure logic).
///
/// Ported from `scribe.idle.IdleTracker` (src/scribe/idle.py). See
/// IdleTrackerTests.swift for the full port of tests/test_idle.py.
final class IdleTracker {
    private let timeoutSeconds: Double
    private var lastActivity: Double?

    init(unloadAfterMinutes: Double) {
        self.timeoutSeconds = unloadAfterMinutes * 60
    }

    var enabled: Bool {
        timeoutSeconds > 0
    }

    func touch(now: Double) {
        lastActivity = now
    }

    /// True when models should unload: enabled, there was activity, and the
    /// timeout has elapsed. Without any touch, never due — callers that
    /// preload models up front must seed a touch themselves (AppModel does,
    /// at startup) or an unused launch would keep the preload resident
    /// forever.
    func due(now: Double) -> Bool {
        guard enabled, let lastActivity else { return false }
        return (now - lastActivity) >= timeoutSeconds
    }
}
