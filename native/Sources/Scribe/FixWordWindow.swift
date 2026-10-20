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
            Text("Click the word scribe misheard — several in a row for a phrase — and type what you said. From now on, scribe fixes that spelling in every dictation.")
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
                ScrollView {
                    WordChips(words: words, selected: selectedWords) { index in
                        selectedWords = FixFromHistory.toggling(index, in: selectedWords)
                        confirmation = nil
                    }
                }
                .frame(maxHeight: 220)
                HStack {
                    Text(heard.map { "\u{201C}\($0)\u{201D} →" } ?? "Pick a word")
                        .foregroundStyle(heard == nil ? Color.secondary : Color.primary)
                    TextField("What you said…", text: $replacement)
                        .onSubmit(fix)
                    Button("Add Fix", action: fix)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canFix)
                        .accessibilityHint(heard.map { "Adds a replacement for \u{201C}\($0)\u{201D}" } ?? "Pick a word first")
                }
                if let confirmation {
                    Text(confirmation).font(.caption).foregroundStyle(.secondary)
                }
                Text(atPairCap(dictionary.replacementPairs.count)
                    ? "The Dictionary is full — remove a replacement to add another."
                    : "Only the words you pick and your fix are stored.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(width: 480)
        .onAppear {
            reload()
            WindowActivation.shared.windowAppeared()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in reload() }
        .onDisappear { WindowActivation.shared.windowDisappeared() }
    }

    /// History is not observable, so re-read it whenever a window comes forward. Word indices belong to the record
    /// they were picked in, so a change of shown record (newest moved, or the pick aged out) drops them.
    private func reload() {
        let shown = record?.id
        records = history.items()
        if record?.id != shown {
            selectedRecord = nil
            selectedWords = []
            confirmation = nil
        }
    }

    private func fix() {
        guard let heard, canFix else { return }
        let fixed = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        dictionary.addReplacementPair(original: heard, replacement: fixed)
        let message = "Added: \(pairRowLabel(heard, fixed))"
        confirmation = message
        AccessibilityNotification.Announcement(message).post()
        selectedWords = []
        replacement = ""
    }
}

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
                    Text(FixFromHistory.chipLabel(word))
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
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Words scribe heard")
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
            let size = view.sizeThatFits(ProposedViewSize(width: width, height: nil))
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
        let fit = ProposedViewSize(width: bounds.width, height: nil)
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(fit)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: fit)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
