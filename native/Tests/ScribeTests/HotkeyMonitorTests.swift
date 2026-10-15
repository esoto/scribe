import XCTest

/// The tap itself needs Input Monitoring and is not unit-testable; what is: tearing down is always safe.
final class HotkeyMonitorTests: XCTestCase {
    func testUninstallBeforeInstallIsANoOp() {
        let monitor = HotkeyMonitor(key: .f13, onDown: {}, onUp: {})

        monitor.uninstall()
        monitor.uninstall()
    }
}
