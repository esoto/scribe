import Foundation

/// A spoken trigger and the text it stands for. The expansion is pasted verbatim, line breaks included.
struct Snippet: Codable, Equatable, Identifiable {
    var trigger: String
    var expansion: String

    var id: String { trigger.lowercased() }
}

private struct SnippetsFile: Codable {
    var version: Int
    var snippets: [Snippet]
}

/// Snippets in `snippets.json` next to the dictionary. Expansions are plain text on disk — fine for an address,
/// not for a secret, and the editor says so. Thread-safe via a serial queue; `onChange` fires on that queue.
final class SnippetStore: @unchecked Sendable {
    static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/scribe/snippets.json")
    private static let fileVersion = 1
    static let maxSnippets = 50

    private let fileURL: URL
    private let queue = DispatchQueue(label: "dev.esoto.scribe.snippets")
    private var snippets: [Snippet] = []
    private var changeHandler: (() -> Void)?

    init(fileURL: URL = SnippetStore.defaultURL) {
        self.fileURL = fileURL
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        loadLocked()
    }

    var onChange: (() -> Void)? {
        get { queue.sync { changeHandler } }
        set { queue.sync { changeHandler = newValue } }
    }

    var all: [Snippet] { queue.sync { snippets } }

    /// What the matcher can actually see of a typed trigger: single-spaced, with the edge punctuation it strips
    /// from spoken tokens already gone, so "my address." is stored as the trigger that will fire.
    static func normalisedTrigger(_ trigger: String) -> String {
        func singleSpaced(_ text: String) -> String {
            text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        }
        // Trimming can strand a bracket behind a space ("( my email ) ."), so repeat until nothing changes.
        var current = singleSpaced(trigger)
        while true {
            let next = singleSpaced(TermReplacer.trimEdges(current))
            if next == current { return next }
            current = next
        }
    }

    /// An existing trigger (any case) is replaced. Line breaks are stored as `\n` so a pasted CRLF expansion is still
    /// one block.
    func upsert(trigger: String, expansion: String) {
        let t = Self.normalisedTrigger(trigger)
        let e = expansion
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .newlines)
        guard !t.isEmpty, !e.isEmpty else { return }
        let key = TermReplacer.words(t)
        queue.async {
            self.snippets.removeAll { TermReplacer.words($0.trigger) == key }
            self.snippets.append(Snippet(trigger: t, expansion: e))
            if self.snippets.count > Self.maxSnippets {
                self.snippets.removeFirst(self.snippets.count - Self.maxSnippets)
            }
            self.persistAndNotifyLocked()
        }
    }

    func remove(trigger: String) {
        queue.async {
            self.snippets.removeAll { $0.trigger == trigger }
            self.persistAndNotifyLocked()
        }
    }

    private func loadLocked() {
        guard let data = try? Data(contentsOf: fileURL),
            let file = try? JSONDecoder().decode(SnippetsFile.self, from: data),
            file.version == Self.fileVersion
        else { return }
        snippets = file.snippets
    }

    private func persistAndNotifyLocked() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(SnippetsFile(version: Self.fileVersion, snippets: snippets)) {
            try? data.write(to: fileURL, options: .atomic)
        }
        changeHandler?()
    }
}

/// Expands triggers after cleanup, so the model never sees an expansion and `Gates.normalize` never flattens its
/// line breaks. A multi-line expansion drops the sentence punctuation ASR put after a trigger that ends the text;
/// a one-line one keeps it.
enum SnippetExpander {
    static func apply(_ snippets: [Snippet], to text: String) -> String {
        TermReplacer.apply(
            entries: snippets.map { ($0.trigger, $0.expansion, !$0.expansion.contains(where: \.isNewline)) },
            to: text)
    }
}
