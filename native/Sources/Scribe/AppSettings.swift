import Foundation

/// UserDefaults-backed application settings, with a legacy config.toml importer.
final class AppSettings {
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    private enum Key {
        static let hotkey = "hotkey"
        static let holdThreshold = "holdThreshold"
        static let engine = "engine"
        static let cleanupEnabled = "cleanupEnabled"
        static let minWords = "minWords"
        static let cleanupTimeout = "cleanupTimeout"
        static let lengthBandLow = "lengthBandLow"
        static let lengthBandHigh = "lengthBandHigh"
        static let restoreDelay = "restoreDelay"
        static let energyGate = "energyGate"
        static let sounds = "sounds"
        static let historySize = "historySize"
        static let idleUnloadMinutes = "idleUnloadMinutes"
        static let cleanupModel = "cleanupModel"
        static let cleanupModelPath = "cleanupModelPath"
        static let microphoneUID = "microphoneUID"
        static let dictionaryLearningEnabled = "dictionaryLearningEnabled"
        static let vocabularyBiasingEnabled = "vocabularyBiasingEnabled"
        static let didImportToml = "didImportToml"
    }

    /// Dev binding: right ⌥, so it doesn't clash with the Python app's right ⌘ while both run.
    var hotkey: HotKey {
        get {
            guard let raw = defaults.string(forKey: Key.hotkey), let key = HotKey(rawValue: raw) else {
                return .rightOption
            }
            return key
        }
        set { defaults.set(newValue.rawValue, forKey: Key.hotkey) }
    }

    var holdThreshold: Double {
        get { defaults.object(forKey: Key.holdThreshold) as? Double ?? 0.3 }
        set { defaults.set(newValue, forKey: Key.holdThreshold) }
    }

    var engine: String {
        get { defaults.string(forKey: Key.engine) ?? "parakeet" }
        set { defaults.set(newValue, forKey: Key.engine) }
    }

    var cleanupEnabled: Bool {
        get { defaults.object(forKey: Key.cleanupEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.cleanupEnabled) }
    }

    /// Parakeet vocabulary biasing. Default off: rescoring loose enough to catch manglings also
    /// replaces ordinary words ("bueno" -> "Deno").
    var vocabularyBiasingEnabled: Bool {
        get { defaults.object(forKey: Key.vocabularyBiasingEnabled) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Key.vocabularyBiasingEnabled) }
    }

    /// Auto-learn glossary terms from cleaned dictations. Default off: injecting a learned list
    /// makes cleanup drop words (see DictionaryFidelityTests).
    var dictionaryLearningEnabled: Bool {
        get { defaults.object(forKey: Key.dictionaryLearningEnabled) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Key.dictionaryLearningEnabled) }
    }

    var minWords: Int {
        get { defaults.object(forKey: Key.minWords) as? Int ?? 4 }
        set { defaults.set(newValue, forKey: Key.minWords) }
    }

    var cleanupTimeout: Double {
        get { defaults.object(forKey: Key.cleanupTimeout) as? Double ?? 6.0 }
        set { defaults.set(newValue, forKey: Key.cleanupTimeout) }
    }

    var lengthBand: (Double, Double) {
        get {
            let low = defaults.object(forKey: Key.lengthBandLow) as? Double ?? 0.5
            let high = defaults.object(forKey: Key.lengthBandHigh) as? Double ?? 1.3
            return (low, high)
        }
        set {
            defaults.set(newValue.0, forKey: Key.lengthBandLow)
            defaults.set(newValue.1, forKey: Key.lengthBandHigh)
        }
    }

    var restoreDelay: Double {
        get { defaults.object(forKey: Key.restoreDelay) as? Double ?? 2.0 }
        set { defaults.set(newValue, forKey: Key.restoreDelay) }
    }

    var energyGate: Double {
        get { defaults.object(forKey: Key.energyGate) as? Double ?? 0.0005 }
        set { defaults.set(newValue, forKey: Key.energyGate) }
    }

    var sounds: Bool {
        get { defaults.object(forKey: Key.sounds) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.sounds) }
    }

    var historySize: Int {
        get { defaults.object(forKey: Key.historySize) as? Int ?? 10 }
        set { defaults.set(newValue, forKey: Key.historySize) }
    }

    var idleUnloadMinutes: Double {
        get { defaults.object(forKey: Key.idleUnloadMinutes) as? Double ?? 15 }
        set { defaults.set(newValue, forKey: Key.idleUnloadMinutes) }
    }

    /// Local MLX model folder for cleanup instead of stock Gemma; nil/blank = stock.
    /// Set via `defaults write`; no menu UI by design.
    var cleanupModelPath: String? {
        get {
            guard let raw = defaults.string(forKey: Key.cleanupModelPath),
                !raw.trimmingCharacters(in: .whitespaces).isEmpty
            else { return nil }
            return raw
        }
        set { defaults.set(newValue, forKey: Key.cleanupModelPath) }
    }

    /// The picked cleanup model (`CleanupModelID.rawValue`); nil = never
    /// chosen, and AppModel resolves one via `CleanupModelCatalog.resolve`.
    /// `cleanupModelPath`, when set, overrides this.
    var cleanupModel: String? {
        get { defaults.string(forKey: Key.cleanupModel) }
        set { defaults.set(newValue, forKey: Key.cleanupModel) }
    }

    /// CoreAudio UID of the capture device; nil = system default.
    /// The built-in mic avoids the Bluetooth HFP renegotiation delay.
    var microphoneUID: String? {
        get {
            guard let raw = defaults.string(forKey: Key.microphoneUID), !raw.isEmpty
            else { return nil }
            return raw
        }
        set { defaults.set(newValue, forKey: Key.microphoneUID) }
    }

    /// Maps legacy config.toml dotted keys (`section.key`) to settings keys.
    private static let tomlKeyMap: [String: String] = [
        "hotkey.key": "hotkey",
        "hotkey.hold_threshold_s": "holdThreshold",
        "stt.engine": "engine",
        "cleanup.enabled": "cleanupEnabled",
        "cleanup.min_words": "minWords",
        "cleanup.timeout_s": "cleanupTimeout",
        "cleanup.length_band": "lengthBand",
        "paste.clipboard_restore_delay_s": "restoreDelay",
        "audio.energy_gate_rms": "energyGate",
        "ui.sounds": "sounds",
        "ui.history_size": "historySize",
        "memory.idle_unload_minutes": "idleUnloadMinutes",
    ]

    /// Minimal legacy config.toml parser; anything unparseable is silently ignored.
    static func importToml(_ text: String) -> [String: Any] {
        var result: [String: Any] = [:]
        var section = ""

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(rawLine)
            if let hashIndex = line.firstIndex(of: "#") {
                line = String(line[line.startIndex..<hashIndex])
            }
            line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("[") && line.hasSuffix("]") {
                section = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                continue
            }

            guard let eqIndex = line.firstIndex(of: "=") else { continue }
            let key = line[line.startIndex..<eqIndex].trimmingCharacters(in: .whitespaces)
            let rawValue = line[line.index(after: eqIndex)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !rawValue.isEmpty else { continue }
            guard let parsed = parseValue(rawValue) else { continue }

            let pythonKey = "\(section).\(key)"
            guard let settingsKey = tomlKeyMap[pythonKey] else { continue }
            guard let value = coerce(parsed, forSettingsKey: settingsKey) else { continue }

            result[settingsKey] = value
        }

        return result
    }

    /// Coerces a parsed TOML scalar to the setting's type; rejects values of the wrong shape.
    private static func coerce(_ value: Any, forSettingsKey key: String) -> Any? {
        switch key {
        case "hotkey":
            guard let str = value as? String, HotKey(rawValue: str) != nil else { return nil }
            return str
        case "engine":
            return value as? String
        case "cleanupEnabled", "sounds":
            return value as? Bool
        case "minWords", "historySize":
            return asInt(value)
        case "holdThreshold", "cleanupTimeout", "restoreDelay", "energyGate", "idleUnloadMinutes":
            return asDouble(value)
        case "lengthBand":
            guard let arr = value as? [Double], arr.count == 2 else { return nil }
            return arr
        default:
            return nil
        }
    }

    /// Parses a quoted string, bool, number, or 2-number array; nil for anything else.
    private static func parseValue(_ raw: String) -> Any? {
        if raw.count >= 2, raw.hasPrefix("\""), raw.hasSuffix("\"") {
            return String(raw.dropFirst().dropLast())
        }
        if raw == "true" { return true }
        if raw == "false" { return false }
        if raw.hasPrefix("["), raw.hasSuffix("]") {
            let inner = raw.dropFirst().dropLast()
            let parts = inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { return nil }
            let nums = parts.compactMap { Double($0) }
            guard nums.count == 2 else { return nil }
            return nums
        }
        if let intVal = Int(raw) { return intVal }
        if let dblVal = Double(raw) { return dblVal }
        return nil
    }

    private static func asDouble(_ value: Any) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        return nil
    }

    private static func asInt(_ value: Any) -> Int? {
        if let i = value as? Int { return i }
        if let d = value as? Double { return Int(d) }
        return nil
    }

    /// One-time best-effort import of config.toml (`tomlText` is a test seam). The hotkey is
    /// deliberately excluded: importing it would change which key drives the app mid-migration.
    func importFromPythonConfigOnce(tomlText: String? = nil) {
        guard !defaults.bool(forKey: Key.didImportToml) else { return }
        defer { defaults.set(true, forKey: Key.didImportToml) }

        let text: String
        if let tomlText {
            text = tomlText
        } else {
            let path = NSString(string: "~/.config/scribe/config.toml").expandingTildeInPath
            guard let fileText = try? String(contentsOfFile: path, encoding: .utf8) else { return }
            text = fileText
        }

        for (key, value) in Self.importToml(text) {
            guard key != "hotkey" else { continue }
            apply(key: key, value: value)
        }
    }

    /// Applies an already-typed value to the matching property.
    private func apply(key: String, value: Any) {
        switch key {
        case "holdThreshold":
            if let v = value as? Double { holdThreshold = v }
        case "engine":
            if let v = value as? String { engine = v }
        case "cleanupEnabled":
            if let v = value as? Bool { cleanupEnabled = v }
        case "minWords":
            if let v = value as? Int { minWords = v }
        case "cleanupTimeout":
            if let v = value as? Double { cleanupTimeout = v }
        case "lengthBand":
            if let v = value as? [Double], v.count == 2 { lengthBand = (v[0], v[1]) }
        case "restoreDelay":
            if let v = value as? Double { restoreDelay = v }
        case "energyGate":
            if let v = value as? Double { energyGate = v }
        case "sounds":
            if let v = value as? Bool { sounds = v }
        case "historySize":
            if let v = value as? Int { historySize = v }
        case "idleUnloadMinutes":
            if let v = value as? Double { idleUnloadMinutes = v }
        default:
            break
        }
    }
}
