import Foundation

/// Idle tracking for on-demand model unloading.
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

    /// Never due without a touch: callers that preload must seed one, or the preload never unloads.
    func due(now: Double) -> Bool {
        guard enabled, let lastActivity else { return false }
        return (now - lastActivity) >= timeoutSeconds
    }
}
