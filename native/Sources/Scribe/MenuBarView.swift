import AppKit
import SwiftUI

/// Menu bar UI. The view delegates every decision to `AppModel`.

func glyphFor(_ state: PipelineState) -> String {
    switch state {
    case .idle: return "◦"
    case .recording: return "●"
    case .processing: return "⋯"
    case .error: return "⚠"
    }
}

/// The menu-bar glyph: a download percentage while a cleanup model is still
/// downloading, otherwise the pipeline state symbol. The state wins while
/// recording/processing/error, so a background download never hides the
/// feedback that matters most.
func menuBarGlyph(_ state: PipelineState, progress: Double?) -> String {
    guard state == .idle, let progress, progress < 1 else { return glyphFor(state) }
    return "\(Int((progress * 100).rounded(.down)))%"
}

/// Menu status line. An STT model download wins while idle or transcribing: a dictation made during the
/// upgrade download waits on it, and "Transcribing…" alone would look like a hang.
func menuStatusText(_ state: PipelineState, sttDownload: String?, cleanupStatus: String?) -> String? {
    switch state {
    case .idle: return sttDownload ?? cleanupStatus
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
    @Environment(\.openWindow) private var openWindow

    private var statusText: String? {
        menuStatusText(model.state, sttDownload: model.sttDownloadStatus, cleanupStatus: model.cleanupModelStatus)
    }

    var body: some View {
        if let statusText {
            Text(statusText)
                .foregroundStyle(model.state == .error ? Color.red : Color.secondary)
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
            get: { model.activeCleanupModel },
            set: { if let id = CleanupModelID(rawValue: $0) { model.switchCleanupModel(to: id) } }
        )) {
            ForEach(
                CleanupModelCatalog.all.filter {
                    $0.id != .appleIntelligence || model.appleIntelligenceAvailable
                        || model.activeCleanupModel == $0.id.rawValue
                }, id: \.id
            ) { spec in
                Text(pickerLabel(spec, status: model.modelStatuses[spec.id] ?? .notDownloaded))
                    .tag(spec.id.rawValue)
            }
            // A defaults-set custom path overrides the picker — keep it visible.
            if model.activeCleanupModel == "custom" {
                Text("Custom model (set via defaults)").tag("custom")
            }
        }
        .pickerStyle(.menu)
        .disabled(model.activeCleanupModel == "custom")

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

        Toggle(
            "Enhance Audio (experimental)",
            isOn: Binding(
                get: { model.enhanceAudioEnabled },
                set: { model.setEnhanceAudio($0) }
            )
        )
        .help(
            "Runs LocalVQE noise suppression before transcription. Measured to lower accuracy on synthetic noise; try it against your own background noise."
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
                    get: { model.vocabularyBiasingEnabled },
                    set: { model.setVocabularyBiasing($0) }
                )
            )
            Toggle(
                "Learn New Terms",
                isOn: Binding(
                    get: { model.dictionaryLearningEnabled },
                    set: { model.setDictionaryLearning($0) }
                )
            )
            if let note = learningNote(
                fidelitySafe: model.activeCleanupFidelitySafe, learningOn: model.dictionaryLearningEnabled)
            {
                Text(note)
            }
            Button("Edit Dictionary…") {
                openDictionaryWindow(openWindow)
            }
            Divider()
            let learned = menuGlossaryTerms(model.glossaryEntries)
            if learned.isEmpty {
                Text("(no learned terms)")
            } else {
                ForEach(learned, id: \.self) { term in
                    Menu(truncateLabel(term)) {
                        Button("Remove") {
                            model.removeGlossaryTerm(term)
                        }
                    }
                }
                Divider()
                Button("Clear Learned Terms") {
                    model.clearLearnedTerms()
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
