import CoreAudio

/// Decides whether the audio engine still captures from the chosen microphone. Pure, so the whole table is unit-tested;
/// `AVEngineControl` supplies the facts and carries out the verdict.
enum InputRebind {
    enum Action: Equatable {
        /// The engine is where it should be, or no rebuild could improve on it.
        case keep
        /// Discard the engine and bind a new one: it is on the wrong device or its tap format is stale.
        case rebuild
        /// The chosen device is not present, so capture follows the system default.
        case useSystemDefault(missingUID: String)
        /// A rebuild is due but a recording is live; the next start decides again.
        case deferWhileRunning
    }

    /// - Parameters:
    ///   - wantedUID: the saved choice; nil means the system default.
    ///   - resolved: the CoreAudio ID the wanted UID has right now, nil if the device is not present.
    ///   - bound: the device the engine's input unit is bound to, nil if it can't be read.
    ///   - configurationChanged: the engine reported a configuration change since it was built.
    ///   - running: the engine is capturing.
    static func decide(
        wantedUID: String?, resolved: AudioDeviceID?, bound: AudioDeviceID?, configurationChanged: Bool, running: Bool
    ) -> Action {
        let verdict = verdictIgnoringRunning(
            wantedUID: wantedUID, resolved: resolved, bound: bound, configurationChanged: configurationChanged)
        // Under a live recording the engine can't be swapped without losing the audio, so wait for the next start.
        return verdict == .rebuild && running ? .deferWhileRunning : verdict
    }

    private static func verdictIgnoringRunning(
        wantedUID: String?, resolved: AudioDeviceID?, bound: AudioDeviceID?, configurationChanged: Bool
    ) -> Action {
        // A route or format change leaves the tap and converter stale even when the device still matches, and
        // even on the system default, so it outranks every device comparison. A missing device is then reported
        // by the new engine.
        if configurationChanged { return .rebuild }
        guard let wantedUID else { return .keep }
        guard let resolved else { return .useSystemDefault(missingUID: wantedUID) }
        // An unreadable binding can't be compared, and rebuilding on every start would not make it readable.
        guard let bound else { return .keep }
        return bound == resolved ? .keep : .rebuild
    }
}
