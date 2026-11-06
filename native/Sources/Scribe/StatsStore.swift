import Foundation

/// What one dictation contributes. Counts and durations only — never text.
struct DictationStat: Equatable {
    var words: Int
    var cleaned: Bool
    /// Cleanup ran and fell back to the raw transcript (timeout, error, gate).
    var rawFallback: Bool
    var sttMs: Int
    /// nil when cleanup did not run (off, too short, no model).
    var cleanupMs: Int?
}

/// What one edit contributes. Numbers and a fixed vocabulary only — never the selection, the instruction or the result.
struct EditStat: Equatable {
    var verb: EditVerb
    var sttMs: Int
    /// The model call's wall time, a timeout's deadline included.
    var editMs: Int?
    /// The result passed every gate. A paste that then fell back to copy-only still counts: the gates are what this tunes.
    var accepted: Bool
    var rejection: EditRejection?
}

/// One calendar day of counters. Latencies are kept as bare integers so p50/p95 can be read back; no timestamps,
/// no text, no per-app split.
struct DayStats: Codable, Equatable {
    var day: String
    var dictations = 0
    var words = 0
    var cleaned = 0
    var rawFallbacks = 0
    var sttMs: [Int] = []
    var cleanupMs: [Int] = []
    var edits = 0
    var editsAccepted = 0
    var editMs: [Int] = []
    /// Counts keyed by `EditVerb.logName`, a fixed vocabulary; never anything the user said or selected.
    var editsByVerb: [String: Int] = [:]
}

/// Written by hand so a file from before edits (no edit keys) still loads, and a day without edits writes exactly the
/// keys it always did. An extension, so the memberwise `DayStats(day:)` stays.
extension DayStats {
    private enum CodingKeys: String, CodingKey {
        case day, dictations, words, cleaned, rawFallbacks, sttMs, cleanupMs
        case edits, editsAccepted, editMs, editsByVerb
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        day = try c.decode(String.self, forKey: .day)
        dictations = try c.decode(Int.self, forKey: .dictations)
        words = try c.decode(Int.self, forKey: .words)
        cleaned = try c.decode(Int.self, forKey: .cleaned)
        rawFallbacks = try c.decode(Int.self, forKey: .rawFallbacks)
        sttMs = try c.decode([Int].self, forKey: .sttMs)
        cleanupMs = try c.decode([Int].self, forKey: .cleanupMs)
        edits = try c.decodeIfPresent(Int.self, forKey: .edits) ?? 0
        editsAccepted = try c.decodeIfPresent(Int.self, forKey: .editsAccepted) ?? 0
        editMs = try c.decodeIfPresent([Int].self, forKey: .editMs) ?? []
        editsByVerb = try c.decodeIfPresent([String: Int].self, forKey: .editsByVerb) ?? [:]
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(day, forKey: .day)
        try c.encode(dictations, forKey: .dictations)
        try c.encode(words, forKey: .words)
        try c.encode(cleaned, forKey: .cleaned)
        try c.encode(rawFallbacks, forKey: .rawFallbacks)
        try c.encode(sttMs, forKey: .sttMs)
        try c.encode(cleanupMs, forKey: .cleanupMs)
        guard edits > 0 else { return }
        try c.encode(edits, forKey: .edits)
        try c.encode(editsAccepted, forKey: .editsAccepted)
        try c.encode(editMs, forKey: .editMs)
        try c.encode(editsByVerb, forKey: .editsByVerb)
    }
}

struct StatsSummary: Equatable {
    var days: Int
    var dictations: Int
    var words: Int
    var cleaned: Int
    var rawFallbacks: Int
    var sttP50: Int?
    var sttP95: Int?
    var cleanupP50: Int?
    var cleanupP95: Int?
    var edits = 0
    var editsAccepted = 0
    var editP50: Int?

    /// The words at a 40 words-per-minute typing pace; a rough figure, and labelled as one.
    var typingMinutesReplaced: Int { Int((Double(words) / 40.0).rounded()) }

    /// Of the dictations where cleanup ran, the share that came back raw; nil when it never ran.
    var rawFallbackPercent: Int? {
        let ran = cleaned + rawFallbacks
        return ran == 0 ? nil : Int((Double(rawFallbacks) * 100 / Double(ran)).rounded())
    }
}

private struct StatsFile: Codable {
    var version: Int
    var days: [DayStats]
}

/// Local health counters, per day, in `stats.json` next to the dictionary. Thread-safe via a serial queue;
/// `onChange` fires on that queue after every write.
final class StatsStore: @unchecked Sendable {
    static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/scribe/stats.json")
    private static let fileVersion = 1
    static let keepDays = 90
    /// A day's latency lists stop growing here; the counts keep counting.
    static let maxSamplesPerDay = 500

    private let fileURL: URL
    private let queue = DispatchQueue(label: "dev.esoto.scribe.stats")
    private var days: [DayStats] = []
    private var changeHandler: (() -> Void)?

    init(fileURL: URL = StatsStore.defaultURL) {
        self.fileURL = fileURL
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        loadLocked()
    }

    /// Includes days older than any window the pane shows, so Reset stays reachable for them.
    var isEmpty: Bool { queue.sync { days.isEmpty } }

    /// Fires on the store's queue. A handler that reads the store must hop off it first (as `StatsModel` does):
    /// the accessors use `queue.sync`, which traps when called from that same queue.
    var onChange: (() -> Void)? {
        get { queue.sync { changeHandler } }
        set { queue.sync { changeHandler = newValue } }
    }

    /// Gregorian whatever the user's calendar setting, so keys stay yyyy-MM-dd and survive a change of that setting;
    /// the current time zone, so "today" matches the clock in the menu bar.
    static var keyCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    /// Calendar day in the given time zone, so "today" matches the clock in the menu bar.
    static func dayKey(_ date: Date, calendar: Calendar = StatsStore.keyCalendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// The key `offset` calendar days before `date`. Steps back from noon: Greenland skips 23:00 at its DST change,
    /// and stepping from 23:30 into that gap lands on the next day, dropping a day from the window.
    static func dayKey(daysBefore offset: Int, _ date: Date, calendar: Calendar) -> String? {
        let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: date) ?? date
        return calendar.date(byAdding: .day, value: -offset, to: noon).map { dayKey($0, calendar: calendar) }
    }

    func record(_ stat: DictationStat, at date: Date = Date(), calendar: Calendar = StatsStore.keyCalendar) {
        update(at: date, calendar: calendar) { day in
            day.dictations += 1
            day.words += stat.words
            if stat.cleaned { day.cleaned += 1 }
            if stat.rawFallback { day.rawFallbacks += 1 }
            if day.sttMs.count < Self.maxSamplesPerDay {
                day.sttMs.append(stat.sttMs)
            }
            if let ms = stat.cleanupMs, day.cleanupMs.count < Self.maxSamplesPerDay {
                day.cleanupMs.append(ms)
            }
        }
    }

    /// An edit counts on its own: it is not a dictation, and its transcription time is the instruction's, not speech.
    func record(_ stat: EditStat, at date: Date = Date(), calendar: Calendar = StatsStore.keyCalendar) {
        update(at: date, calendar: calendar) { day in
            day.edits += 1
            if stat.accepted { day.editsAccepted += 1 }
            day.editsByVerb[stat.verb.logName, default: 0] += 1
            if let ms = stat.editMs, day.editMs.count < Self.maxSamplesPerDay {
                day.editMs.append(ms)
            }
        }
    }

    private func update(at date: Date, calendar: Calendar, _ change: @escaping (inout DayStats) -> Void) {
        let key = Self.dayKey(date, calendar: calendar)
        // By calendar age, not entry count: light use must not keep a year of days the pane never shows.
        // An empty fallback keeps every day: a nil step (never seen for real dates) must not wipe the history.
        let oldestKept = Self.dayKey(daysBefore: Self.keepDays - 1, date, calendar: calendar) ?? ""
        queue.async {
            // Zero-padded yyyy-MM-dd keys compare as dates.
            self.days.removeAll { $0.day < oldestKept }
            let index: Int
            if let existing = self.days.firstIndex(where: { $0.day == key }) {
                index = existing
            } else {
                self.days.append(DayStats(day: key))
                index = self.days.count - 1
            }
            change(&self.days[index])
            self.persistLocked()
            self.changeHandler?()
        }
    }

    func reset() {
        queue.async {
            self.days.removeAll()
            self.persistLocked()
            self.changeHandler?()
        }
    }

    /// The last `window` calendar days ending today (1 = today only).
    func summary(days window: Int, now: Date = Date(), calendar: Calendar = StatsStore.keyCalendar) -> StatsSummary {
        let keys = Set((0..<max(1, window)).compactMap { Self.dayKey(daysBefore: $0, now, calendar: calendar) })
        let selected = queue.sync { days.filter { keys.contains($0.day) } }
        let stt = selected.flatMap(\.sttMs)
        let cleanup = selected.flatMap(\.cleanupMs)
        let edit = selected.flatMap(\.editMs)
        return StatsSummary(
            days: window,
            dictations: selected.reduce(0) { $0 + $1.dictations },
            words: selected.reduce(0) { $0 + $1.words },
            cleaned: selected.reduce(0) { $0 + $1.cleaned },
            rawFallbacks: selected.reduce(0) { $0 + $1.rawFallbacks },
            sttP50: Self.percentile(stt, 50), sttP95: Self.percentile(stt, 95),
            cleanupP50: Self.percentile(cleanup, 50), cleanupP95: Self.percentile(cleanup, 95),
            edits: selected.reduce(0) { $0 + $1.edits },
            editsAccepted: selected.reduce(0) { $0 + $1.editsAccepted },
            editP50: Self.percentile(edit, 50))
    }

    /// Nearest-rank percentile; nil for no samples.
    static func percentile(_ samples: [Int], _ p: Int) -> Int? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        let rank = Int((Double(p) / 100 * Double(sorted.count)).rounded(.up))
        return sorted[max(0, min(sorted.count - 1, rank - 1))]
    }

    private func loadLocked() {
        guard let data = try? Data(contentsOf: fileURL),
            let file = try? JSONDecoder().decode(StatsFile.self, from: data),
            file.version == Self.fileVersion
        else { return }
        days = file.days
    }

    private func persistLocked() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(StatsFile(version: Self.fileVersion, days: days)) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
