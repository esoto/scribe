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

/// The menu-bar glyph: ⚠ while idle with a permission missing, a download percentage while a cleanup model
/// is still downloading, otherwise the pipeline state symbol. The state wins while
/// recording/processing/error, so a background download never hides the
/// feedback that matters most.
func menuBarGlyph(_ state: PipelineState, progress: Double?, needsAttention: Bool) -> String {
    guard state == .idle else { return glyphFor(state) }
    if needsAttention { return glyphFor(.error) }
    guard let progress, progress < 1 else { return glyphFor(state) }
    return "\(Int((progress * 100).rounded(.down)))%"
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

/// Menu status line. While idle a missing permission wins, since dictation is broken until it's fixed.
/// An STT model download wins while transcribing: a dictation made during the
/// upgrade download waits on it, and "Transcribing…" alone would look like a hang.
func menuStatusText(
    _ state: PipelineState, sttDownload: String?, cleanupStatus: String?, attention: String?
) -> String? {
    switch state {
    case .idle: return attention ?? sttDownload ?? cleanupStatus
    case .recording: return "Recording…"
    case .processing: return sttDownload ?? "Transcribing…"
    case .error: return "Error — check log"
    }
}

func truncateLabel(_ text: String, n: Int = 40) -> String {
    guard text.count > n else { return text }
    let cutIndex = text.index(text.startIndex, offsetBy: n - 1)
    return String(text[..<cutIndex]) + "…"
}

/// Learned entries only: pair-seeded terms can't be removed here, so offering them would leave a dead Remove button.
func menuGlossaryTerms(_ entries: [GlossaryEntry], limit: Int = 20) -> [String] {
    entries
        .sorted { $0.count != $1.count ? $0.count > $1.count : $0.lastSeen > $1.lastSeen }
        .prefix(limit)
        .map(\.term)
}

private let engineOptions: [(id: String, label: String)] = [
    ("parakeet", "Parakeet (fast)"),
    ("whisper", "Whisper (best Spanish)"),
]

struct MenuBarView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var dictionaryModel: DictionaryModel
    @ObservedObject var permissions: PermissionsModel
    @ObservedObject var dictation: DictationCoordinator
    @ObservedObject var cleanupModels: CleanupModelController
    @Environment(\.openWindow) private var openWindow

    init(model: AppModel) {
        self.model = model
        self.dictionaryModel = model.dictionaryModel
        self.permissions = model.permissions
        self.dictation = model.dictation
        self.cleanupModels = model.cleanupModels
    }

    private var statusText: String? {
        menuStatusText(
            dictation.state, sttDownload: model.sttDownloadStatus, cleanupStatus: cleanupModels.cleanupModelStatus,
            attention: attentionText(for: permissions.grants))
    }

    var body: some View {
        if let statusText {
            Text(statusText)
                .foregroundStyle(dictation.state == .error ? Color.red : Color.secondary)
            Divider()
        }

        Picker("Engine", selection: Binding(
            get: { model.activeEngineName },
            set: { model.switchEngine(to: $0) }
        )) {
            ForEach(engineOptions, id: \.id) { option in
                Text(option.label).tag(option.id)
            }
        }
        .pickerStyle(.inline)

        Picker("Cleanup Model", selection: Binding(
            get: { cleanupModels.activeCleanupModel },
            set: { if let id = CleanupModelID(rawValue: $0) { cleanupModels.switchCleanupModel(to: id) } }
        )) {
            ForEach(
                CleanupModelCatalog.all.filter {
                    $0.id != .appleIntelligence || cleanupModels.appleIntelligenceAvailable
                        || cleanupModels.activeCleanupModel == $0.id.rawValue
                }, id: \.id
            ) { spec in
                Text(pickerLabel(spec, status: cleanupModels.modelStatuses[spec.id] ?? .notDownloaded))
                    .tag(spec.id.rawValue)
            }
            // A defaults-set custom path overrides the picker — keep it visible.
            if cleanupModels.activeCleanupModel == "custom" {
                Text("Custom model (set via defaults)").tag("custom")
            }
        }
        .pickerStyle(.menu)
        .disabled(cleanupModels.activeCleanupModel == "custom")

        Button("Manage Models…") {
            openModelsWindow(openWindow)
        }

        Picker("Microphone", selection: Binding(
            get: { model.microphoneUID ?? "" },
            set: { model.setMicrophone(uid: $0.isEmpty ? nil : $0) }
        )) {
            Text("System Default").tag("")
            ForEach(model.microphones) { device in
                Text(device.name).tag(device.id)
            }
            // Keeps a stale selection visible after its device unplugs.
            if let uid = model.microphoneUID, !model.microphones.contains(where: { $0.id == uid }) {
                Text("(disconnected)").tag(uid)
            }
        }
        .pickerStyle(.menu)

        Toggle(
            "Cleanup",
            isOn: Binding(
                get: { model.cleanupEnabled },
                set: { model.setCleanupEnabled($0) }
            )
        )

        Menu("History") {
            let items = model.history.items()
            if items.isEmpty {
                Text("(empty)")
            } else {
                ForEach(items) { record in
                    Button {
                        model.copyToClipboard(record.final)
                    } label: {
                        Label(truncateLabel(record.final), systemImage: "doc.on.clipboard")
                    }
                    .help(record.final)
                }
            }
        }

        Menu("Dictionary") {
            Toggle(
                "Correct Speech (bias recognizer)",
                isOn: Binding(
                    get: { dictionaryModel.vocabularyBiasingEnabled },
                    set: { dictionaryModel.setVocabularyBiasing($0) }
                )
            )
            Toggle(
                "Learn New Terms",
                isOn: Binding(
                    get: { dictionaryModel.dictionaryLearningEnabled },
                    set: { dictionaryModel.setDictionaryLearning($0) }
                )
            )
            if let note = learningNote(
                fidelitySafe: cleanupModels.activeCleanupFidelitySafe, learningOn: dictionaryModel.dictionaryLearningEnabled)
            {
                Text(note)
            }
            Button("Edit Dictionary…") {
                openDictionaryWindow(openWindow)
            }
            Divider()
            let learned = menuGlossaryTerms(dictionaryModel.glossaryEntries)
            if learned.isEmpty {
                Text("(no learned terms)")
            } else {
                ForEach(learned, id: \.self) { term in
                    Menu(truncateLabel(term)) {
                        Button("Remove") {
                            dictionaryModel.removeGlossaryTerm(term)
                        }
                    }
                }
                Divider()
                Button("Clear Learned Terms") {
                    dictionaryModel.clearLearnedTerms()
                }
            }
        }

        Divider()

        Button("Setup / Doctor…") {
            openOnboarding(openWindow)
        }

        Toggle(
            "Launch at Login",
            isOn: Binding(
                get: { model.launchAtLoginEnabled },
                set: { model.setLaunchAtLogin($0) }
            )
        )

        Divider()

        Button("Quit") {
            NSApplication.shared.terminate(nil)
        }
    }
}
