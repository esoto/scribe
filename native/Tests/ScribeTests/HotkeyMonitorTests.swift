import XCTest

/// The tap itself needs Input Monitoring and is not unit-testable; what is: tearing down is always safe.
final class HotkeyMonitorTests: XCTestCase {
    func testUninstallBeforeInstallIsANoOp() {
        let monitor = HotkeyMonitor(key: .f13, onDown: { _ in }, onUp: {})

        monitor.uninstall()
        monitor.uninstall()
    }
}
