import CoreGraphics
import XCTest

final class KeyStateMachineTests: XCTestCase {
    // Device-side bits (IOLLEvent.h NX_DEVICERCMDKEYMASK / NX_DEVICERALTKEYMASK), not the generic ⌘/⌥ bits.
    private let cmd: UInt64 = 0x10
    private let opt: UInt64 = 0x40
    private let genericOpt: UInt64 = 0x80000
    private let leftOpt: UInt64 = 0x20

    func testKeycodeTable() {
        XCTAssertEqual(HotKey.rightCommand.keycode, 54)
        XCTAssertEqual(HotKey.rightOption.keycode, 61)
        XCTAssertEqual(HotKey.f13.keycode, 105)
    }

    func testModifierMaskTable() {
        XCTAssertEqual(HotKey.rightCommand.modifierMask, cmd)
        XCTAssertEqual(HotKey.rightOption.modifierMask, opt)
        XCTAssertNil(HotKey.f13.modifierMask)
    }

    func testDisplayNameTable() {
        XCTAssertEqual(HotKey.rightCommand.displayName, "Right \u{2318}")
        XCTAssertEqual(HotKey.rightOption.displayName, "Right \u{2325}")
        XCTAssertEqual(HotKey.f13.displayName, "F13")
    }

    func testRightCommandDownUp() {
        let m = KeyStateMachine(key: .rightCommand)
        XCTAssertEqual(m.handle(eventType: 12, keycode: 54, flags: cmd), .down(chord: false))
        XCTAssertEqual(m.handle(eventType: 12, keycode: 54, flags: 0), .up)
    }

    func testOtherKeycodeIgnored() {
        let m = KeyStateMachine(key: .rightCommand)
        XCTAssertNil(m.handle(eventType: 12, keycode: 55, flags: cmd))
        XCTAssertNil(m.handle(eventType: 12, keycode: 61, flags: opt))
    }

    func testDuplicateFlagsEventsIgnored() {
        let m = KeyStateMachine(key: .rightCommand)
        XCTAssertEqual(m.handle(eventType: 12, keycode: 54, flags: cmd), .down(chord: false))
        XCTAssertNil(m.handle(eventType: 12, keycode: 54, flags: cmd))
        XCTAssertEqual(m.handle(eventType: 12, keycode: 54, flags: 0), .up)
        XCTAssertNil(m.handle(eventType: 12, keycode: 54, flags: 0))
    }

    func testF13UsesKeyDownKeyUp() {
        let m = KeyStateMachine(key: .f13)
        XCTAssertEqual(m.handle(eventType: 10, keycode: 105, flags: 0), .down(chord: false))
        XCTAssertEqual(m.handle(eventType: 11, keycode: 105, flags: 0), .up)
        XCTAssertNil(m.handle(eventType: 12, keycode: 105, flags: 0))
    }

    func testRightOption() {
        let m = KeyStateMachine(key: .rightOption)
        XCTAssertEqual(m.handle(eventType: 12, keycode: 61, flags: opt), .down(chord: false))
        XCTAssertEqual(m.handle(eventType: 12, keycode: 61, flags: 0), .up)
    }

    func testModifierKeyIgnoresKeyDownEvents() {
        let m = KeyStateMachine(key: .rightCommand)
        XCTAssertNil(m.handle(eventType: 10, keycode: 54, flags: cmd))
    }

    func testRightOptionReleaseWhileLeftOptionHeld() {
        let m = KeyStateMachine(key: .rightOption)
        // Real flags from scribe.log: Right ⌥ down = 0x80140. With Left ⌥ still held, the release
        // event keeps the generic 0x80000 bit — only the device bit 0x40 drops.
        XCTAssertEqual(m.handle(eventType: 12, keycode: 61, flags: 0x80140), .down(chord: false))
        XCTAssertEqual(m.handle(eventType: 12, keycode: 61, flags: genericOpt | leftOpt | 0x100), .up)
    }

    func testRightCommandReleaseWhileLeftCommandHeld() {
        let m = KeyStateMachine(key: .rightCommand)
        // Real flags from scribe.log: Right ⌘ down = 0x100110; released while Left ⌘ held = 0x100108.
        XCTAssertEqual(m.handle(eventType: 12, keycode: 54, flags: 0x100110), .down(chord: false))
        XCTAssertEqual(m.handle(eventType: 12, keycode: 54, flags: 0x100108), .up)
    }

    func testRightOptionEventWithoutDeviceBitNeverArms() {
        let m = KeyStateMachine(key: .rightOption)
        XCTAssertNil(m.handle(eventType: 12, keycode: 61, flags: genericOpt | leftOpt))
    }

    func testResetReportsAndClearsHeldKey() {
        let m = KeyStateMachine(key: .rightOption)
        XCTAssertFalse(m.reset())
        XCTAssertEqual(m.handle(eventType: 12, keycode: 61, flags: opt), .down(chord: false))
        XCTAssertTrue(m.reset())
        XCTAssertNil(m.handle(eventType: 12, keycode: 61, flags: 0))
        XCTAssertEqual(m.handle(eventType: 12, keycode: 61, flags: opt), .down(chord: false))
    }

    func testShiftHeldAtKeyDownReportsAChord() {
        let m = KeyStateMachine(key: .rightOption)
        // flagsChanged for keycode 61 with Right ⌥ (0x40) and ⇧ (0x20000 generic, 0x2 left device bit) set.
        XCTAssertEqual(m.handle(eventType: 12, keycode: 61, flags: 0x40 | 0x20000 | 0x2 | 0x80000), .down(chord: true))
        XCTAssertEqual(m.handle(eventType: 12, keycode: 61, flags: 0x20000 | 0x2), .up)
    }

    func testPlainPressReportsNoChord() {
        let m = KeyStateMachine(key: .rightOption)
        XCTAssertEqual(m.handle(eventType: 12, keycode: 61, flags: 0x40 | 0x80000), .down(chord: false))
    }

    func testCapsLockIsNotAChord() {
        // Caps Lock is the adjacent 0x10000 bit; only Shift (0x20000) makes a chord.
        let m = KeyStateMachine(key: .rightOption)
        XCTAssertEqual(m.handle(eventType: 12, keycode: 61, flags: 0x40 | 0x80000 | 0x10000), .down(chord: false))
    }

    func testShiftPressedAfterTheKeyIsNotAChord() {
        let m = KeyStateMachine(key: .rightOption)
        XCTAssertEqual(m.handle(eventType: 12, keycode: 61, flags: 0x40 | 0x80000), .down(chord: false))
        // The later Shift press arrives with Shift's own keycode and is dropped, as every other key is.
        XCTAssertNil(m.handle(eventType: 12, keycode: 56, flags: 0x40 | 0x80000 | 0x20000 | 0x2))
    }

    func testTheShiftBitIsCoreGraphicsOwnShiftMask() {
        let m = KeyStateMachine(key: .rightOption)
        XCTAssertEqual(
            m.handle(eventType: 12, keycode: 61, flags: 0x40 | CGEventFlags.maskShift.rawValue), .down(chord: true))
    }

    func testF13WithShiftIsAChord() {
        let m = KeyStateMachine(key: .f13)
        XCTAssertEqual(m.handle(eventType: 10, keycode: 105, flags: 0x20000), .down(chord: true))
        XCTAssertEqual(m.handle(eventType: 11, keycode: 105, flags: 0), .up)
    }
}
