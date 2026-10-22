import XCTest

final class KeyboardLayoutTests: XCTestCase {
    func test_first_keycode_that_types_the_character_wins() {
        let typed: [CGKeyCode: String] = [3: "x", 5: "z", 20: "z"]
        XCTAssertEqual(KeyboardLayout.keycode(for: "z", translating: { typed[$0] }), 5)
    }

    func test_nil_when_no_key_types_the_character() {
        XCTAssertNil(KeyboardLayout.keycode(for: "v", translating: { _ in "a" }))
        XCTAssertNil(KeyboardLayout.keycode(for: "v", translating: { _ in nil }))
    }

    func test_scans_keycodes_zero_through_127_only() {
        XCTAssertEqual(KeyboardLayout.keycode(for: "z", translating: { $0 == 127 ? "z" : nil }), 127)
        XCTAssertNil(KeyboardLayout.keycode(for: "z", translating: { $0 == 128 ? "z" : nil }))
    }

    func test_a_key_that_types_several_characters_is_not_a_match() {
        XCTAssertNil(KeyboardLayout.keycode(for: "z", translating: { _ in "zz" }))
    }

    // MARK: - The machine's real layout

    func test_the_current_layout_round_trips_through_its_own_keycode() {
        for letter: Character in ["v", "z"] {
            guard let keycode = KeyboardLayout.keycode(for: letter) else { continue }
            XCTAssertEqual(KeyboardLayout.character(for: keycode), String(letter))
        }
    }

    func test_a_character_no_key_types_has_no_keycode() {
        XCTAssertNil(KeyboardLayout.keycode(for: "\u{1F600}"))
    }

    func test_qwerty_family_layout_puts_a_on_keycode_zero() throws {
        try XCTSkipUnless(KeyboardLayout.character(for: 0) == "a", "the active layout is not QWERTY-family")
        XCTAssertEqual(KeyboardLayout.keycode(for: "a"), 0)
    }
}
