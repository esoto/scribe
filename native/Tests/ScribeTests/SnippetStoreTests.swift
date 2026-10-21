import XCTest

final class SnippetStoreTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func makeStore() -> SnippetStore { SnippetStore(fileURL: dir.appendingPathComponent("snippets.json")) }

    private let address = "12 Elm St\nSpringfield"

    func testUpsertNormalisesTheTriggerAndReplacesByTrigger() {
        let store = makeStore()
        store.upsert(trigger: "  my   address ", expansion: address + "\n")
        store.upsert(trigger: "My Address", expansion: "elsewhere")
        XCTAssertEqual(store.all, [Snippet(trigger: "My Address", expansion: "elsewhere")])
    }

    func testBlankTriggerOrExpansionIsIgnored() {
        let store = makeStore()
        store.upsert(trigger: " ", expansion: "x")
        store.upsert(trigger: "x", expansion: "\n")
        XCTAssertEqual(store.all, [])
    }

    func testRemovePersistsAndReloads() {
        let store = makeStore()
        store.upsert(trigger: "my address", expansion: address)
        store.upsert(trigger: "my email", expansion: "e@example.com")
        store.remove(trigger: "my email")
        XCTAssertEqual(store.all.map(\.trigger), ["my address"])
        XCTAssertEqual(makeStore().all, [Snippet(trigger: "my address", expansion: address)])
    }

    func testCapDropsTheOldest() {
        let store = makeStore()
        for i in 0..<(SnippetStore.maxSnippets + 2) {
            store.upsert(trigger: "t\(i)", expansion: "e")
        }
        XCTAssertEqual(store.all.count, SnippetStore.maxSnippets)
        XCTAssertEqual(store.all.first?.trigger, "t2")
    }

    func testOnChangeFiresAfterAWrite() {
        let store = makeStore()
        let fired = expectation(description: "onChange")
        store.onChange = { fired.fulfill() }
        store.upsert(trigger: "my address", expansion: address)
        wait(for: [fired], timeout: 2)
    }

    // MARK: - Expander

    private var snippets: [Snippet] {
        [Snippet(trigger: "my address", expansion: address), Snippet(trigger: "my email", expansion: "e@example.com")]
    }

    func testWholeUtteranceBlockDropsTheSentenceFinalPeriod() {
        XCTAssertEqual(SnippetExpander.apply(snippets, to: "My address."), address)
    }

    func testOneLineExpansionKeepsPunctuation() {
        XCTAssertEqual(
            SnippetExpander.apply(snippets, to: "Write to my email, please."),
            "Write to e@example.com, please.")
    }

    func testBlockInsideASentenceKeepsTheRestAndTheLeadingPunctuation() {
        XCTAssertEqual(
            SnippetExpander.apply(snippets, to: "Ship it to (my address), thanks."),
            "Ship it to (" + address + " thanks.")
    }

    func testNoSnippetsOrNoMatchLeavesTextAlone() {
        XCTAssertEqual(SnippetExpander.apply([], to: "My address."), "My address.")
        XCTAssertEqual(SnippetExpander.apply(snippets, to: "Nothing here."), "Nothing here.")
    }

    // MARK: - Editor helpers

    func testRowLabelShowsTheFirstLineAndMarksMore() {
        XCTAssertEqual(snippetRowLabel(Snippet(trigger: "my address", expansion: address)), "my address → 12 Elm St …")
        XCTAssertEqual(snippetRowLabel(Snippet(trigger: "my email", expansion: "e@example.com")), "my email → e@example.com")
    }

    func testCanAddSnippet() {
        XCTAssertTrue(canAddSnippet(trigger: "x", expansion: "y", count: 0))
        XCTAssertFalse(canAddSnippet(trigger: " ", expansion: "y", count: 0))
        XCTAssertFalse(canAddSnippet(trigger: "x", expansion: "\n", count: 0))
        XCTAssertFalse(canAddSnippet(trigger: "x", expansion: "y", count: SnippetStore.maxSnippets))
    }

    @MainActor
    func testSnippetsModelMirrorsTheStore() async {
        let store = makeStore()
        let model = SnippetsModel(store: store)
        model.add(trigger: "my address", expansion: address)
        let shown = await eventually { model.snippets.map(\.trigger) == ["my address"] }
        XCTAssertTrue(shown)
    }
}
