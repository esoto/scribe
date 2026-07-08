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

    var body: some View {
        Menu("Engine") {
            ForEach(engineOptions, id: \.id) { option in
                Button {
                    model.switchEngine(to: option.id)
                } label: {
                    HStack {
                        Text(option.label)
                        if model.activeEngineName == option.id {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        }

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
                ForEach(Array(items.enumerated()), id: \.offset) { _, record in
                    Button(truncateLabel(record.final)) {
                        model.copyToClipboard(record.final)
                    }
                }
            }
        }

        Divider()

        Button("Setup / Doctor…") {
            model.openDoctor()
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
