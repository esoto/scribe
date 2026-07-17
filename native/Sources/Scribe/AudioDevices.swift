import CoreAudio
import Foundation

/// An audio input device, identified by its CoreAudio UID — stable across
/// reboots and re-plugs, unlike the numeric `AudioDeviceID`.
struct AudioInputDevice: Equatable, Identifiable {
    let id: String
    let name: String
}

/// CoreAudio adapter: enumerates input-capable devices and resolves UIDs
/// back to live device IDs. Thin OS wrapper — excluded from unit coverage
/// beyond smoke tests; the selection behavior built on top is what's
/// tested (see MicSelectionTests).
enum AudioDevices {
    /// All devices with at least one input channel, in system order.
    static func inputDevices() -> [AudioInputDevice] {
        allDeviceIDs().compactMap { devID in
            guard inputChannelCount(devID) > 0,
                let uid = stringProperty(devID, kAudioDevicePropertyDeviceUID),
                let name = stringProperty(devID, kAudioObjectPropertyName)
            else { return nil }
            return AudioInputDevice(id: uid, name: name)
        }
    }

    /// Live device ID for a stored UID, or nil when that device is not
    /// currently connected — callers fall back to the system default.
    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        allDeviceIDs().first { stringProperty($0, kAudioDevicePropertyDeviceUID) == uid }
    }

    /// Calls `handler` on the main queue whenever the system's device list
    /// changes (plug/unplug, Bluetooth connect). Installed once for the
    /// app's lifetime — no removal path needed.
    static func onDevicesChanged(_ handler: @escaping () -> Void) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, .main
        ) { _, _ in handler() }
    }

    // MARK: - CoreAudio plumbing

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard
            AudioObjectGetPropertyDataSize(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr
        else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids
    }

    private static func inputChannelCount(_ devID: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(devID, &address, 0, nil, &size) == noErr, size > 0
        else { return 0 }
        let listPtr = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { listPtr.deallocate() }
        guard AudioObjectGetPropertyData(devID, &address, 0, nil, &size, listPtr) == noErr
        else { return 0 }
        let buffers = UnsafeMutableAudioBufferListPointer(
            listPtr.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func stringProperty(
        _ devID: AudioDeviceID, _ selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(devID, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }
}
