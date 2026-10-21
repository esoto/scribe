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
    @Published private(set) var voiceCommandsEnabled: Bool
    @Published private(set) var urlSchemeEnabled: Bool
    @Published private(set) var hudEnabled: Bool
    @Published private(set) var hotkeyMode: HotkeyMode

    private let settings: AppSettings
    private let onHotkeyChanged: (HotKey) -> Void
    private let onHoldThresholdChanged: (Double) -> Void
    private let onIdleMinutesChanged: (Double) -> Void
    private let onHistorySizeChanged: (Int) -> Void
    private let onRestoreDelayChanged: (Double) -> Void
    private let onVoiceCommandsChanged: (Bool) -> Void
    private let onHudEnabledChanged: (Bool) -> Void
    private let onHotkeyModeChanged: (HotkeyMode) -> Void

    init(
        settings: AppSettings,
        onHotkeyChanged: @escaping (HotKey) -> Void,
        onHoldThresholdChanged: @escaping (Double) -> Void,
        onIdleMinutesChanged: @escaping (Double) -> Void,
        onHistorySizeChanged: @escaping (Int) -> Void,
        onRestoreDelayChanged: @escaping (Double) -> Void,
        onVoiceCommandsChanged: @escaping (Bool) -> Void = { _ in },
        onHudEnabledChanged: @escaping (Bool) -> Void = { _ in },
        onHotkeyModeChanged: @escaping (HotkeyMode) -> Void = { _ in }
    ) {
        self.settings = settings
        self.onHotkeyChanged = onHotkeyChanged
        self.onHoldThresholdChanged = onHoldThresholdChanged
        self.onIdleMinutesChanged = onIdleMinutesChanged
        self.onHistorySizeChanged = onHistorySizeChanged
        self.onRestoreDelayChanged = onRestoreDelayChanged
        self.onVoiceCommandsChanged = onVoiceCommandsChanged
        self.onHudEnabledChanged = onHudEnabledChanged
        self.onHotkeyModeChanged = onHotkeyModeChanged
        hotkey = settings.hotkey
        holdThreshold = settings.holdThreshold
        sounds = settings.sounds
        idleUnloadMinutes = settings.idleUnloadMinutes
        historySize = settings.historySize
        restoreDelay = settings.restoreDelay
        voiceCommandsEnabled = settings.voiceCommandsEnabled
        urlSchemeEnabled = settings.urlSchemeEnabled
        hudEnabled = settings.hudEnabled
        hotkeyMode = settings.hotkeyMode
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

    func setVoiceCommandsEnabled(_ on: Bool) {
        guard on != voiceCommandsEnabled else { return }
        voiceCommandsEnabled = on
        settings.voiceCommandsEnabled = on
        onVoiceCommandsChanged(on)
    }

    /// No effect closure: the URL handler reads `AppSettings` on every open.
    func setURLSchemeEnabled(_ on: Bool) {
        guard on != urlSchemeEnabled else { return }
        urlSchemeEnabled = on
        settings.urlSchemeEnabled = on
    }

    func setHudEnabled(_ on: Bool) {
        guard on != hudEnabled else { return }
        hudEnabled = on
        settings.hudEnabled = on
        onHudEnabledChanged(on)
    }

    func setHotkeyMode(_ mode: HotkeyMode) {
        guard mode != hotkeyMode else { return }
        hotkeyMode = mode
        settings.hotkeyMode = mode
        onHotkeyModeChanged(mode)
    }
}
