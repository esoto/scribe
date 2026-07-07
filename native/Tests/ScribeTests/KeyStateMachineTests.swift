import XCTest
@testable import Scribe

final class KeyStateMachineTests: XCTestCase {
    private let cmd: UInt64 = 0x100000
    private let opt: UInt64 = 0x80000

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

    func testRightCommandDownUp() {
        let m = KeyStateMachine(key: .rightCommand)
        XCTAssertEqual(m.handle(eventType: 12, keycode: 54, flags: cmd), .down)
        XCTAssertEqual(m.handle(eventType: 12, keycode: 54, flags: 0), .up)
    }

    func testOtherKeycodeIgnored() {
        let m = KeyStateMachine(key: .rightCommand)
        XCTAssertNil(m.handle(eventType: 12, keycode: 55, flags: cmd))
        XCTAssertNil(m.handle(eventType: 12, keycode: 61, flags: opt))
    }

    func testDuplicateFlagsEventsIgnored() {
        let m = KeyStateMachine(key: .rightCommand)
        XCTAssertEqual(m.handle(eventType: 12, keycode: 54, flags: cmd), .down)
        XCTAssertNil(m.handle(eventType: 12, keycode: 54, flags: cmd))
        XCTAssertEqual(m.handle(eventType: 12, keycode: 54, flags: 0), .up)
        XCTAssertNil(m.handle(eventType: 12, keycode: 54, flags: 0))
    }

    func testF13UsesKeyDownKeyUp() {
        let m = KeyStateMachine(key: .f13)
        XCTAssertEqual(m.handle(eventType: 10, keycode: 105, flags: 0), .down)
        XCTAssertEqual(m.handle(eventType: 11, keycode: 105, flags: 0), .up)
        XCTAssertNil(m.handle(eventType: 12, keycode: 105, flags: 0))
    }

    func testRightOption() {
        let m = KeyStateMachine(key: .rightOption)
        XCTAssertEqual(m.handle(eventType: 12, keycode: 61, flags: opt), .down)
        XCTAssertEqual(m.handle(eventType: 12, keycode: 61, flags: 0), .up)
    }

    func testModifierKeyIgnoresKeyDownEvents() {
        let m = KeyStateMachine(key: .rightCommand)
        XCTAssertNil(m.handle(eventType: 10, keycode: 54, flags: cmd))
    }
}
