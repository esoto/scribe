import Foundation

/// What the Settings window edits. Each setter persists to `AppSettings` and runs its effect once per real change,
/// so a repeated binding write never reinstalls the hotkey tap or rebuilds anything. Sounds needs no effect:
/// the coordinator reads `AppSettings.sounds` on every cue.
@MainActor
final class SettingsModel: ObservableObject {
    @Published private(set) var hotkey: HotKey
    @Published private(set) var holdThreshold: Double
    @Published private(set) var sounds: Bool
    @Published private(set) var idleUnloadMinutes: Double
    @Published private(set) var historySize: Int
    @Published private(set) var restoreDelay: Double

    private let settings: AppSettings
    private let onHotkeyChanged: (HotKey) -> Void
    private let onHoldThresholdChanged: (Double) -> Void
    private let onIdleMinutesChanged: (Double) -> Void
    private let onHistorySizeChanged: (Int) -> Void
    private let onRestoreDelayChanged: (Double) -> Void

    init(
        settings: AppSettings,
        onHotkeyChanged: @escaping (HotKey) -> Void,
        onHoldThresholdChanged: @escaping (Double) -> Void,
        onIdleMinutesChanged: @escaping (Double) -> Void,
        onHistorySizeChanged: @escaping (Int) -> Void,
        onRestoreDelayChanged: @escaping (Double) -> Void
    ) {
        self.settings = settings
        self.onHotkeyChanged = onHotkeyChanged
        self.onHoldThresholdChanged = onHoldThresholdChanged
        self.onIdleMinutesChanged = onIdleMinutesChanged
        self.onHistorySizeChanged = onHistorySizeChanged
        self.onRestoreDelayChanged = onRestoreDelayChanged
        hotkey = settings.hotkey
        holdThreshold = settings.holdThreshold
        sounds = settings.sounds
        idleUnloadMinutes = settings.idleUnloadMinutes
        historySize = settings.historySize
        restoreDelay = settings.restoreDelay
    }

    func setHotkey(_ key: HotKey) {
        guard key != hotkey else { return }
        hotkey = key
        settings.hotkey = key
        onHotkeyChanged(key)
    }

    func setHoldThreshold(_ seconds: Double) {
        guard seconds != holdThreshold else { return }
        holdThreshold = seconds
        settings.holdThreshold = seconds
        onHoldThresholdChanged(seconds)
    }

    func setSounds(_ on: Bool) {
        guard on != sounds else { return }
        sounds = on
        settings.sounds = on
    }

    func setIdleUnloadMinutes(_ minutes: Double) {
        guard minutes != idleUnloadMinutes else { return }
        idleUnloadMinutes = minutes
        settings.idleUnloadMinutes = minutes
        onIdleMinutesChanged(minutes)
    }

    func setHistorySize(_ size: Int) {
        guard size != historySize else { return }
        historySize = size
        settings.historySize = size
        onHistorySizeChanged(size)
    }

    func setRestoreDelay(_ seconds: Double) {
        guard seconds != restoreDelay else { return }
        restoreDelay = seconds
        settings.restoreDelay = seconds
        onRestoreDelayChanged(seconds)
    }
}
