import Foundation

struct ReplacementPair: Codable, Equatable, Sendable {
    var original: String
    var replacement: String
    var addedAt: Date
}

struct GlossaryEntry: Codable, Equatable, Sendable {
    var term: String
    var count: Int
    var firstSeen: Date
    var lastSeen: Date
}

/// Capped and deterministically ordered so an equal snapshot renders a byte-identical prompt (warm-prefix KV cache relies on it).
struct DictionarySnapshot: Equatable, Sendable {
    var pairs: [ReplacementPair]
    var glossary: [String]

    static let empty = DictionarySnapshot(pairs: [], glossary: [])
    var isEmpty: Bool { pairs.isEmpty && glossary.isEmpty }
}

private struct DictionaryFile: Codable {
    var version: Int
    var pairs: [ReplacementPair]
    var glossary: [GlossaryEntry]
    var candidates: [GlossaryEntry]
}

/// Owns manual replacement pairs and the auto-learned glossary. Persists words only, never transcripts.
/// Thread-safe via a private serial queue. `onChange` fires on that queue and only when the prompt-facing snapshot changes, keeping the warm prefix stable.
final class UserDictionaryStore: @unchecked Sendable {
    static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/scribe/dictionary.json")

    private static let fileVersion = 1
    private static let promotionThreshold = 3
    private static let candidateDecayDays = 14.0
    private static let glossaryDecayDays = 60.0
    private static let maxStoredCandidates = 200
    private static let maxStoredGlossary = 200
    static let maxStoredPairs = 50
    private static let snapshotPairCap = 20
    private static let snapshotGlossaryCap = 30

    private let fileURL: URL
    private let now: () -> Date
    private let queue = DispatchQueue(label: "dev.esoto.scribe.dictionary")

    private var pairs: [ReplacementPair] = []
    private var glossary: [GlossaryEntry] = []
    private var candidates: [GlossaryEntry] = []
    private var enabled = true
    private var lastSnapshot = DictionarySnapshot.empty
    private var lastStructure = Structure.empty
    private var changeHandler: ((DictionarySnapshot) -> Void)?

    /// Everything the editor lists (terms and pairs, ignoring counts); separate from the snapshot, which is capped at 30 terms.
    private struct Structure: Equatable {
        var terms: [String]
        var pairs: [String]
        static let empty = Structure(terms: [], pairs: [])
    }

    init(fileURL: URL = UserDictionaryStore.defaultURL, now: @escaping () -> Date = Date.init) {
        self.fileURL = fileURL
        self.now = now
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        loadLocked()
        // The learning flag isn't set yet; its setter ages the glossary once it is.
        decayLocked(includingGlossary: false)
        capLocked()
        lastSnapshot = computeSnapshotLocked()
        lastStructure = computeStructureLocked()
    }

    /// Fires on the internal queue; hop to the main actor for UI and never call back into the store synchronously.
    var onChange: ((DictionarySnapshot) -> Void)? {
        get { queue.sync { changeHandler } }
        set { queue.sync { changeHandler = newValue } }
    }

    /// Runtime learning switch; when off, nothing learned is written to disk, the glossary is frozen, and no candidate is promoted.
    var learningEnabled: Bool {
        get { queue.sync { enabled } }
        set {
            queue.sync {
                let wasEnabled = enabled
                enabled = newValue
                if newValue {
                    // Words heard while off must neither reach disk nor count toward promotion.
                    if !wasEnabled { candidates.removeAll() }
                    decayLocked()
                    notifyIfChangedLocked()
                } else {
                    // Persisting rewrites the file without candidates, purging any left by an earlier run.
                    candidates.removeAll()
                    persistAndNotifyLocked()
                }
            }
        }
    }

    var snapshot: DictionarySnapshot { queue.sync { lastSnapshot } }
    var allPairs: [ReplacementPair] { queue.sync { pairs } }
    var allGlossaryEntries: [GlossaryEntry] { queue.sync { glossary } }

    /// Heard words that match nothing known. ASR mangles unfamiliar names differently each time, and edit distance can't separate variants from ordinary words, so the user confirms binding.
    /// Most recently heard first.
    var unmatchedHeardWords: [GlossaryEntry] {
        queue.sync {
            var known = Set(glossary.map { $0.term.lowercased() })
            for pair in pairs {
                known.insert(pair.original.lowercased())
                known.insert(pair.replacement.lowercased())
            }
            return candidates
                .filter { !known.contains($0.term.lowercased()) }
                .sorted { $0.lastSeen > $1.lastSeen }
        }
    }

    func ignoreHeardWord(_ term: String) {
        queue.async {
            self.candidates.removeAll { $0.term.lowercased() == term.lowercased() }
            self.persistAndNotifyLocked()
        }
    }

    func observe(cleanedText: String) {
        queue.async {
            // Collection runs with learning off too — it powers the "heard but unmatched" suggestions — but is held in memory only; persistence and promotion are gated by `enabled`.
            let terms = GlossaryHarvester.candidates(in: cleanedText)
            guard !terms.isEmpty else { return }
            // Sweep before counting so a stale candidate isn't resurrected by the sighting.
            self.decayLocked()
            let t = self.now()
            for term in terms {
                if let i = self.glossary.firstIndex(where: { $0.term == term }) {
                    // Use-counts and recency are learning too, so they freeze with it.
                    guard self.enabled else { continue }
                    self.glossary[i].count += 1
                    self.glossary[i].lastSeen = t
                } else if let i = self.candidates.firstIndex(where: { $0.term == term }) {
                    self.candidates[i].count += 1
                    self.candidates[i].lastSeen = t
                    // Promotion is gated, collection is not: with learning off a word stays a bindable candidate.
                    if self.enabled, self.candidates[i].count >= Self.promotionThreshold {
                        self.glossary.append(self.candidates.remove(at: i))
                    }
                } else {
                    self.candidates.append(
                        GlossaryEntry(term: term, count: 1, firstSeen: t, lastSeen: t))
                }
            }
            self.capLocked()
            self.persistAndNotifyLocked()
        }
    }

    func addPair(original: String, replacement: String) {
        // Single-spaced like the matcher sees it; case is kept for display only.
        let o = original.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let r = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !o.isEmpty, !r.isEmpty else { return }
        let key = TermReplacer.words(o)
        queue.async {
            // Matching ignores case, so "Camel" and "camel" must not coexist.
            self.pairs.removeAll { TermReplacer.words($0.original) == key }
            self.pairs.append(ReplacementPair(original: o, replacement: r, addedAt: self.now()))
            self.capLocked()
            self.persistAndNotifyLocked()
        }
    }

    func removePair(original: String) {
        queue.async {
            self.pairs.removeAll { $0.original == original }
            self.persistAndNotifyLocked()
        }
    }

    func removeGlossaryTerm(_ term: String) {
        queue.async {
            self.glossary.removeAll { $0.term == term }
            self.candidates.removeAll { $0.term == term }
            self.persistAndNotifyLocked()
        }
    }

    func clearLearned() {
        queue.async {
            self.glossary.removeAll()
            self.candidates.removeAll()
            self.persistAndNotifyLocked()
        }
    }

    private func loadLocked() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let file = try? decoder.decode(DictionaryFile.self, from: data),
            file.version == Self.fileVersion
        else { return }
        pairs = file.pairs
        glossary = file.glossary
        candidates = file.candidates
    }

    private func persistAndNotifyLocked() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        // Unpromoted words stay in memory while learning is off; the README promises nothing new reaches disk.
        let file = DictionaryFile(
            version: Self.fileVersion, pairs: pairs, glossary: glossary,
            candidates: enabled ? candidates : [])
        if let data = try? encoder.encode(file) {
            try? data.write(to: fileURL, options: .atomic)
        }
        notifyIfChangedLocked()
    }

    private func notifyIfChangedLocked() {
        // Notify when the snapshot moved (prompt prefix must rebuild) or the editor-visible structure moved; plain count bumps notify neither (republishing can close an open menu).
        let snap = computeSnapshotLocked()
        let structure = computeStructureLocked()
        guard snap != lastSnapshot || structure != lastStructure else { return }
        lastSnapshot = snap
        lastStructure = structure
        changeHandler?(snap)
    }

    private func computeStructureLocked() -> Structure {
        Structure(
            // Candidates are included so new words show in the editor's suggestions; only the set of words counts, not counts.
            terms: (glossary.map(\.term) + candidates.map(\.term)).sorted(),
            pairs: pairs.map { "\($0.original)=>\($0.replacement)" }.sorted())
    }

    /// Candidates always age out. The glossary is skipped while learning is off, so switching it off never erodes learned terms.
    private func decayLocked(includingGlossary: Bool = true) {
        let t = now()
        func stale(_ entry: GlossaryEntry, days: Double) -> Bool {
            t.timeIntervalSince(entry.lastSeen) > days * 86_400
        }
        candidates.removeAll { stale($0, days: Self.candidateDecayDays) }
        if includingGlossary, enabled {
            glossary.removeAll { stale($0, days: Self.glossaryDecayDays) }
        }
    }

    private func capLocked() {
        if candidates.count > Self.maxStoredCandidates {
            candidates = Array(candidates.sorted(by: Self.byUsage).prefix(Self.maxStoredCandidates))
        }
        if glossary.count > Self.maxStoredGlossary {
            glossary = Array(glossary.sorted(by: Self.byUsage).prefix(Self.maxStoredGlossary))
        }
        if pairs.count > Self.maxStoredPairs {
            pairs = Array(
                pairs.sorted { $0.addedAt > $1.addedAt }.prefix(Self.maxStoredPairs))
        }
    }

    private func computeSnapshotLocked() -> DictionarySnapshot {
        let topPairs = pairs.sorted { $0.addedAt > $1.addedAt }
            .prefix(Self.snapshotPairCap)
            .sorted { Self.alphabetical($0.original, $1.original) }
        // INVARIANT: a term never appears in both the replacement list and the vocabulary list; the real model drops it from the sentence (see DictionaryFidelityTests).
        guard enabled else {
            // Learned vocabulary withheld from the prompt when learning is off (see AppSettings.dictionaryLearningEnabled).
            return DictionarySnapshot(pairs: Array(topPairs), glossary: [])
        }
        let pairTargets = Set(topPairs.map { $0.replacement.lowercased() })
        let learned = glossary.sorted(by: Self.byUsage)
            .map(\.term)
            .filter { !pairTargets.contains($0.lowercased()) }
            .prefix(Self.snapshotGlossaryCap)
            .sorted(by: Self.alphabetical)
        return DictionarySnapshot(pairs: Array(topPairs), glossary: Array(learned))
    }

    private static func byUsage(_ a: GlossaryEntry, _ b: GlossaryEntry) -> Bool {
        a.count != b.count ? a.count > b.count : a.lastSeen > b.lastSeen
    }

    private static func alphabetical(_ a: String, _ b: String) -> Bool {
        let la = a.lowercased()
        let lb = b.lowercased()
        return la != lb ? la < lb : a < b
    }
}
