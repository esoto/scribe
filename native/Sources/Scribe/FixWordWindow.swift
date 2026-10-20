import AppKit
import SwiftUI

let fixWordWindowID = "fix-word"

/// LSUIElement apps must activate explicitly to bring the window forward.
func openFixWordWindow(_ openWindow: OpenWindowAction) {
    NSApp.activate(ignoringOtherApps: true)
    openWindow(id: fixWordWindowID)
}

/// History → Fix a Word…: click the misheard word (or several in a row) in a recent dictation, type what you said,
/// and the pair lands in the Dictionary. Reads the in-memory history; only the pair (words) is persisted.
struct FixWordWindow: View {
    @ObservedObject var dictionary: DictionaryModel
    let history: History
    @State private var records: [DictationRecord] = []
    @State private var selectedRecord: UUID?
    @State private var selectedWords: Set<Int> = []
    @State private var replacement = ""
    @State private var confirmation: String?

    private var record: DictationRecord? { records.first { $0.id == selectedRecord } ?? records.first }
    private var words: [String] { record.map { FixFromHistory.words(in: $0.raw) } ?? [] }
    private var heard: String? { FixFromHistory.heardPhrase(words: words, selected: selectedWords) }
    private var canFix: Bool {
        FixFromHistory.canFix(heard: heard, replacement: replacement, pairCount: dictionary.replacementPairs.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("scribe fix a word").font(.title2.bold())
            Text("Click the word scribe misheard — several in a row for a phrase — and type what you said. From now on every dictation gets the fix.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if records.isEmpty {
                Text("No dictations yet.").foregroundStyle(.secondary)
            } else {
                Picker("Dictation", selection: Binding(
                    get: { record?.id },
                    set: { selectedRecord = $0; selectedWords = []; confirmation = nil })
                ) {
                    ForEach(records) { r in
                        Text(truncateLabel(r.raw, n: 48)).tag(Optional(r.id))
                    }
                }
                WordChips(words: words, selected: selectedWords) { index in
                    selectedWords = FixFromHistory.toggling(index, in: selectedWords)
                    confirmation = nil
                }
                HStack {
                    Text(heard.map { "\u{201C}\($0)\u{201D} →" } ?? "Pick a word")
                        .foregroundStyle(heard == nil ? Color.secondary : Color.primary)
                    TextField("What you said…", text: $replacement)
                        .onSubmit(fix)
                    Button("Add Fix", action: fix)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canFix)
                }
                if let confirmation {
                    Text(confirmation).font(.caption).foregroundStyle(.secondary)
                }
                Text(atPairCap(dictionary.replacementPairs.count)
                    ? "The dictionary is full — remove a replacement to add another."
                    : "Stored in the Dictionary as words, never the dictation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(width: 480)
        .onAppear {
            records = history.items()
            WindowActivation.shared.windowAppeared()
        }
        .onDisappear { WindowActivation.shared.windowDisappeared() }
    }

    private func fix() {
        guard let heard, canFix else { return }
        let fixed = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        dictionary.addReplacementPair(original: heard, replacement: fixed)
        confirmation = "Added: \(pairRowLabel(heard, fixed))"
        selectedWords = []
        replacement = ""
    }
}

/// The words as toggle chips, wrapping onto as many lines as they need.
private struct WordChips: View {
    let words: [String]
    let selected: Set<Int>
    let toggle: (Int) -> Void

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                Button {
                    toggle(index)
                } label: {
                    Text(word)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(selected.contains(index) ? Color.accentColor : Color(nsColor: .controlBackgroundColor)))
                        .foregroundStyle(selected.contains(index) ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected.contains(index) ? .isSelected : [])
            }
        }
    }
}

/// Left-to-right rows that wrap at the proposed width; SwiftUI has no flow layout of its own.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
