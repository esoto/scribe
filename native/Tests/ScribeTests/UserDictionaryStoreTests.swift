import XCTest

/// A mutable date clock injected into `UserDictionaryStore` — whole seconds
/// only, so dates survive the ISO-8601 persistence round-trip untouched.
private final class DateClock {
    var date = Date(timeIntervalSince1970: 1_000_000)
    func advance(days: Double) { date = date.addingTimeInterval(days * 86_400) }
}

final class UserDictionaryStoreTests: XCTestCase {
    private var dir: URL!
    private var clock: DateClock!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        clock = DateClock()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private var fileURL: URL { dir.appendingPathComponent("dictionary.json") }

    private func makeStore() -> UserDictionaryStore {
        UserDictionaryStore(fileURL: fileURL, now: { [clock] in clock!.date })
    }

    func testPromotionAtThirdDistinctDictation() {
        let store = makeStore()
        store.observe(cleanedText: "deploy with Kamal tonight")
        store.observe(cleanedText: "ask Kamal to restart it")
        XCTAssertEqual(store.snapshot.glossary, [])
        store.observe(cleanedText: "the Kamal config changed")
        XCTAssertEqual(store.snapshot.glossary, ["Kamal"])
    }

    func testOnChangeFiresWhenTheWordSetChangesButNotOnCountBumps() {
        let store = makeStore()
        let fired = Box<DictionarySnapshot>()
        store.onChange = { fired.append($0) }

        // First sighting introduces a word the editor now lists.
        store.observe(cleanedText: "check Kamal now")
        _ = store.snapshot
        XCTAssertEqual(fired.value.count, 1)

        // Re-hearing it changes only a count — nobody is told, which is what
        // keeps an open menu from redrawing on every dictation.
        store.observe(cleanedText: "check Kamal now")
        _ = store.snapshot
        XCTAssertEqual(store.snapshot.glossary, [])
        XCTAssertEqual(fired.value.count, 1)

        // Promotion moves it into the prompt, which is a snapshot change.
        store.observe(cleanedText: "check Kamal now")
        XCTAssertEqual(store.snapshot.glossary, ["Kamal"])
        XCTAssertEqual(fired.value.count, 2)
        XCTAssertEqual(fired.value.last?.glossary, ["Kamal"])

        store.observe(cleanedText: "check Kamal now")
        _ = store.snapshot
        XCTAssertEqual(fired.value.count, 2)
    }

    func testPersistenceRoundTrip() {
        let store = makeStore()
        store.addPair(original: "camel", replacement: "kamal")
        for _ in 0..<3 { store.observe(cleanedText: "warm the KVCache first") }
        store.observe(cleanedText: "we met Sofía twice")  // candidate, count 1
        _ = store.snapshot  // flush async mutations before reopening

        let reopened = makeStore()
        XCTAssertEqual(reopened.allPairs.map(\.original), ["camel"])
        XCTAssertEqual(reopened.allGlossaryEntries.map(\.term), ["KVCache"])
        XCTAssertEqual(reopened.allGlossaryEntries.first?.count, 3)
        // Candidate counts persist too: two more sightings promote.
        reopened.observe(cleanedText: "call Sofía back")
        reopened.observe(cleanedText: "tell Sofía thanks")
        XCTAssertEqual(Set(reopened.snapshot.glossary), ["KVCache", "Sofía"])
    }

    func testCandidateDecay() {
        let store = makeStore()
        store.observe(cleanedText: "mention Parakeet once")
        _ = store.snapshot  // flush before moving the clock
        clock.advance(days: 15)
        // The stale candidate is swept, so two fresh sightings total 2 — no promotion.
        store.observe(cleanedText: "mention Parakeet again")
        store.observe(cleanedText: "mention Parakeet more")
        XCTAssertEqual(store.snapshot.glossary, [])
        store.observe(cleanedText: "mention Parakeet final")
        XCTAssertEqual(store.snapshot.glossary, ["Parakeet"])
    }

    func testGlossaryDecay() {
        let store = makeStore()
        for _ in 0..<3 { store.observe(cleanedText: "ship with Kamal now") }
        XCTAssertEqual(store.snapshot.glossary, ["Kamal"])  // also flushes
        clock.advance(days: 61)
        store.observe(cleanedText: "something else with MLX inside")
        XCTAssertEqual(store.snapshot.glossary, [])
    }

    func testSnapshotCapsAndOrdering() {
        let store = makeStore()
        // 31 promoted terms; term00 gets an extra sighting so it must survive the cap.
        let terms = (0..<31).map { String(format: "Term%02dx", $0) }
        for term in terms {
            for _ in 0..<3 { store.observe(cleanedText: "we discussed \(term) today") }
        }
        store.observe(cleanedText: "back to Term00x again")
        let snap = store.snapshot
        XCTAssertEqual(snap.glossary.count, 30)
        XCTAssertTrue(snap.glossary.contains("Term00x"))
        XCTAssertEqual(snap.glossary, snap.glossary.sorted { $0.lowercased() < $1.lowercased() })

        // Pairs: 21 added, snapshot keeps the 20 newest, alphabetical.
        for i in 0..<21 {
            store.addPair(original: String(format: "orig%02d", i), replacement: "r")
            _ = store.snapshot  // flush so each pair gets a distinct addedAt
            clock.advance(days: 0.001)
        }
        let pairSnap = store.snapshot.pairs.map(\.original)
        XCTAssertEqual(pairSnap.count, 20)
        XCTAssertFalse(pairSnap.contains("orig00"))  // oldest fell off
        XCTAssertEqual(pairSnap, pairSnap.sorted())
    }

    func testStoredPairCap() {
        let store = makeStore()
        for i in 0..<55 {
            store.addPair(original: "orig\(i)", replacement: "r")
            _ = store.snapshot  // flush so each pair gets a distinct addedAt
            clock.advance(days: 0.001)
        }
        XCTAssertEqual(store.allPairs.count, 50)
        XCTAssertFalse(store.allPairs.map(\.original).contains("orig0"))
    }

    func testPairReplacementIsNotAddedToTheGlossary() {
        // Seeding a pair's replacement into the vocabulary was tried and
        // reverted: naming a term in both prompt sections made the model
        // drop words. A pair applies on its own.
        let store = makeStore()
        store.addPair(original: "camel", replacement: "kamal")
        XCTAssertEqual(store.snapshot.glossary, [])
        XCTAssertEqual(store.snapshot.pairs.map(\.replacement), ["kamal"])
    }

    func testLearnedTermMatchingAPairTargetIsExcludedFromTheGlossary() {
        // Same invariant from the other direction: a term can be learned AND
        // be a pair's replacement by coincidence. The pair already fixes the
        // spelling, so the vocabulary entry is redundant — and the vocabulary
        // section is the one known to cost words, so don't grow it needlessly.
        let store = makeStore()
        for _ in 0..<3 { store.observe(cleanedText: "ship it with Kamal today") }
        XCTAssertEqual(store.snapshot.glossary, ["Kamal"])
        store.addPair(original: "camel", replacement: "kamal")
        XCTAssertEqual(store.snapshot.glossary, [], "case-insensitive match with the pair target")
        XCTAssertEqual(store.allGlossaryEntries.map(\.term), ["Kamal"], "still stored, just not injected")
    }

    /// Fills the glossary past the 30-term snapshot cap, highest-count first,
    /// so terms[30...] are stored but never reach the prompt.
    private func makeOverCappedStore() -> (UserDictionaryStore, [String]) {
        let store = makeStore()
        let terms = (0..<40).map { String(format: "Term%02dx", $0) }
        for (i, term) in terms.enumerated() {
            for _ in 0..<(40 - i + 3) { store.observe(cleanedText: "we discussed \(term) today") }
        }
        _ = store.snapshot
        return (store, terms)
    }

    func testRemovingTermBelowPromptCapStillNotifies() {
        // The editor window lists every stored term, not just the 30 that
        // reach the prompt. Removing one of the others changes that list
        // without changing the snapshot — if it doesn't notify, the row
        // stays on screen after the user deletes it.
        let (store, terms) = makeOverCappedStore()
        let belowCap = terms[39]
        XCTAssertFalse(store.snapshot.glossary.contains(belowCap), "precondition: outside prompt")

        let fired = Box<DictionarySnapshot>()
        store.onChange = { fired.append($0) }
        store.removeGlossaryTerm(belowCap)
        _ = store.snapshot

        XCTAssertEqual(store.allGlossaryEntries.count, 39)
        XCTAssertEqual(fired.value.count, 1)
    }

    func testPromotionIntoFullGlossaryStillNotifies() {
        let (store, _) = makeOverCappedStore()
        let fired = Box<DictionarySnapshot>()
        store.onChange = { fired.append($0) }
        for _ in 0..<3 { store.observe(cleanedText: "brand new NewTermZ here") }
        _ = store.snapshot
        XCTAssertTrue(store.allGlossaryEntries.map(\.term).contains("NewTermZ"))
        XCTAssertEqual(fired.value.count, 1, "a promotion is visible in the editor even below the cap")
    }

    func testCountBumpsStillDoNotNotify() {
        // The other half of the contract: re-seeing a known term happens
        // every dictation and must stay silent.
        let store = makeStore()
        for _ in 0..<3 { store.observe(cleanedText: "ship with Kamal now") }
        _ = store.snapshot
        let fired = Box<DictionarySnapshot>()
        store.onChange = { fired.append($0) }
        for _ in 0..<5 { store.observe(cleanedText: "ship with Kamal now") }
        _ = store.snapshot
        XCTAssertEqual(fired.value.count, 0)
    }

    // MARK: - Heard-but-unmatched suggestions

    func testUnmatchedHeardWordsExcludesEverythingKnown() {
        let store = makeStore()
        store.addPair(original: "camel", replacement: "kamal")
        for _ in 0..<3 { store.observe(cleanedText: "the Postgres box is warm") }
        store.observe(cleanedText: "deploy to Headstar tonight")
        store.observe(cleanedText: "ask Camel about it")   // a pair original
        store.observe(cleanedText: "ping Kamal directly")  // a pair replacement

        let heard = store.unmatchedHeardWords.map(\.term)
        XCTAssertEqual(heard, ["Headstar"])
    }

    func testUnmatchedHeardWordsAreMostRecentFirst() {
        let store = makeStore()
        store.observe(cleanedText: "deploy to Headstar tonight")
        _ = store.snapshot
        clock.advance(days: 1)
        store.observe(cleanedText: "deploy to Hatsner tonight")
        XCTAssertEqual(store.unmatchedHeardWords.map(\.term), ["Hatsner", "Headstar"])
    }

    func testBindingAHeardWordRemovesItFromTheList() {
        let store = makeStore()
        store.addPair(original: "camel", replacement: "kamal")
        store.observe(cleanedText: "deploy to Headstar tonight")
        XCTAssertEqual(store.unmatchedHeardWords.map(\.term), ["Headstar"])

        // Binding is just another exact pair sharing the same target.
        store.addPair(original: "Headstar", replacement: "hetzner")
        XCTAssertEqual(store.unmatchedHeardWords, [])
        XCTAssertEqual(
            TermReplacer.apply(store.snapshot.pairs, to: "deploy to Headstar tonight"),
            "deploy to hetzner tonight")
    }

    func testIgnoringAHeardWordDropsIt() {
        let store = makeStore()
        store.observe(cleanedText: "deploy to Headstar tonight")
        let fired = Box<DictionarySnapshot>()
        store.onChange = { fired.append($0) }
        store.ignoreHeardWord("headstar")  // case-insensitive
        _ = store.snapshot
        XCTAssertEqual(store.unmatchedHeardWords, [])
        XCTAssertEqual(fired.value.count, 1, "the editor list changed, so it must notify")
    }

    func testWordsAreStillCollectedWhileLearningIsOff() {
        // Collection powers the suggestions; only injection is gated.
        let store = makeStore()
        store.learningEnabled = false
        for _ in 0..<3 { store.observe(cleanedText: "deploy to Headstar tonight") }
        XCTAssertEqual(store.unmatchedHeardWords.map(\.term), ["Headstar"])
        XCTAssertEqual(store.snapshot.glossary, [], "never injected while learning is off")
        store.learningEnabled = true
        store.observe(cleanedText: "one more Headstar mention")
        XCTAssertEqual(store.snapshot.glossary, ["Headstar"], "injected once enabled")
    }

    func testAddPairReplacesSameOriginal() {
        let store = makeStore()
        store.addPair(original: "camel", replacement: "kamal")
        store.addPair(original: "camel", replacement: "Kamal")
        XCTAssertEqual(store.allPairs.count, 1)
        XCTAssertEqual(store.allPairs.first?.replacement, "Kamal")
    }

    func testClearLearnedKeepsPairs() {
        let store = makeStore()
        store.addPair(original: "camel", replacement: "kamal")
        for _ in 0..<3 { store.observe(cleanedText: "use MLX here") }
        store.clearLearned()
        let snap = store.snapshot
        XCTAssertEqual(snap.glossary, [])
        XCTAssertTrue(store.allGlossaryEntries.isEmpty)
        XCTAssertEqual(snap.pairs.map(\.original), ["camel"])
        // Candidates were wiped too: promotion needs three fresh sightings.
        store.observe(cleanedText: "use MLX here")
        store.observe(cleanedText: "use MLX here")
        XCTAssertEqual(store.snapshot.glossary, [])
    }

    func testRemoveGlossaryTermAlsoDropsCandidate() {
        let store = makeStore()
        store.observe(cleanedText: "ping Whisper once")
        store.removeGlossaryTerm("Whisper")
        store.observe(cleanedText: "ping Whisper twice")
        store.observe(cleanedText: "ping Whisper thrice")
        XCTAssertEqual(store.snapshot.glossary, [])
    }

    func testLearningDisabledStopsPromotionNotCollection() {
        let store = makeStore()
        store.learningEnabled = false
        for _ in 0..<5 { store.observe(cleanedText: "loud Kamal noises") }
        XCTAssertEqual(store.snapshot.glossary, [], "nothing reaches the prompt")
        XCTAssertTrue(store.allGlossaryEntries.isEmpty, "nothing is promoted")
        XCTAssertEqual(
            store.unmatchedHeardWords.map(\.term), ["Kamal"],
            "but it is still offered as a bindable word")
    }

    func testCorruptFileStartsEmpty() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json {{{".utf8).write(to: fileURL)
        let store = makeStore()
        XCTAssertTrue(store.snapshot.isEmpty)
        store.addPair(original: "a1", replacement: "b")
        XCTAssertEqual(store.snapshot.pairs.count, 1)
    }

    func testFileOnDiskAfterMutation() throws {
        let store = makeStore()
        store.addPair(original: "camel", replacement: "kamal")
        _ = store.snapshot  // flush
        let data = try Data(contentsOf: fileURL)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"version\""))
        XCTAssertTrue(text.contains("camel"))
        XCTAssertFalse(text.contains("transcript"))
    }
}
