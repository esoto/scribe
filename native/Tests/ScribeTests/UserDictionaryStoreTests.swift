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

    func testOnChangeFiresOnlyOnSnapshotChange() {
        let store = makeStore()
        let fired = Box<DictionarySnapshot>()
        store.onChange = { fired.append($0) }
        store.observe(cleanedText: "check Kamal now")
        store.observe(cleanedText: "check Kamal now")
        XCTAssertEqual(store.snapshot.glossary, [])
        XCTAssertEqual(fired.value.count, 0)
        store.observe(cleanedText: "check Kamal now")
        XCTAssertEqual(store.snapshot.glossary, ["Kamal"])
        XCTAssertEqual(fired.value.count, 1)
        XCTAssertEqual(fired.value.first?.glossary, ["Kamal"])
        // A fourth sighting bumps counts but not the snapshot — no callback.
        store.observe(cleanedText: "check Kamal now")
        _ = store.snapshot
        XCTAssertEqual(fired.value.count, 1)
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
        // "kamal" rides along as the seeded replacement of the saved pair.
        XCTAssertEqual(Set(reopened.snapshot.glossary), ["KVCache", "Sofía", "kamal"])
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

    func testPairReplacementSeedsGlossary() {
        // A manual pair exists because the STT mangles that word — and it
        // mangles it DIFFERENTLY each time, so the pair's exact left side
        // can't cover every variant. Seeding the replacement into the
        // vocabulary lets the prompt's "close mishearing" clause do it.
        let store = makeStore()
        store.addPair(original: "camel", replacement: "kamal")
        XCTAssertEqual(store.snapshot.glossary, ["kamal"])
    }

    func testSeededTermIsDedupedAgainstLearnedTerm() {
        let store = makeStore()
        for _ in 0..<3 { store.observe(cleanedText: "ship it with Kamal today") }
        XCTAssertEqual(store.snapshot.glossary, ["Kamal"])
        store.addPair(original: "camel", replacement: "kamal")
        // One entry, not two spellings of the same word; the user's explicit
        // replacement wins over the learned casing.
        XCTAssertEqual(store.snapshot.glossary, ["kamal"])
    }

    func testRemovingPairDropsItsSeededTerm() {
        let store = makeStore()
        store.addPair(original: "camel", replacement: "kamal")
        XCTAssertEqual(store.snapshot.glossary, ["kamal"])
        store.removePair(original: "camel")
        XCTAssertEqual(store.snapshot.glossary, [])
    }

    func testSeededTermsSortAlphabeticallyWithLearnedOnes() {
        let store = makeStore()
        for _ in 0..<3 { store.observe(cleanedText: "deploy to Hetzner nightly") }
        store.addPair(original: "camel", replacement: "kamal")
        store.addPair(original: "zed", replacement: "Ansible")
        XCTAssertEqual(store.snapshot.glossary, ["Ansible", "Hetzner", "kamal"])
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
        // "MLX" is forgotten; "kamal" survives only as the surviving pair's
        // seeded replacement, not as a learned term.
        XCTAssertEqual(snap.glossary, ["kamal"])
        XCTAssertTrue(store.allGlossaryEntries.isEmpty)
        XCTAssertEqual(snap.pairs.map(\.original), ["camel"])
        // Candidates were wiped too: promotion needs three fresh sightings,
        // so "MLX" stays absent and only the seeded "kamal" remains.
        store.observe(cleanedText: "use MLX here")
        store.observe(cleanedText: "use MLX here")
        XCTAssertEqual(store.snapshot.glossary, ["kamal"])
    }

    func testRemoveGlossaryTermAlsoDropsCandidate() {
        let store = makeStore()
        store.observe(cleanedText: "ping Whisper once")
        store.removeGlossaryTerm("Whisper")
        store.observe(cleanedText: "ping Whisper twice")
        store.observe(cleanedText: "ping Whisper thrice")
        XCTAssertEqual(store.snapshot.glossary, [])
    }

    func testLearningDisabledIsNoOp() {
        let store = makeStore()
        store.learningEnabled = false
        for _ in 0..<5 { store.observe(cleanedText: "loud Kamal noises") }
        XCTAssertEqual(store.snapshot.glossary, [])
        XCTAssertTrue(store.allGlossaryEntries.isEmpty)
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
