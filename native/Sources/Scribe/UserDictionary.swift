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
    private var lastStructure = Structure.empty
    private var changeHandler: ((DictionarySnapshot) -> Void)?

    /// Identity of everything the editor window lists: which terms and
    /// pairs exist, ignoring counts. Kept separate from the snapshot
    /// because the two answer different questions — the snapshot is what
    /// the model sees (capped at 30 terms), this is what the user sees
    /// (everything stored). A term can be added or removed below the cap,
    /// changing the list without changing the prompt.
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
        decayLocked()
        capLocked()
        lastSnapshot = computeSnapshotLocked()
        lastStructure = computeStructureLocked()
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

    /// Words heard in dictations that match nothing the dictionary knows —
    /// no replacement, no learned term. Speech recognition mangles an
    /// unfamiliar name differently on every attempt, so these are mostly
    /// one-off manglings of words the user has ALREADY corrected once
    /// ("Headstar", "Hatsner", "Heftner" for one "hetzner"), which an
    /// exact-match pair can never catch. Offering them for binding is the
    /// only safe way to close that gap: edit distance can't separate a real
    /// variant from an ordinary word ("header" sits closer to "headsner"
    /// than "Heftner" does), so a human confirms instead.
    ///
    /// Most recently heard first — a mangling you just saw is the one you
    /// want to fix.
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

    /// Drops a heard word without binding it — it was noise, not a mangling.
    func ignoreHeardWord(_ term: String) {
        queue.async {
            self.candidates.removeAll { $0.term.lowercased() == term.lowercased() }
            self.persistAndNotifyLocked()
        }
    }

    /// Learns from the final text of one successfully cleaned dictation.
    func observe(cleanedText: String) {
        queue.async {
            // Collection is NOT gated by `enabled`. Recording which words
            // were heard is local, words-only, and harmless — it's what
            // powers the "heard but unmatched" suggestions, which are the
            // useful half of this feature. `enabled` gates only whether
            // learned terms are handed to the cleanup model, which is the
            // half known to cost words. See `computeSnapshotLocked`.
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
                    // Promotion is gated, collection is not. With learning
                    // off a word stays a candidate forever, which is what
                    // keeps it offered as a bindable mangling instead of
                    // quietly becoming "known vocabulary" nobody asked for.
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
        // Two independent reasons to notify, and both matter:
        //   - the snapshot moved  -> the model's prompt changes, so the
        //     cleanup backend must rebuild its cached prompt prefix;
        //   - the structure moved -> a term or pair the editor window
        //     lists appeared or vanished, even if it never reached the
        //     prompt (removing a term ranked below the 30-term cap, or
        //     promoting one into a full glossary).
        // Notifying on only the first left the editor showing rows that no
        // longer existed. Plain count bumps deliberately notify on
        // NEITHER: those happen every dictation, and republishing that
        // often can close an open menu.
        let snap = computeSnapshotLocked()
        let structure = computeStructureLocked()
        guard snap != lastSnapshot || structure != lastStructure else { return }
        lastSnapshot = snap
        lastStructure = structure
        changeHandler?(snap)
    }

    private func computeStructureLocked() -> Structure {
        Structure(
            // Candidates are included so a newly heard word appears in the
            // editor's suggestion list while the window is open. Only the
            // SET of words counts, never their counts, so the common case —
            // re-hearing a word already known — still notifies nobody.
            terms: (glossary.map(\.term) + candidates.map(\.term)).sorted(),
            pairs: pairs.map { "\($0.original)=>\($0.replacement)" }.sorted())
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
        // INVARIANT: a term is never named in both the replacement list and
        // the vocabulary list. Measured against the real model, naming one
        // in both makes it get dropped from the sentence outright — see
        // DictionaryFidelityTests. Seeding pair replacements INTO the
        // vocabulary (tried, reverted) violated this maximally; a term that
        // is both learned and a pair target violates it by coincidence, so
        // filter those out here. The pair already guarantees the spelling,
        // which is all the vocabulary entry would have added.
        guard enabled else {
            // Learned vocabulary withheld from the prompt — see
            // AppSettings.dictionaryLearningEnabled. Terms stay stored and
            // visible in the editor; they just aren't injected.
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
