import AppKit
import SwiftUI

let dictionaryWindowID = "dictionary"

/// LSUIElement apps must activate explicitly to bring the window forward.
func openDictionaryWindow(_ openWindow: OpenWindowAction) {
    NSApp.activate(ignoringOtherApps: true)
    openWindow(id: dictionaryWindowID)
}

func pairRowLabel(_ original: String, _ replacement: String) -> String {
    "\(truncateLabel(original, n: 24)) → \(truncateLabel(replacement, n: 24))"
}

/// Pairs are literal substitutions, so unlike vocabulary terms they are never sanitized or capped.
func canAddPair(original: String, replacement: String) -> Bool {
    [original, replacement].allSatisfy {
        !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

func atPairCap(_ count: Int) -> Bool { count >= UserDictionaryStore.maxStoredPairs }

func distinctReplacementTargets(_ pairs: [ReplacementPair]) -> [String] {
    var seen = Set<String>()
    var targets: [String] = []
    for target in pairs.map(\.replacement) where seen.insert(target.lowercased()).inserted {
        targets.append(target)
    }
    return targets.sorted { $0.lowercased() < $1.lowercased() }
}

func glossaryRowDetail(count: Int, lastSeen: Date, now: Date = Date()) -> String {
    let days = Int(now.timeIntervalSince(lastSeen) / 86_400)
    let when = days <= 0 ? "today" : days == 1 ? "yesterday" : "\(days) days ago"
    return "seen \(count)× · \(when)"
}

/// Mutations go through `DictionaryModel`, which forwards to `UserDictionaryStore`.
struct DictionaryWindow: View {
    @ObservedObject var model: DictionaryModel
    @State private var newOriginal = ""
    @State private var newReplacement = ""

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
                        .disabled(
                            !canAddPair(original: newOriginal, replacement: newReplacement)
                                || atPairCap(model.replacementPairs.count))
                    }
                    Text(atPairCap(model.replacementPairs.count)
                        ? "Remove one to add another."
                        : "\(model.replacementPairs.count) of \(UserDictionaryStore.maxStoredPairs) replacements")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                                            .disabled(atPairCap(model.replacementPairs.count))
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
