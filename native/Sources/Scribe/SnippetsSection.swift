import AppKit
import SwiftUI

/// The Dictionary window's view of the snippet store.
@MainActor
final class SnippetsModel: ObservableObject {
    @Published private(set) var snippets: [Snippet]

    private let store: SnippetStore

    init(store: SnippetStore) {
        self.store = store
        snippets = store.all
        store.onChange = { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        let fresh = store.all
        if fresh != snippets { snippets = fresh }
    }

    func add(trigger: String, expansion: String) { store.upsert(trigger: trigger, expansion: expansion) }
    func remove(_ snippet: Snippet) { store.remove(trigger: snippet.trigger) }
}

/// A row: the trigger and the first line of the expansion, with a mark when there is more.
func snippetRowLabel(_ snippet: Snippet) -> String {
    let firstLine = snippet.expansion.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
    let more = snippet.expansion.contains("\n") ? " …" : ""
    return "\(truncateLabel(snippet.trigger, n: 20)) → \(truncateLabel(firstLine, n: 28))\(more)"
}

func canAddSnippet(trigger: String, expansion: String, count: Int) -> Bool {
    !trigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && !expansion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && count < SnippetStore.maxSnippets
}

struct SnippetsSection: View {
    @ObservedObject var model: SnippetsModel
    @State private var trigger = ""
    @State private var expansion = ""

    var body: some View {
        GroupBox("Snippets") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Say the trigger — alone or inside a sentence — and the text takes its place after cleanup. Stored in plain text in snippets.json: fine for an address, not for a password.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if model.snippets.isEmpty {
                    Text("No snippets yet — add one below.").foregroundStyle(.secondary)
                } else {
                    ForEach(model.snippets) { snippet in
                        HStack {
                            Text(snippetRowLabel(snippet))
                            Spacer()
                            Button {
                                model.remove(snippet)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("Remove this snippet")
                            .accessibilityLabel("Remove snippet \(snippet.trigger)")
                        }
                        .help(snippet.expansion)
                    }
                }
                TextField("Trigger — e.g. my address", text: $trigger)
                TextEditor(text: $expansion)
                    .font(.body)
                    .frame(height: 60)
                    .border(Color(nsColor: .separatorColor))
                    .accessibilityLabel("Expansion")
                HStack {
                    Text("\(model.snippets.count) of \(SnippetStore.maxSnippets) snippets")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Add Snippet", action: add)
                        .disabled(!canAddSnippet(trigger: trigger, expansion: expansion, count: model.snippets.count))
                }
            }
            .padding(4)
        }
    }

    private func add() {
        guard canAddSnippet(trigger: trigger, expansion: expansion, count: model.snippets.count) else { return }
        model.add(trigger: trigger, expansion: expansion)
        trigger = ""
        expansion = ""
    }
}
