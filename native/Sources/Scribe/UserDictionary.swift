import Foundation

/// A manual "heard X → write Y" correction, user-added only.
struct ReplacementPair: Codable, Equatable, Sendable {
    var original: String
    var replacement: String
    var addedAt: Date
}

/// A learned (or still-candidate) vocabulary term with its usage stats.
struct GlossaryEntry: Codable, Equatable, Sendable {
    var term: String
    var count: Int
    var firstSeen: Date
    var lastSeen: Date
}

/// The prompt-ready view of the dictionary: already capped and
/// deterministically ordered, so an equal snapshot renders a byte-identical
/// system prompt — the property the warm-prefix KV cache relies on.
struct DictionarySnapshot: Equatable, Sendable {
    var pairs: [ReplacementPair]
    var glossary: [String]

    static let empty = DictionarySnapshot(pairs: [], glossary: [])
    var isEmpty: Bool { pairs.isEmpty && glossary.isEmpty }
}

/// On-disk schema for the dictionary file.
private struct DictionaryFile: Codable {
    var version: Int
    var pairs: [ReplacementPair]
    var glossary: [GlossaryEntry]
    var candidates: [GlossaryEntry]
}

/// Owns the user dictionary: manual replacement pairs plus the auto-learned
/// glossary (candidates promote after appearing in enough distinct
/// dictations, decay when stale). Persists words only — never transcripts;
/// `History` stays in-memory by design.
///
/// Thread-safe via a private serial queue (`FileLogger`/`History` style):
/// reads are `queue.sync`, mutations `queue.async`. `onChange` fires on the
/// internal queue and ONLY when the prompt-facing snapshot actually changed —
/// candidate count bumps below the promotion threshold fire nothing, which is
/// what keeps the cleanup model's warm prefix stable between term changes.
final class UserDictionaryStore: @unchecked Sendable {
    static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/scribe/dictionary.json")

    private static let fileVersion = 1
    private static let promotionThreshold = 3
    private static let candidateDecayDays = 14.0
    private static let glossaryDecayDays = 60.0
    private static let maxStoredCandidates = 200
    private static let maxStoredGlossary = 200
    private static let maxStoredPairs = 50
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
    private var changeHandler: ((DictionarySnapshot) -> Void)?

    init(fileURL: URL = UserDictionaryStore.defaultURL, now: @escaping () -> Date = Date.init) {
        self.fileURL = fileURL
        self.now = now
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        loadLocked()
        decayLocked()
        capLocked()
        lastSnapshot = computeSnapshotLocked()
    }

    /// Fired on the store's internal queue whenever the snapshot changes —
    /// hop to the main actor before touching UI state, and do not call back
    /// into the store synchronously from inside the handler.
    var onChange: ((DictionarySnapshot) -> Void)? {
        get { queue.sync { changeHandler } }
        set { queue.sync { changeHandler = newValue } }
    }

    /// Runtime learning switch (persistence of the preference belongs to
    /// `AppSettings`). When off, `observe` is a no-op.
    var learningEnabled: Bool {
        get { queue.sync { enabled } }
        set { queue.sync { enabled = newValue } }
    }

    var snapshot: DictionarySnapshot { queue.sync { lastSnapshot } }
    var allPairs: [ReplacementPair] { queue.sync { pairs } }
    var allGlossaryEntries: [GlossaryEntry] { queue.sync { glossary } }

    /// Learns from the final text of one successfully cleaned dictation.
    func observe(cleanedText: String) {
        queue.async {
            guard self.enabled else { return }
            let terms = GlossaryHarvester.candidates(in: cleanedText)
            guard !terms.isEmpty else { return }
            // Sweep BEFORE counting: a stale candidate must not be
            // resurrected by the sighting that should have found it expired.
            self.decayLocked()
            let t = self.now()
            for term in terms {
                if let i = self.glossary.firstIndex(where: { $0.term == term }) {
                    self.glossary[i].count += 1
                    self.glossary[i].lastSeen = t
                } else if let i = self.candidates.firstIndex(where: { $0.term == term }) {
                    self.candidates[i].count += 1
                    self.candidates[i].lastSeen = t
                    if self.candidates[i].count >= Self.promotionThreshold {
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

    /// Adds (or replaces, matching on `original`) a manual pair. Inputs are
    /// stored verbatim apart from whitespace trimming; prompt-side
    /// sanitization happens at render time in `CleanupPrompt`.
    func addPair(original: String, replacement: String) {
        let o = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let r = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !o.isEmpty, !r.isEmpty else { return }
        queue.async {
            self.pairs.removeAll { $0.original == o }
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

    /// Wipes everything auto-learned; manual pairs survive.
    func clearLearned() {
        queue.async {
            self.glossary.removeAll()
            self.candidates.removeAll()
            self.persistAndNotifyLocked()
        }
    }

    // MARK: - Internals (call only on `queue`, or from init)

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
        let file = DictionaryFile(
            version: Self.fileVersion, pairs: pairs, glossary: glossary, candidates: candidates)
        if let data = try? encoder.encode(file) {
            try? data.write(to: fileURL, options: .atomic)
        }
        let snap = computeSnapshotLocked()
        if snap != lastSnapshot {
            lastSnapshot = snap
            changeHandler?(snap)
        }
    }

    private func decayLocked() {
        let t = now()
        func stale(_ entry: GlossaryEntry, days: Double) -> Bool {
            t.timeIntervalSince(entry.lastSeen) > days * 86_400
        }
        candidates.removeAll { stale($0, days: Self.candidateDecayDays) }
        glossary.removeAll { stale($0, days: Self.glossaryDecayDays) }
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
        let learned = glossary.sorted(by: Self.byUsage)
            .prefix(Self.snapshotGlossaryCap)
            .map(\.term)

        // A manual pair exists precisely because the STT mangles that word —
        // and it mangles it differently each time ("Hetzner" came back as
        // Headstar / Hatsner / Heftner / Headsnar in one session), so the
        // pair's exact left side can never cover every variant. Seeding the
        // replacement into the vocabulary hands the job to the prompt's
        // "or a close mishearing of one" clause, which generalizes.
        // Replacements come first so they win the case-insensitive dedupe:
        // an explicit user spelling beats a learned one.
        var terms: [String] = []
        var seen = Set<String>()
        for term in topPairs.map(\.replacement) + learned
        where !term.trimmingCharacters(in: .whitespaces).isEmpty {
            if seen.insert(term.lowercased()).inserted { terms.append(term) }
        }
        return DictionarySnapshot(
            pairs: Array(topPairs), glossary: terms.sorted(by: Self.alphabetical))
    }

    /// Highest count first, most recently seen breaking ties.
    private static func byUsage(_ a: GlossaryEntry, _ b: GlossaryEntry) -> Bool {
        a.count != b.count ? a.count > b.count : a.lastSeen > b.lastSeen
    }

    /// Case-insensitive but fully deterministic (exact string breaks ties).
    private static func alphabetical(_ a: String, _ b: String) -> Bool {
        let la = a.lowercased()
        let lb = b.lowercased()
        return la != lb ? la < lb : a < b
    }
}
