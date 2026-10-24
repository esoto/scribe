import AppKit
import SwiftUI

/// Menu bar UI. The view delegates every decision to the models it observes.

func glyphFor(_ state: PipelineState) -> String {
    switch state {
    case .idle: return "◦"
    case .recording: return "●"
    case .processing: return "⋯"
    case .error: return "⚠"
    }
}

/// The menu-bar glyph: ⚠ while idle with a permission missing, a download percentage while a model is still
/// downloading (cleanup first, then the speech model), otherwise the pipeline state symbol. The state wins while
/// recording/processing/error, so a background download never hides the feedback that matters most.
func menuBarGlyph(_ state: PipelineState, progress: Double?, sttProgress: Double? = nil, needsAttention: Bool) -> String {
    guard state == .idle else { return glyphFor(state) }
    if needsAttention { return glyphFor(.error) }
    if let progress, progress < 1 { return "\(DownloadStatus.wholePercent(progress))%" }
    if let sttProgress, sttProgress < 1 { return "\(DownloadStatus.wholePercent(sttProgress))%" }
    return glyphFor(state)
}

/// The first missing permission, in Setup order, as the menu's status line; nil when all are granted.
func attentionText(for grants: GrantStatus) -> String? {
    guard let first = OnboardingState.missing(grants).first else { return nil }
    let name: String
    switch first {
    case .microphone: name = "Microphone"
    case .accessibility: name = "Accessibility"
    case .inputMonitoring: name = "Input Monitoring"
    }
    return "\(name) is off — open Setup / Doctor…"
}

/// Menu status line. While idle: a missing permission wins (dictation is broken until it's fixed), then an STT
/// download, then an Enhance Audio download, then an engine switch in progress or failed, then a transient hint
/// from the last dictation, then a cleanup-model status. An STT model download wins while transcribing: a dictation
/// made during the upgrade download waits on it, and "Transcribing…" alone would look like a hang. Enhance Audio's
/// never does: a dictation skips it while it loads.
func menuStatusText(
    _ state: PipelineState, sttDownload: String?, enhancerDownload: String? = nil, engineStatus: String? = nil,
    hint: String? = nil, cleanupStatus: String?, attention: String?
) -> String? {
    switch state {
    case .idle: return attention ?? sttDownload ?? enhancerDownload ?? engineStatus ?? hint ?? cleanupStatus
    case .recording: return "Recording…"
    case .processing: return sttDownload ?? "Transcribing…"
    case .error: return "Error — check log"
    }
}

/// The idle status line when nothing needs attention: what the next dictation will use.
func nowLine(engine: String, cleanupModel: String, cleanupEnabled: Bool) -> String {
    cleanupEnabled ? "\(engine) · \(cleanupModel)" : "\(engine) · cleanup off"
}

/// History row: the text, plus a marker when cleanup did not run so the user can tell the two apart. Line breaks
/// are flattened because a snippet block is stored with them and a menu title would wrap.
func historyRowLabel(_ record: DictationRecord) -> String {
    let flat = record.final.split(whereSeparator: \.isNewline).joined(separator: " ")
    return record.cleaned ? truncateLabel(flat) : truncateLabel(flat) + " · raw"
}

/// Option-click alternate of a History row: what the engine heard, before replacements and cleanup.
func historyRawRowLabel(_ record: DictationRecord) -> String {
    "Copy raw · " + truncateLabel(record.raw, n: 30)
}

func truncateLabel(_ text: String, n: Int = 40) -> String {
    guard text.count > n else { return text }
    let cutIndex = text.index(text.startIndex, offsetBy: n - 1)
    return String(text[..<cutIndex]) + "…"
}

private let engineOptions: [(id: String, label: String)] = [
    ("parakeet", "Parakeet (fast)"),
    ("whisper", "Whisper (best Spanish)"),
]

/// The menu label for an engine id; an unknown id shows as itself.
func engineLabel(_ id: String) -> String {
    engineOptions.first { $0.id == id }?.label ?? id
}

/// The cleanup model's name for the status line. A defaults-set custom path has no catalog entry.
func cleanupModelLabel(_ activeCleanupModel: String) -> String {
    guard let id = CleanupModelID(rawValue: activeCleanupModel) else { return "Custom model" }
    return CleanupModelCatalog.spec(id).label
}

struct MenuBarView: View {
    /// For `cleanupEnabled`, the history and the actions; the download statuses come from `downloads`.
    @ObservedObject var model: AppModel
    @ObservedObject var downloads: DownloadStatus
    @ObservedObject var permissions: PermissionsModel
    @ObservedObject var dictation: DictationCoordinator
    @ObservedObject var cleanupModels: CleanupModelController
    @ObservedObject var engineController: EngineController
    @Environment(\.openWindow) private var openWindow

    init(model: AppModel) {
        self.model = model
        self.downloads = model.downloads
        self.permissions = model.permissions
        self.dictation = model.dictation
        self.cleanupModels = model.cleanupModels
        self.engineController = model.engineController
    }

    private var statusText: String? {
        menuStatusText(
            dictation.state, sttDownload: downloads.sttStatus, enhancerDownload: downloads.enhancerStatus,
            engineStatus: engineController.engineStatus, hint: dictation.hint,
            cleanupStatus: cleanupModels.cleanupModelStatus,
            attention: attentionText(for: permissions.grants))
    }

    var body: some View {
        if let statusText {
            Text(statusText)
                .foregroundStyle(dictation.state == .error ? Color.red : Color.secondary)
        } else {
            Text(nowLine(
                engine: engineLabel(engineController.activeEngineName),
                cleanupModel: cleanupModelLabel(cleanupModels.activeCleanupModel),
                cleanupEnabled: model.cleanupEnabled)
            )
            .foregroundStyle(.secondary)
        }
        Divider()

        Picker("Engine", selection: Binding(
            get: { engineController.pendingEngineName ?? engineController.activeEngineName },
            set: { model.switchEngine(to: $0) }
        )) {
            ForEach(engineOptions, id: \.id) { option in
                Text(option.label).tag(option.id)
            }
        }
        .pickerStyle(.inline)

        Toggle(
            "Cleanup (remove fillers)",
            isOn: Binding(
                get: { model.cleanupEnabled },
                set: { model.setCleanupEnabled($0) }
            )
        )

        Divider()

        Menu("History") {
            let items = model.history.items()
            if items.isEmpty {
                Text("(empty)")
            } else {
                Button("Paste Again") {
                    model.pasteLastDictation()
                }
                .help("Pastes the last dictation into the app that has focus")
                Button("Fix a Word…") {
                    openFixWordWindow(openWindow)
                }
                Divider()
                ForEach(items) { record in
                    Button {
                        model.copyToClipboard(record.final)
                    } label: {
                        Label(historyRowLabel(record), systemImage: "doc.on.clipboard")
                    }
                    .help(record.final)
                    .modifierKeyAlternate(.option) {
                        Button {
                            model.copyToClipboard(record.raw)
                        } label: {
                            Label(historyRawRowLabel(record), systemImage: "doc.on.clipboard")
                        }
                    }
                }
            }
        }

        Button("Edit Dictionary…") {
            openDictionaryWindow(openWindow)
        }

        Divider()

        Button("Settings…") {
            openSettingsWindow(openWindow)
        }
        .keyboardShortcut(",")

        Button("Setup / Doctor…") {
            openOnboarding(openWindow)
        }

        Divider()

        Button("Quit scribe") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
