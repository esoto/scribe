import XCTest

final class PasteGuardTests: XCTestCase {
    private final class FakeDeliverer: PasteDelivering {
        let err: Error?
        private(set) var pasted: [String] = []
        private(set) var copied: [String] = []

        init(err: Error? = nil) {
            self.err = err
        }

        func paste(_ text: String) throws {
            if let err { throw err }
            pasted.append(text)
        }

        func copyOnly(_ text: String) {
            copied.append(text)
        }
    }

    private func guarded(
        _ inner: FakeDeliverer,
        accessibility: Bool = true,
        expected: pid_t? = 42,
        current: pid_t? = 42
    ) -> GuardedPaster {
        GuardedPaster(
            inner: inner,
            accessibilityGranted: { accessibility },
            expectedFrontmost: { expected },
            currentFrontmost: { current })
    }

    func test_accessibility_off_copies_instead_of_pasting() {
        let inner = FakeDeliverer()
        let paster = guarded(inner, accessibility: false)

        XCTAssertThrowsError(try paster.paste("hola")) { error in
            XCTAssertEqual((error as? PasteGuardError)?.notice, "Accessibility is off — text copied, press ⌘V")
        }
        XCTAssertEqual(inner.copied, ["hola"])
        XCTAssertEqual(inner.pasted, [])
    }

    func test_focus_change_copies_instead_of_pasting() {
        let inner = FakeDeliverer()
        let paster = guarded(inner, expected: 42, current: 99)

        XCTAssertThrowsError(try paster.paste("hola")) { error in
            XCTAssertEqual((error as? PasteGuardError)?.notice, "Focus changed — text copied, press ⌘V")
        }
        XCTAssertEqual(inner.copied, ["hola"])
        XCTAssertEqual(inner.pasted, [])
    }

    func test_unknown_current_app_counts_as_a_focus_change() {
        let inner = FakeDeliverer()
        let paster = guarded(inner, expected: 42, current: nil)

        XCTAssertThrowsError(try paster.paste("hola")) { error in
            XCTAssertEqual((error as? PasteGuardError)?.notice, "Focus changed — text copied, press ⌘V")
        }
        XCTAssertEqual(inner.copied, ["hola"])
        XCTAssertEqual(inner.pasted, [])
    }

    func test_same_app_pastes() throws {
        let inner = FakeDeliverer()

        try guarded(inner, expected: 42, current: 42).paste("hola")

        XCTAssertEqual(inner.pasted, ["hola"])
        XCTAssertEqual(inner.copied, [])
    }

    func test_no_recorded_key_down_app_means_no_focus_guard() throws {
        let inner = FakeDeliverer()

        try guarded(inner, expected: nil, current: 99).paste("hola")

        XCTAssertEqual(inner.pasted, ["hola"])
        XCTAssertEqual(inner.copied, [])
    }

    func test_accessibility_is_checked_before_focus() {
        let inner = FakeDeliverer()
        let paster = guarded(inner, accessibility: false, expected: 42, current: 99)

        XCTAssertThrowsError(try paster.paste("hola")) { error in
            XCTAssertEqual((error as? PasteGuardError)?.notice, "Accessibility is off — text copied, press ⌘V")
        }
    }

    func test_inner_paste_failure_is_not_disguised_as_a_guard_failure() {
        let inner = FakeDeliverer(err: PasteError(message: "secure input"))
        let paster = guarded(inner)

        XCTAssertThrowsError(try paster.paste("hola")) { error in
            XCTAssertTrue(error is PasteError)
        }
        XCTAssertEqual(inner.copied, [])
    }

    func test_paste_target_holds_the_last_pid_set() {
        let target = PasteTarget()
        XCTAssertNil(target.get())

        target.set(42)
        XCTAssertEqual(target.get(), 42)

        target.set(nil)
        XCTAssertNil(target.get())
    }
}
