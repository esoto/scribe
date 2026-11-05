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
        XCTAssertTrue(devices.allSatisfy { !AudioDevices.isDefaultAggregate(uid: $0.id) })
    }

    func testOnlyUIDsThatStartWithTheDefaultAggregatePrefixAreDefaultAggregates() {
        XCTAssertTrue(AudioDevices.isDefaultAggregate(uid: "CADefaultDeviceAggregate-4242-0"))
        XCTAssertFalse(AudioDevices.isDefaultAggregate(uid: "BuiltInMicrophoneDevice"))
        XCTAssertFalse(AudioDevices.isDefaultAggregate(uid: "usb-CADefaultDeviceAggregate"))
        XCTAssertFalse(AudioDevices.isDefaultAggregate(uid: ""))
    }

    func testUnknownUIDResolvesToNilSoCaptureFallsBackToDefault() {
        XCTAssertNil(AudioDevices.deviceID(forUID: "scribe-test-nonexistent-device-uid"))
    }

    func testBoundInputOfAnUnknownDeviceIsNil() {
        XCTAssertNil(AudioDevices.boundInput(forDeviceID: AudioDeviceID(kAudioObjectUnknown)))
    }

    func testBoundInputNamesEveryInputDeviceTheSystemLists() throws {
        let devices = AudioDevices.inputDevices()
        try XCTSkipIf(devices.isEmpty, "this Mac lists no input device, so there is nothing to name")
        for device in devices {
            let id = AudioDevices.deviceID(forUID: device.id)
            XCTAssertNotNil(id)
            XCTAssertEqual(
                id.flatMap(AudioDevices.boundInput(forDeviceID:)), BoundInput(uid: device.id, name: device.name))
        }
    }

    func testTheDefaultInputIsAListedDeviceWithAName() throws {
        guard let input = AudioDevices.defaultInput() else { throw XCTSkip("this Mac has no default input") }
        XCTAssertFalse(input.uid.isEmpty)
        XCTAssertFalse(input.name.isEmpty)
        XCTAssertNotNil(AudioDevices.deviceID(forUID: input.uid))
    }
}
