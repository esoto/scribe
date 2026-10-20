import XCTest

final class StatsStoreTests: XCTestCase {
    private var dir: URL!
    private let calendar = Calendar(identifier: .gregorian)
    private let noon = Date(timeIntervalSince1970: 1_700_000_000)  // 2023-11-14 22:13 UTC

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private var fileURL: URL { dir.appendingPathComponent("stats.json") }
    private func makeStore() -> StatsStore { StatsStore(fileURL: fileURL) }

    private func stat(words: Int = 10, cleaned: Bool = true, fallback: Bool = false, stt: Int = 200, cleanup: Int? = 600) -> DictationStat {
        DictationStat(words: words, cleaned: cleaned, rawFallback: fallback, sttMs: stt, cleanupMs: cleanup)
    }

    private func daysAgo(_ n: Int) -> Date { calendar.date(byAdding: .day, value: -n, to: noon)! }

    func testRecordsCountsAndLatenciesForToday() {
        let store = makeStore()
        store.record(stat(words: 12, stt: 150, cleanup: 500), at: noon, calendar: calendar)
        store.record(stat(words: 8, cleaned: false, fallback: true, stt: 250, cleanup: 6000), at: noon, calendar: calendar)
        store.record(stat(words: 3, cleaned: false, stt: 100, cleanup: nil), at: noon, calendar: calendar)

        let today = store.summary(days: 1, now: noon, calendar: calendar)
        XCTAssertEqual(today.dictations, 3)
        XCTAssertEqual(today.words, 23)
        XCTAssertEqual(today.cleaned, 1)
        XCTAssertEqual(today.rawFallbacks, 1)
        XCTAssertEqual(today.sttP50, 150)
        XCTAssertEqual(today.sttP95, 250)
        // Cleanup that never ran contributes no latency sample.
        XCTAssertEqual(today.cleanupP50, 500)
        XCTAssertEqual(today.cleanupP95, 6000)
        XCTAssertEqual(today.rawFallbackPercent, 50)
    }

    func testWindowsSelectWholeCalendarDays() {
        let store = makeStore()
        store.record(stat(words: 1), at: noon, calendar: calendar)
        store.record(stat(words: 10), at: daysAgo(3), calendar: calendar)
        store.record(stat(words: 100), at: daysAgo(10), calendar: calendar)

        XCTAssertEqual(store.summary(days: 1, now: noon, calendar: calendar).words, 1)
        XCTAssertEqual(store.summary(days: 7, now: noon, calendar: calendar).words, 11)
        XCTAssertEqual(store.summary(days: 30, now: noon, calendar: calendar).words, 111)
        XCTAssertEqual(store.summary(days: 0, now: noon, calendar: calendar).words, 1)
    }

    func testEmptySummaryHasNoPercentiles() {
        let s = makeStore().summary(days: 7, now: noon, calendar: calendar)
        XCTAssertEqual(s.dictations, 0)
        XCTAssertNil(s.sttP50)
        XCTAssertNil(s.cleanupP95)
        XCTAssertNil(s.rawFallbackPercent)
        XCTAssertEqual(s.typingMinutesReplaced, 0)
    }

    func testPersistsAcrossInstancesAndResets() {
        let store = makeStore()
        store.record(stat(words: 40), at: noon, calendar: calendar)
        XCTAssertEqual(store.summary(days: 1, now: noon, calendar: calendar).words, 40)

        let reopened = makeStore()
        XCTAssertEqual(reopened.summary(days: 1, now: noon, calendar: calendar).words, 40)

        reopened.reset()
        XCTAssertEqual(reopened.summary(days: 1, now: noon, calendar: calendar).dictations, 0)
        XCTAssertEqual(makeStore().summary(days: 1, now: noon, calendar: calendar).dictations, 0)
    }

    func testKeepsOnlyTheLastNinetyDays() {
        let store = makeStore()
        for n in stride(from: 100, through: 0, by: -1) {
            store.record(stat(words: 1), at: daysAgo(n), calendar: calendar)
        }
        XCTAssertEqual(store.summary(days: 365, now: noon, calendar: calendar).dictations, StatsStore.keepDays)
    }

    func testLatencySamplesStopAtTheCapButCountsContinue() {
        let store = makeStore()
        for _ in 0..<(StatsStore.maxSamplesPerDay + 5) {
            store.record(stat(words: 1), at: noon, calendar: calendar)
        }
        let s = store.summary(days: 1, now: noon, calendar: calendar)
        XCTAssertEqual(s.dictations, StatsStore.maxSamplesPerDay + 5)
        XCTAssertEqual(s.sttP50, 200)
    }

    func testOnChangeFiresAfterAWrite() {
        let store = makeStore()
        let fired = expectation(description: "onChange")
        store.onChange = { fired.fulfill() }
        store.record(stat(), at: noon, calendar: calendar)
        wait(for: [fired], timeout: 2)
    }

    func testIgnoresAFileOfAnotherVersion() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try #"{"version": 99, "days": [{"day": "2023-11-14", "dictations": 7, "words": 7, "cleaned": 0, "rawFallbacks": 0, "sttMs": [], "cleanupMs": []}]}"#
            .write(to: fileURL, atomically: true, encoding: .utf8)
        XCTAssertEqual(makeStore().summary(days: 365, now: noon, calendar: calendar).dictations, 0)
    }

    func testPercentileIsNearestRank() {
        XCTAssertNil(StatsStore.percentile([], 50))
        XCTAssertEqual(StatsStore.percentile([7], 95), 7)
        XCTAssertEqual(StatsStore.percentile([1, 2, 3, 4], 50), 2)
        XCTAssertEqual(StatsStore.percentile([4, 1, 3, 2], 95), 4)
        XCTAssertEqual(StatsStore.percentile(Array(1...100), 95), 95)
    }

    func testDayKeyUsesTheCalendarDay() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(StatsStore.dayKey(noon, calendar: utc), "2023-11-14")
    }

    // MARK: - Pane text

    func testCountsLine() {
        var s = StatsSummary(days: 1, dictations: 0, words: 0, cleaned: 0, rawFallbacks: 0)
        XCTAssertEqual(statsCountsLine(s), "No dictations")
        s.dictations = 1
        s.words = 20
        XCTAssertEqual(statsCountsLine(s), "1 dictation · 20 words · ≈ 1 min of typing")
        s.dictations = 12
        s.words = 480
        XCTAssertEqual(statsCountsLine(s), "12 dictations · 480 words · ≈ 12 min of typing")
    }

    func testLatencyAndFallbackLines() {
        var s = StatsSummary(days: 1, dictations: 50, words: 500, cleaned: 46, rawFallbacks: 2)
        XCTAssertNil(statsLatencyLine(s))
        s.sttP50 = 180
        s.sttP95 = 410
        XCTAssertEqual(statsLatencyLine(s), "Transcription 180 ms (median) · slowest 5%: 410 ms")
        s.cleanupP50 = 640
        s.cleanupP95 = 2100
        XCTAssertEqual(statsLatencyLine(s), "Transcription 180 ms · cleanup 640 ms (median) · slowest 5%: 410 / 2100 ms")
        XCTAssertEqual(statsFallbackLine(s), "Pasted raw 2 of 48 cleanups (4%)")
        s.cleaned = 0
        s.rawFallbacks = 0
        XCTAssertNil(statsFallbackLine(s))
    }

    @MainActor
    func testStatsModelRefreshesAfterARecord() async {
        let store = makeStore()
        let model = StatsModel(store: store, now: { [noon] in noon })
        XCTAssertEqual(model.today.dictations, 0)
        store.record(stat(), at: noon)
        let refreshed = await eventually { model.today.dictations == 1 && model.week.dictations == 1 }
        XCTAssertTrue(refreshed)
    }
}
