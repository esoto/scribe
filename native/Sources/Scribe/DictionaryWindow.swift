import AppKit
import SwiftUI

/// Scene id for the dictionary editor window, shared between the menu's
/// "Edit Dictionary…" item and the scene declaration in `ScribeApp`.
let dictionaryWindowID = "dictionary"

/// Brings scribe to the foreground and opens the dictionary editor —
/// same LSUIElement activation dance as `openOnboarding`.
func openDictionaryWindow(_ openWindow: OpenWindowAction) {
    NSApp.activate(ignoringOtherApps: true)
    openWindow(id: dictionaryWindowID)
}

/// Row label for a replacement pair. Free function, unit-tested.
func pairRowLabel(_ original: String, _ replacement: String) -> String {
    "\(truncateLabel(original, n: 24)) → \(truncateLabel(replacement, n: 24))"
}

/// Add-button enablement. Pairs are applied as literal text substitutions
/// (see TermReplacer), never as prompt instructions, so they are NOT
/// sanitized or length-capped the way vocabulary terms are — a replacement
/// of `<div>` or a lone quote character is legitimate and must survive
/// verbatim. Only genuinely empty input is refused. Free function,
/// unit-tested.
func canAddPair(original: String, replacement: String) -> Bool {
    [original, replacement].allSatisfy {
        !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// The distinct right-hand sides of the user's pairs, in stable order —
/// several manglings of one word share a single target, so duplicates are
/// collapsed. Free function, unit-tested.
func distinctReplacementTargets(_ pairs: [ReplacementPair]) -> [String] {
    var seen = Set<String>()
    var targets: [String] = []
    for target in pairs.map(\.replacement) where seen.insert(target.lowercased()).inserted {
        targets.append(target)
    }
    return targets.sorted { $0.lowercased() < $1.lowercased() }
}

/// Detail line for a learned term row. Free function, unit-tested.
func glossaryRowDetail(count: Int, lastSeen: Date, now: Date = Date()) -> String {
    let days = Int(now.timeIntervalSince(lastSeen) / 86_400)
    let when = days <= 0 ? "today" : days == 1 ? "yesterday" : "\(days) days ago"
    return "seen \(count)× · \(when)"
}

/// Editor window for the user dictionary: manual replacement pairs on top,
/// the auto-learned glossary below. All mutations go through `AppModel`,
/// which forwards to `UserDictionaryStore` and refreshes the mirrored
/// `@Published` state via the store's onChange.
struct DictionaryWindow: View {
    @ObservedObject var model: AppModel
    @State private var newOriginal = ""
    @State private var newReplacement = ""

    /// Distinct correction targets already configured — what a heard
    /// mangling can be bound to.
    private var replacementTargets: [String] {
        distinctReplacementTargets(model.replacementPairs)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("scribe dictionary")
                .font(.title2)
                .bold()
            Text("Corrections and vocabulary the cleanup step applies to your dictations. Everything lives on this Mac.")
                .font(.callout)
                .foregroundStyle(.secondary)

            GroupBox("Replacements") {
                VStack(alignment: .leading, spacing: 8) {
                    if model.replacementPairs.isEmpty {
                        Text("No replacements yet — add one below.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.replacementPairs, id: \.original) { pair in
                            HStack {
                                Text(pairRowLabel(pair.original, pair.replacement))
                                Spacer()
                                Button {
                                    model.removeReplacementPair(pair.original)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .help("Remove this replacement")
                            }
                        }
                    }
                    HStack {
                        TextField("Heard as…", text: $newOriginal)
                        TextField("Replace with…", text: $newReplacement)
                        Button("Add") {
                            model.addReplacementPair(
                                original: newOriginal, replacement: newReplacement)
                            newOriginal = ""
                            newReplacement = ""
                        }
                        .disabled(!canAddPair(original: newOriginal, replacement: newReplacement))
                    }
                }
                .padding(4)
            }

            if !model.unmatchedHeardWords.isEmpty {
                GroupBox("Heard but not matched") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(replacementTargets.isEmpty
                            ? "Words scribe heard that it doesn't recognize. Add a replacement above, then bind these to it."
                            : "Words scribe heard that match nothing. If one is a mangling of a word you already correct, bind it — speech recognition mangles a name differently every time, and each spelling needs its own entry.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ScrollView {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(model.unmatchedHeardWords, id: \.term) { entry in
                                    HStack {
                                        Text(entry.term)
                                        Spacer()
                                        if !replacementTargets.isEmpty {
                                            Menu("Bind to…") {
                                                ForEach(replacementTargets, id: \.self) { target in
                                                    Button(target) {
                                                        model.bindHeardWord(
                                                            entry.term, toReplacement: target)
                                                    }
                                                }
                                            }
                                            .frame(width: 110)
                                        }
                                        Button {
                                            model.ignoreHeardWord(entry.term)
                                        } label: {
                                            Image(systemName: "xmark")
                                        }
                                        .buttonStyle(.borderless)
                                        .help("Ignore this word")
                                    }
                                }
                            }
                        }
                        .frame(maxHeight: 160)
                    }
                    .padding(4)
                }
            }

            GroupBox("Learned Terms") {
                VStack(alignment: .leading, spacing: 8) {
                    if model.glossaryEntries.isEmpty {
                        Text("Nothing learned yet — distinctive terms you dictate often will appear here.")
                            .foregroundStyle(.secondary)
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(model.glossaryEntries, id: \.term) { entry in
                                    HStack {
                                        Text(entry.term)
                                        Text(glossaryRowDetail(
                                            count: entry.count, lastSeen: entry.lastSeen))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                        Button {
                                            model.removeGlossaryTerm(entry.term)
                                        } label: {
                                            Image(systemName: "trash")
                                        }
                                        .buttonStyle(.borderless)
                                        .help("Forget this term")
                                    }
                                }
                            }
                        }
                        .frame(maxHeight: 220)
                    }
                    HStack {
                        Toggle(
                            "Learn new terms",
                            isOn: Binding(
                                get: { model.dictionaryLearningEnabled },
                                set: { model.setDictionaryLearning($0) }
                            )
                        )
                        Spacer()
                        Button("Clear Learned Terms") {
                            model.clearLearnedTerms()
                        }
                        .disabled(model.glossaryEntries.isEmpty)
                    }
                }
                .padding(4)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear { model.refreshDictionaryState() }
    }
}
