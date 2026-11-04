import XCTest

/// The rebuild rules of the warm prefixes, run on plain values: the KV caches themselves need a model.
final class WarmSlotsTests: XCTestCase {
    func testNothingIsWarmAtFirst() {
        let slots = WarmSlots<Int>()
        XCTAssertNil(slots.prefix(in: .cleanup))
        XCTAssertNil(slots.prefix(in: .edit))
        XCTAssertNil(slots.systemPrompt(in: .cleanup))
        XCTAssertTrue(slots.systemPrompts.isEmpty)
    }

    func testAnUpToDatePrefixIsNotRebuilt() {
        var slots = WarmSlots<Int>()
        XCTAssertTrue(slots.beginWarmUp(.cleanup, systemPrompt: "A"))
        slots.store(1, in: .cleanup, systemPrompt: "A")

        XCTAssertFalse(slots.beginWarmUp(.cleanup, systemPrompt: "A"))
        XCTAssertEqual(slots.prefix(in: .cleanup), 1)
        XCTAssertEqual(slots.systemPrompt(in: .cleanup), "A")
    }

    func testAChangedPromptReplacesThePrefixInsteadOfKeepingTheOldOne() {
        var slots = WarmSlots<Int>()
        _ = slots.beginWarmUp(.cleanup, systemPrompt: "A")
        slots.store(1, in: .cleanup, systemPrompt: "A")

        XCTAssertTrue(slots.beginWarmUp(.cleanup, systemPrompt: "B"))
        XCTAssertNil(slots.prefix(in: .cleanup), "stale until the rebuild lands")
        slots.store(2, in: .cleanup, systemPrompt: "B")
        XCTAssertEqual(slots.systemPrompts, ["B"], "a superseded prompt must not stay resident")
    }

    func testAFailedWarmUpIsNotRetriedForTheSamePromptButIsForAnother() {
        var slots = WarmSlots<Int>()
        XCTAssertTrue(slots.beginWarmUp(.edit, systemPrompt: "E"))
        // the build failed: nothing stored

        XCTAssertFalse(slots.beginWarmUp(.edit, systemPrompt: "E"))
        XCTAssertNil(slots.prefix(in: .edit))
        XCTAssertTrue(slots.beginWarmUp(.edit, systemPrompt: "E2"))
    }

    func testTheSlotsAreIndependent() {
        var slots = WarmSlots<Int>()
        _ = slots.beginWarmUp(.cleanup, systemPrompt: "C")
        slots.store(1, in: .cleanup, systemPrompt: "C")
        _ = slots.beginWarmUp(.edit, systemPrompt: "E")
        slots.store(2, in: .edit, systemPrompt: "E")

        XCTAssertEqual(slots.systemPrompts, ["C", "E"])

        // A dictionary change rebuilds cleanup and leaves the edit prefix alone.
        XCTAssertTrue(slots.beginWarmUp(.cleanup, systemPrompt: "C2"))
        XCTAssertEqual(slots.prefix(in: .edit), 2)
        XCTAssertEqual(slots.systemPrompt(in: .edit), "E")

        // A failed edit warm-up does not touch cleanup either.
        slots.store(3, in: .cleanup, systemPrompt: "C2")
        _ = slots.beginWarmUp(.edit, systemPrompt: "E2")
        XCTAssertEqual(slots.prefix(in: .cleanup), 3)
    }

    func testAFailedAttemptIsRecordedPerSlot() {
        var slots = WarmSlots<Int>()
        XCTAssertTrue(slots.beginWarmUp(.edit, systemPrompt: "E"))  // failed: nothing stored

        XCTAssertTrue(
            slots.beginWarmUp(.cleanup, systemPrompt: "E"),
            "an attempt in the edit slot does not block the cleanup slot, even for an equal prompt")
        _ = slots.beginWarmUp(.cleanup, systemPrompt: "C")
        XCTAssertFalse(
            slots.beginWarmUp(.edit, systemPrompt: "E"),
            "and a later cleanup attempt does not clear the edit slot's failure")
    }

    func testRemoveAllForgetsPrefixesAndFailedAttempts() {
        var slots = WarmSlots<Int>()
        _ = slots.beginWarmUp(.cleanup, systemPrompt: "C")
        slots.store(1, in: .cleanup, systemPrompt: "C")
        _ = slots.beginWarmUp(.edit, systemPrompt: "E")  // failed

        slots.removeAll()

        XCTAssertNil(slots.prefix(in: .cleanup))
        XCTAssertTrue(slots.systemPrompts.isEmpty)
        XCTAssertTrue(slots.beginWarmUp(.cleanup, systemPrompt: "C"))
        XCTAssertTrue(slots.beginWarmUp(.edit, systemPrompt: "E"), "a reloaded model deserves a new attempt")
    }
}
