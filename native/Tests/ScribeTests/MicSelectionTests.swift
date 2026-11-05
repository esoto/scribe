import CoreAudio
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

    func testInputDeviceEnumerationIsSane() {
        let devices = AudioDevices.inputDevices()
        XCTAssertEqual(Set(devices.map(\.id)).count, devices.count)
        XCTAssertTrue(devices.allSatisfy { !$0.name.isEmpty })
    }

    func testUnknownUIDResolvesToNilSoCaptureFallsBackToDefault() {
        XCTAssertNil(AudioDevices.deviceID(forUID: "scribe-test-nonexistent-device-uid"))
    }

    func testBoundInputOfAnUnknownDeviceIsNil() {
        XCTAssertNil(AudioDevices.boundInput(forDeviceID: AudioDeviceID(kAudioObjectUnknown)))
    }

    func testBoundInputNamesEveryInputDeviceTheSystemLists() {
        for device in AudioDevices.inputDevices() {
            let id = AudioDevices.deviceID(forUID: device.id)
            XCTAssertNotNil(id)
            XCTAssertEqual(
                id.flatMap(AudioDevices.boundInput(forDeviceID:)), BoundInput(uid: device.id, name: device.name))
        }
    }

    func testDefaultInputUIDIsNilOrNamesADevice() {
        if let uid = AudioDevices.defaultInputUID() {
            XCTAssertFalse(uid.isEmpty)
            XCTAssertNotNil(AudioDevices.deviceID(forUID: uid))
        }
    }
}
