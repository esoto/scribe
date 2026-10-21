import AppKit
import SwiftUI

let settingsWindowID = "settings"

/// LSUIElement apps must activate explicitly to bring the window forward.
func openSettingsWindow(_ openWindow: OpenWindowAction) {
    NSApp.activate(ignoringOtherApps: true)
    openWindow(id: settingsWindowID)
}

let holdThresholdChoices: [Double] = (1...10).map { Double($0) / 10 }
let idleUnloadChoices: [Double] = [0, 5, 15, 30, 60]
let restoreDelayChoices: [Double] = [0.5, 1, 2, 3, 5]

/// A value set outside the fixed list (`defaults write`) stays selectable; a picker with no matching tag shows blank.
func pickerChoices(_ fixed: [Double], including current: Double) -> [Double] {
    fixed.contains(current) ? fixed : (fixed + [current]).sorted()
}

func holdThresholdLabel(_ seconds: Double) -> String {
    let tenths = seconds * 10
    return abs(tenths - tenths.rounded()) < 1e-9 ? String(format: "%.1f s", seconds) : String(format: "%g s", seconds)
}

func idleUnloadLabel(_ minutes: Double) -> String {
    guard minutes > 0 else { return "Never" }
    return minutes == minutes.rounded() ? "\(Int(minutes)) min" : String(format: "%g min", minutes)
}

private func caption(_ text: String) -> some View {
    Text(text).font(.caption).foregroundStyle(.secondary)
}

/// Everything set once lives here; the menu keeps only what changes mid-session. Each pane observes the objects
/// whose published values it reads, so a change in one never rebuilds the others.
struct SettingsWindow: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("scribe settings").font(.title2.bold())
            TabView {
                GeneralPane(settings: model.settingsModel, model: model)
                    .tabItem { Text("General") }
                AudioPane(model: model)
                    .tabItem { Text("Audio") }
                ModelsPane(model: model.cleanupModels)
                    .tabItem { Text("Models") }
                StatsPane(model: model.statsModel)
                    .tabItem { Text("Stats") }
            }
        }
        .padding(24)
        .frame(width: 480)
        .onAppear {
            WindowActivation.shared.windowAppeared()
            NSApp.activate(ignoringOtherApps: true)
        }
        .onDisappear { WindowActivation.shared.windowDisappeared() }
    }
}

private struct GeneralPane: View {
    @ObservedObject var settings: SettingsModel
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Picker(
                "Hotkey",
                selection: Binding(get: { settings.hotkey }, set: { settings.setHotkey($0) })
            ) {
                ForEach(HotKey.allCases, id: \.self) { key in
                    Text(key.displayName).tag(key)
                }
            }
            caption("Right ⌥ is rarely used alone and leaves Right ⌘ free.")

            Picker(
                "Ignore taps shorter than",
                selection: Binding(get: { settings.holdThreshold }, set: { settings.setHoldThreshold($0) })
            ) {
                ForEach(pickerChoices(holdThresholdChoices, including: settings.holdThreshold), id: \.self) { seconds in
                    Text(holdThresholdLabel(seconds)).tag(seconds)
                }
            }

            Picker(
                "Restore clipboard after",
                selection: Binding(get: { settings.restoreDelay }, set: { settings.setRestoreDelay($0) })
            ) {
                ForEach(pickerChoices(restoreDelayChoices, including: settings.restoreDelay), id: \.self) { seconds in
                    Text(holdThresholdLabel(seconds)).tag(seconds)
                }
            }
            caption("Your previous clipboard comes back this long after a paste — raise it if a slow app pastes the old one instead.")

            Toggle("Sounds", isOn: Binding(get: { settings.sounds }, set: { settings.setSounds($0) }))
            Toggle(
                "Allow scribe:// URLs",
                isOn: Binding(get: { settings.urlSchemeEnabled }, set: { settings.setURLSchemeEnabled($0) }))
            caption("Lets Raycast, Stream Deck or a foot pedal open scribe://paste-last. Off by default: while it is on, any app, or a web page you allow, can paste your last dictation into the app that has focus.")
            Toggle(
                "Voice commands",
                isOn: Binding(get: { settings.voiceCommandsEnabled }, set: { settings.setVoiceCommandsEnabled($0) }))
            caption("Say one of these on its own: “enter” or “send it”, “new line”, “new paragraph”, “scratch that” or “undo” — or the Spanish “enviar”, “nueva línea”, “nuevo párrafo”, “borra eso”, “deshacer”.")
            Toggle(
                "Recording pill",
                isOn: Binding(get: { settings.hudEnabled }, set: { settings.setHudEnabled($0) }))
            caption("A small pill above the Dock shows the level while you hold the key, then the result.")
            Toggle(
                "Launch at Login",
                isOn: Binding(get: { model.launchAtLoginEnabled }, set: { model.setLaunchAtLogin($0) }))

            Picker(
                "Unload models after",
                selection: Binding(get: { settings.idleUnloadMinutes }, set: { settings.setIdleUnloadMinutes($0) })
            ) {
                ForEach(pickerChoices(idleUnloadChoices, including: settings.idleUnloadMinutes), id: \.self) { minutes in
                    Text(idleUnloadLabel(minutes)).tag(minutes)
                }
            }
            caption("Frees ~3 GB after a quiet spell; the next dictation reloads while you speak.")

            Stepper(
                "History size: \(settings.historySize)",
                value: Binding(get: { settings.historySize }, set: { settings.setHistorySize($0) }),
                in: 1...50)
        }
        .padding(16)
    }
}

private struct AudioPane: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Picker(
                "Microphone",
                selection: Binding(
                    get: { model.microphoneUID ?? "" },
                    set: { model.setMicrophone(uid: $0.isEmpty ? nil : $0) })
            ) {
                Text("System Default").tag("")
                ForEach(model.microphones) { device in
                    Text(device.name).tag(device.id)
                }
                // Keeps a stale selection visible after its device unplugs.
                if let uid = model.microphoneUID, !model.microphones.contains(where: { $0.id == uid }) {
                    Text("(disconnected)").tag(uid)
                }
            }
            caption("The built-in mic avoids the Bluetooth headset delay.")

            Toggle(
                "Enhance Audio — experimental",
                isOn: Binding(get: { model.enhanceAudioEnabled }, set: { model.setEnhanceAudio($0) }))
            caption(
                "Lowered accuracy on synthetic noise in tests. Try it against your own background noise. "
                    + "Downloads a ~19 MB model the first time.")
        }
        .padding(16)
    }
}
