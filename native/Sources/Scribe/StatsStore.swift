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

    var onChange: (() -> Void)? {
        get { queue.sync { changeHandler } }
        set { queue.sync { changeHandler = newValue } }
    }

    /// Calendar day in the given time zone, so "today" matches the clock in the menu bar.
    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    func record(_ stat: DictationStat, at date: Date = Date(), calendar: Calendar = .current) {
        let key = Self.dayKey(date, calendar: calendar)
        queue.async {
            let index: Int
            if let existing = self.days.firstIndex(where: { $0.day == key }) {
                index = existing
            } else {
                self.days.append(DayStats(day: key))
                if self.days.count > Self.keepDays {
                    self.days.removeFirst(self.days.count - Self.keepDays)
                }
                index = self.days.count - 1
            }
            self.days[index].dictations += 1
            self.days[index].words += stat.words
            if stat.cleaned { self.days[index].cleaned += 1 }
            if stat.rawFallback { self.days[index].rawFallbacks += 1 }
            if self.days[index].sttMs.count < Self.maxSamplesPerDay {
                self.days[index].sttMs.append(stat.sttMs)
            }
            if let ms = stat.cleanupMs, self.days[index].cleanupMs.count < Self.maxSamplesPerDay {
                self.days[index].cleanupMs.append(ms)
            }
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
    func summary(days window: Int, now: Date = Date(), calendar: Calendar = .current) -> StatsSummary {
        let keys = Set((0..<max(1, window)).compactMap { offset -> String? in
            calendar.date(byAdding: .day, value: -offset, to: now).map { Self.dayKey($0, calendar: calendar) }
        })
        let selected = queue.sync { days.filter { keys.contains($0.day) } }
        let stt = selected.flatMap(\.sttMs)
        let cleanup = selected.flatMap(\.cleanupMs)
        return StatsSummary(
            days: window,
            dictations: selected.reduce(0) { $0 + $1.dictations },
            words: selected.reduce(0) { $0 + $1.words },
            cleaned: selected.reduce(0) { $0 + $1.cleaned },
            rawFallbacks: selected.reduce(0) { $0 + $1.rawFallbacks },
            sttP50: Self.percentile(stt, 50), sttP95: Self.percentile(stt, 95),
            cleanupP50: Self.percentile(cleanup, 50), cleanupP95: Self.percentile(cleanup, 95))
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
