import Carbon.HIToolbox
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

    func test_a_character_no_key_types_has_no_keycode() {
        XCTAssertNil(KeyboardLayout.keycode(for: "\u{1F600}"))
    }

    func test_qwerty_family_layout_puts_a_on_keycode_zero() throws {
        try XCTSkipUnless(KeyboardLayout.character(for: 0) == "a", "the active layout is not QWERTY-family")
        XCTAssertEqual(KeyboardLayout.keycode(for: "a"), 0)
    }

    func test_a_lookup_off_the_main_thread_matches_one_on_it() {
        final class Result: @unchecked Sendable { var keycode: CGKeyCode? }
        let onMain = KeyboardLayout.keycode(for: "v")
        let result = Result()
        let done = expectation(description: "worker lookup")
        DispatchQueue.global().async {
            result.keycode = KeyboardLayout.keycode(for: "v")
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(result.keycode, onMain)
    }

    // MARK: - Installed layouts, read without switching the user's

    private func installedLayout(_ id: String) throws -> Data {
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource] ?? []
        let property = try XCTUnwrap(list.first.flatMap { TISGetInputSourceProperty($0, kTISPropertyUnicodeKeyLayoutData) }, id)
        return Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data
    }

    func test_installed_layouts_resolve_the_key_their_command_layer_types() throws {
        let expected: [(id: String, v: CGKeyCode, z: CGKeyCode)] = [
            ("com.apple.keylayout.US", 9, 6), ("com.apple.keylayout.German", 9, 16),
            ("com.apple.keylayout.French", 9, 13), ("com.apple.keylayout.Dvorak", 47, 44),
            ("com.apple.keylayout.DVORAK-QWERTYCMD", 9, 6), ("com.apple.keylayout.Russian", 9, 6),
        ]
        for layout in expected {
            let data = try installedLayout(layout.id)
            let resolve = { (c: Character) in
                KeyboardLayout.keycode(for: c, translating: { KeyboardLayout.translate($0, in: data) })
            }
            XCTAssertEqual(resolve("v"), layout.v, layout.id)
            XCTAssertEqual(resolve("z"), layout.z, layout.id)
        }
    }
}
