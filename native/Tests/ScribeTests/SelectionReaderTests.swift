import XCTest

final class SelectionReaderTests: XCTestCase {
    /// A clipboard that records what is put back on it, and lets a test play the source app's copy.
    private final class Clipboard: PasteboardLike {
        private(set) var items: [PasteboardItemData]?
        private(set) var restored: [[PasteboardItemData]] = []
        private var count = 1

        init(items: [PasteboardItemData]?) {
            self.items = items
        }

        func snapshot() -> [PasteboardItemData]? { items }

        func restore(_ items: [PasteboardItemData]) {
            self.items = items
            restored.append(items)
            count += 1
        }

        func setTransient(_ s: String) {
            items = [["public.utf8-plain-text": Data(s.utf8)]]
            count += 1
        }

        func changeCount() -> Int { count }

        func string() -> String? {
            items?.first?["public.utf8-plain-text"].flatMap { String(data: $0, encoding: .utf8) }
        }

        /// What the app in front does with ⌘C.
        func appCopies(_ text: String) {
            appCopies(items: [["public.utf8-plain-text": Data(text.utf8)]])
        }

        func appCopies(items: [PasteboardItemData]) {
            self.items = items
            count += 1
        }
    }

    /// Plays the ⌘C: the app copies from inside `press`, or later from a poll's sleep.
    private final class Keys: KeyPressing {
        let err: Error?
        let onPress: () -> Void
        private(set) var pressed: [SyntheticKey] = []
        private(set) var targets: [pid_t?] = []

        init(err: Error? = nil, onPress: @escaping () -> Void = {}) {
            self.err = err
            self.onPress = onPress
        }

        func press(_ key: SyntheticKey, target: pid_t?) throws {
            if let err { throw err }
            pressed.append(key)
            targets.append(target)
            onPress()
        }
    }

    private let mine: [PasteboardItemData] = [["public.utf8-plain-text": Data("mine".utf8)]]

    /// Power-of-two fractions: the accumulated wait is exact, so the poll count is too.
    private func reader(
        _ pasteboard: Clipboard, _ keys: Keys, sleeps: Box<Double> = Box(), wait: Double = 0.5, poll: Double = 0.125,
        onSleep: @escaping (Int) -> Void = { _ in }
    ) -> PasteboardSelectionReader {
        PasteboardSelectionReader(
            pasteboard: pasteboard, keys: keys, waitSeconds: wait, pollSeconds: poll,
            sleep: { seconds in
                sleeps.append(seconds)
                onSleep(sleeps.value.count)
            })
    }

    func test_a_copy_that_lands_at_once_is_the_selection_and_keeps_the_clipboard_from_before() async throws {
        let pasteboard = Clipboard(items: mine)
        let keys = Keys(onPress: { pasteboard.appCopies("the selected words") })

        let selection = try await reader(pasteboard, keys).read(target: 42)

        XCTAssertEqual(selection, Selection(text: "the selected words", snapshot: mine))
        XCTAssertTrue(pasteboard.restored.isEmpty, "the final paste restores; the reader leaves the copy in place")
    }

    func test_a_copy_that_lands_after_a_few_polls_is_found_and_stops_the_wait() async throws {
        let pasteboard = Clipboard(items: mine)
        let sleeps = Box<Double>()
        let keys = Keys()

        let selection = try await reader(pasteboard, keys, sleeps: sleeps) { polls in
            if polls == 2 { pasteboard.appCopies("late but in time") }
        }.read(target: 42)

        XCTAssertEqual(selection?.text, "late but in time")
        XCTAssertEqual(sleeps.value, [0.125, 0.125])
    }

    func test_the_selection_is_trimmed() async throws {
        let pasteboard = Clipboard(items: mine)
        let keys = Keys(onPress: { pasteboard.appCopies("  two lines\nof text \n\n") })

        let selection = try await reader(pasteboard, keys).read(target: nil)

        XCTAssertEqual(selection?.text, "two lines\nof text")
    }

    func test_an_empty_clipboard_before_the_copy_gives_a_nil_snapshot() async throws {
        let pasteboard = Clipboard(items: nil)
        let keys = Keys(onPress: { pasteboard.appCopies("words") })

        let selection = try await reader(pasteboard, keys).read(target: 42)

        XCTAssertEqual(selection, Selection(text: "words", snapshot: nil))
    }

    func test_a_clipboard_that_never_changes_means_nothing_was_selected() async throws {
        let pasteboard = Clipboard(items: mine)
        let keys = Keys()

        let selection = try await reader(pasteboard, keys).read(target: 42)

        XCTAssertNil(selection)
        XCTAssertEqual(pasteboard.items, mine)
        XCTAssertTrue(pasteboard.restored.isEmpty, "nothing changed, so there is nothing to put back")
    }

    func test_the_wait_is_bounded_by_wait_over_poll() async throws {
        let pasteboard = Clipboard(items: mine)
        let sleeps = Box<Double>()

        _ = try await reader(pasteboard, Keys(), sleeps: sleeps, wait: 0.5, poll: 0.125).read(target: 42)

        XCTAssertEqual(sleeps.value, [0.125, 0.125, 0.125, 0.125])
    }

    func test_a_copy_of_nothing_is_no_selection_and_the_clipboard_is_put_back() async throws {
        for empty in ["", "   \n\t "] {
            let pasteboard = Clipboard(items: mine)
            let keys = Keys(onPress: { pasteboard.appCopies(empty) })

            let selection = try await reader(pasteboard, keys).read(target: 42)

            XCTAssertNil(selection, "\(empty.debugDescription)")
            XCTAssertEqual(pasteboard.items, mine)
            XCTAssertEqual(pasteboard.restored, [mine])
        }
    }

    func test_a_copy_with_no_text_on_it_is_no_selection_and_the_clipboard_is_put_back() async throws {
        let pasteboard = Clipboard(items: mine)
        let keys = Keys(onPress: {
            pasteboard.appCopies(items: [["public.png": Data([0x89, 0x50])]])
        })

        let selection = try await reader(pasteboard, keys).read(target: 42)

        XCTAssertNil(selection)
        XCTAssertEqual(pasteboard.items, mine)
    }

    func test_an_empty_copy_over_an_empty_clipboard_has_nothing_to_put_back() async throws {
        let pasteboard = Clipboard(items: nil)
        let keys = Keys(onPress: { pasteboard.appCopies("") })

        let selection = try await reader(pasteboard, keys).read(target: 42)

        XCTAssertNil(selection)
        XCTAssertTrue(pasteboard.restored.isEmpty)
    }

    func test_the_copy_key_is_pressed_exactly_once_in_the_given_app() async throws {
        let pasteboard = Clipboard(items: mine)
        let keys = Keys(onPress: { pasteboard.appCopies("x") })

        _ = try await reader(pasteboard, keys).read(target: 42)
        XCTAssertEqual(keys.pressed, [.commandC])
        XCTAssertEqual(keys.targets, [42])

        let anywhere = Keys(onPress: { pasteboard.appCopies("y") })
        _ = try await reader(pasteboard, anywhere).read(target: nil)
        XCTAssertEqual(anywhere.targets, [nil])
    }

    func test_a_refused_key_press_propagates_and_touches_nothing() async {
        let pasteboard = Clipboard(items: mine)
        let sleeps = Box<Double>()
        let keys = Keys(err: PasteGuardError(notice: "Accessibility is off — ⌘C not sent"))

        do {
            _ = try await reader(pasteboard, keys, sleeps: sleeps).read(target: 42)
            XCTFail("the refusal must reach the caller")
        } catch {
            XCTAssertEqual((error as? PasteGuardError)?.notice, "Accessibility is off — ⌘C not sent")
        }
        XCTAssertEqual(pasteboard.items, mine)
        XCTAssertTrue(pasteboard.restored.isEmpty)
        XCTAssertTrue(sleeps.value.isEmpty, "no key, no wait")
    }

    func test_the_default_sleep_really_waits() async throws {
        let started = ContinuousClock.now

        let selection = try await PasteboardSelectionReader(
            pasteboard: Clipboard(items: mine), keys: Keys(), waitSeconds: 0.01, pollSeconds: 0.005
        ).read(target: 42)

        XCTAssertNil(selection)
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - started, .milliseconds(10))
    }
}
