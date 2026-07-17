import AppKit
import SwiftUI

/// Menu bar UI (SwiftUI/MenuBarExtra). Pure helpers up top; the view below
/// delegates every decision to `AppModel`.
///
/// Ported from `scribe.menubar` (src/scribe/menubar.py) — `ScribeMenuBar`'s
/// rumps-driven NSMenu construction becomes a declarative SwiftUI menu body;
/// `glyph_for`/`truncate_label` port 1:1 (see MenuBarHelpersTests.swift for
/// the port of tests/test_menubar_helpers.py).

/// Maps a `PipelineState` to its one-glyph menu bar title.
func glyphFor(_ state: PipelineState) -> String {
    switch state {
    case .idle: return "◦"
    case .recording: return "●"
    case .processing: return "⋯"
    case .error: return "⚠"
    }
}

/// Truncates `text` to at most `n` characters, replacing the tail with `…`
/// when it doesn't fit.
func truncateLabel(_ text: String, n: Int = 40) -> String {
    guard text.count > n else { return text }
    let cutIndex = text.index(text.startIndex, offsetBy: n - 1)
    return String(text[..<cutIndex]) + "…"
}

private let engineOptions: [(id: String, label: String)] = [
    ("parakeet", "Parakeet (fast)"),
    ("whisper", "Whisper (best Spanish)"),
]

struct MenuBarView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    private var statusText: String? {
        switch model.state {
        case .idle: return nil
        case .recording: return "Recording…"
        case .processing: return "Transcribing…"
        case .error: return "Error — check log"
        }
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

        Picker("Microphone", selection: Binding(
            get: { model.microphoneUID ?? "" },
            set: { model.setMicrophone(uid: $0.isEmpty ? nil : $0) }
        )) {
            Text("System Default").tag("")
            let devices = model.availableMicrophones()
            ForEach(devices) { device in
                Text(device.name).tag(device.id)
            }
            // Keep a stale selection visible (and revertable) after its
            // device unplugs — capture falls back to the default meanwhile.
            if let uid = model.microphoneUID, !devices.contains(where: { $0.id == uid }) {
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
