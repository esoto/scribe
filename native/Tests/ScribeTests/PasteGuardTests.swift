import XCTest

final class PasteGuardTests: XCTestCase {
    private final class FakeDeliverer: PasteDelivering {
        let err: Error?
        private(set) var pasted: [String] = []
        private(set) var copied: [String] = []

        init(err: Error? = nil) {
            self.err = err
        }

        private(set) var pastedTargets: [pid_t?] = []

        func paste(_ text: String, target: pid_t?) throws {
            if let err { throw err }
            pasted.append(text)
            pastedTargets.append(target)
        }

        func copyOnly(_ text: String) {
            copied.append(text)
        }
    }

    private func guarded(
        _ inner: FakeDeliverer,
        accessibility: Bool = true,
        current: pid_t? = 42
    ) -> GuardedPaster {
        GuardedPaster(
            inner: inner,
            accessibilityGranted: { accessibility },
            currentFrontmost: { current })
    }

    func test_accessibility_off_copies_instead_of_pasting() {
        let inner = FakeDeliverer()
        let paster = guarded(inner, accessibility: false)

        XCTAssertThrowsError(try paster.paste("hola", target: 42)) { error in
            XCTAssertEqual((error as? PasteGuardError)?.notice, "Accessibility is off — text copied, press ⌘V")
        }
        XCTAssertEqual(inner.copied, ["hola"])
        XCTAssertEqual(inner.pasted, [])
    }

    func test_focus_change_copies_instead_of_pasting() {
        let inner = FakeDeliverer()
        let paster = guarded(inner, current: 99)

        XCTAssertThrowsError(try paster.paste("hola", target: 42)) { error in
            XCTAssertEqual((error as? PasteGuardError)?.notice, "Focus changed — text copied, press ⌘V")
        }
        XCTAssertEqual(inner.copied, ["hola"])
        XCTAssertEqual(inner.pasted, [])
    }

    func test_unknown_current_app_counts_as_a_focus_change() {
        let inner = FakeDeliverer()
        let paster = guarded(inner, current: nil)

        XCTAssertThrowsError(try paster.paste("hola", target: 42)) { error in
            XCTAssertEqual((error as? PasteGuardError)?.notice, "Focus changed — text copied, press ⌘V")
        }
        XCTAssertEqual(inner.copied, ["hola"])
        XCTAssertEqual(inner.pasted, [])
    }

    func test_same_app_pastes() throws {
        let inner = FakeDeliverer()

        try guarded(inner, current: 42).paste("hola", target: 42)

        XCTAssertEqual(inner.pasted, ["hola"])
        XCTAssertEqual(inner.pastedTargets, [42])
        XCTAssertEqual(inner.copied, [])
    }

    func test_no_recorded_key_down_app_means_no_focus_guard() throws {
        let inner = FakeDeliverer()

        try guarded(inner, current: 99).paste("hola", target: nil)

        XCTAssertEqual(inner.pasted, ["hola"])
        XCTAssertEqual(inner.copied, [])
    }

    func test_accessibility_is_checked_before_focus() {
        let inner = FakeDeliverer()
        let paster = guarded(inner, accessibility: false, current: 99)

        XCTAssertThrowsError(try paster.paste("hola", target: 42)) { error in
            XCTAssertEqual((error as? PasteGuardError)?.notice, "Accessibility is off — text copied, press ⌘V")
        }
    }

    func test_inner_paste_failure_is_not_disguised_as_a_guard_failure() {
        let inner = FakeDeliverer(err: PasteError(message: "secure input"))
        let paster = guarded(inner)

        XCTAssertThrowsError(try paster.paste("hola", target: 42)) { error in
            XCTAssertTrue(error is PasteError)
        }
        XCTAssertEqual(inner.copied, [])
    }

    func test_paste_again_refuses_scribe_itself() {
        let inner = FakeDeliverer()
        XCTAssertThrowsError(try guarded(inner, current: 7).pasteIntoFocusedApp("hola", ownPID: 7)) { error in
            XCTAssertEqual((error as? PasteGuardError)?.notice, "scribe has focus — text copied, press ⌘V")
        }
        XCTAssertEqual(inner.copied, ["hola"])
        XCTAssertEqual(inner.pasted, [])
    }

    func test_paste_again_pastes_into_another_app_without_a_target() throws {
        let inner = FakeDeliverer()
        try guarded(inner, current: 42).pasteIntoFocusedApp("hola", ownPID: 7)
        XCTAssertEqual(inner.pasted, ["hola"])
        XCTAssertEqual(inner.pastedTargets, [nil])
    }

    func test_paste_again_reports_accessibility_before_focus() {
        let inner = FakeDeliverer()
        XCTAssertThrowsError(
            try guarded(inner, accessibility: false, current: 7).pasteIntoFocusedApp("hola", ownPID: 7)
        ) { error in
            XCTAssertEqual((error as? PasteGuardError)?.notice, "Accessibility is off — text copied, press ⌘V")
        }
    }

    // MARK: - GuardedKeyPresser

    private func keyPresser(
        _ posted: Box<SyntheticKey>, accessibility: Bool = true, current: pid_t? = 42, error: Error? = nil
    ) -> GuardedKeyPresser {
        GuardedKeyPresser(
            post: { key in
                if let error { throw error }
                posted.append(key)
            },
            accessibilityGranted: { accessibility },
            currentFrontmost: { current })
    }

    func test_key_press_refused_without_accessibility() {
        let posted = Box<SyntheticKey>()
        let presser = keyPresser(posted, accessibility: false)

        XCTAssertThrowsError(try presser.press(.returnKey, target: 42)) { error in
            XCTAssertEqual((error as? PasteGuardError)?.notice, "Accessibility is off — Return not sent")
        }
        XCTAssertEqual(posted.value, [])
    }

    func test_key_press_refused_after_a_focus_change() {
        let posted = Box<SyntheticKey>()
        let presser = keyPresser(posted, current: 99)

        XCTAssertThrowsError(try presser.press(.commandZ, target: 42)) { error in
            XCTAssertEqual((error as? PasteGuardError)?.notice, "Focus changed — Undo not sent")
        }
        XCTAssertEqual(posted.value, [])
    }

    func test_key_press_reaches_the_same_app_or_an_unknown_target() throws {
        let posted = Box<SyntheticKey>()
        let presser = keyPresser(posted)
        try presser.press(.returnKey, target: 42)
        try presser.press(.commandZ, target: nil)
        XCTAssertEqual(posted.value, [.returnKey, .commandZ])
    }

    func test_key_press_post_failure_is_not_a_guard_failure() {
        let posted = Box<SyntheticKey>()
        let presser = keyPresser(posted, error: TestError(message: "no event"))
        XCTAssertThrowsError(try presser.press(.returnKey, target: 42)) { error in
            XCTAssertNil(error as? PasteGuardError)
        }
    }

    func test_synthetic_keys_carry_their_virtual_keycodes_and_flags() {
        XCTAssertEqual(SyntheticKey.commandV.keycode, 9)
        XCTAssertEqual(SyntheticKey.returnKey.keycode, 36)
        XCTAssertEqual(SyntheticKey.commandZ.keycode, 6)
        XCTAssertEqual(SyntheticKey.commandV.flags, .maskCommand)
        XCTAssertEqual(SyntheticKey.commandZ.flags, .maskCommand)
        XCTAssertEqual(SyntheticKey.returnKey.flags, [])
        XCTAssertEqual(SyntheticKey.commandV.spoken, "\u{2318}V")
    }
}
