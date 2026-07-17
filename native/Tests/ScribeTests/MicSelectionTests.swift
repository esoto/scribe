import XCTest


final class MicSelectionTests: XCTestCase {
    private func makeSettings() -> (AppSettings, UserDefaults) {
        let suite = "MicSelectionTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (AppSettings(defaults: defaults), defaults)
    }

    func testMicrophoneUIDDefaultsToNilAndRoundtrips() {
        let (settings, _) = makeSettings()
        XCTAssertNil(settings.microphoneUID)
        settings.microphoneUID = "BuiltInMicrophoneDevice"
        XCTAssertEqual(settings.microphoneUID, "BuiltInMicrophoneDevice")
    }

    func testEmptyMicrophoneUIDCountsAsUnset() {
        let (settings, defaults) = makeSettings()
        defaults.set("", forKey: "microphoneUID")
        XCTAssertNil(settings.microphoneUID)
    }

    // MARK: - CoreAudio adapter smoke tests (real hardware, soft asserts)

    func testInputDeviceEnumerationIsSane() {
        let devices = AudioDevices.inputDevices()
        // Whatever the machine has: UIDs must be unique and names non-empty.
        XCTAssertEqual(Set(devices.map(\.id)).count, devices.count)
        XCTAssertTrue(devices.allSatisfy { !$0.name.isEmpty })
    }

    func testUnknownUIDResolvesToNilSoCaptureFallsBackToDefault() {
        XCTAssertNil(AudioDevices.deviceID(forUID: "scribe-test-nonexistent-device-uid"))
    }
}
