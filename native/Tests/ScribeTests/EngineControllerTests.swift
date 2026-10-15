import XCTest

/// Pins the engine-switch protocol (begin, commit, failed load, revert, supersede, idle unload) with gated fake
/// engines, so cancellation orderings are driven by the test and not by timing.
@MainActor
final class EngineControllerTests: XCTestCase {
    private struct CommitSnapshot {
        let engine: String
        let name: String
        let active: String
        let pending: String?
        let storedEngine: String
        let previousUnloads: Int
    }

    @MainActor
    private final class Harness {
        let suiteName = UUID().uuidString
        let defaults: UserDefaults
        let settings: AppSettings
        let parakeet = FakeUnloadableEngine(name: "parakeet", loaded: true)
        let whisper = FakeUnloadableEngine(name: "whisper")
        /// A third engine so one switch can be superseded by a switch to a different engine.
        let tiny = FakeUnloadableEngine(name: "tiny")
        /// What the controller looked like inside each commit callback.
        var commits: [CommitSnapshot] = []
        let logs = Locked<[String]>([])
        var controller: EngineController!

        init() {
            defaults = UserDefaults(suiteName: suiteName)!
            settings = AppSettings(defaults: defaults)
            settings.engine = "parakeet"
        }

        func tearDown() {
            // A suspended load would leak its task past the test.
            for engine in [parakeet, whisper, tiny] { engine.releasePreload() }
            defaults.removePersistentDomain(forName: suiteName)
        }

        func makeController(failureStickySeconds: Double = 10) -> EngineController {
            let logs = self.logs
            controller = EngineController(
                engines: ["parakeet": parakeet, "whisper": whisper, "tiny": tiny],
                startingEngine: "parakeet",
                settings: settings,
                onEngineCommitted: { [unowned self] engine, name in
                    self.commits.append(
                        CommitSnapshot(
                            engine: engine.name, name: name,
                            active: self.controller.activeEngineName, pending: self.controller.pendingEngineName,
                            storedEngine: self.settings.engine, previousUnloads: self.parakeet.unloadCalls))
                },
                failureStickySeconds: failureStickySeconds,
                log: { line in logs.mutate { $0.append(line) } })
            return controller
        }
    }

    private var h: Harness!

    override func setUp() {
        super.setUp()
        h = Harness()
    }

    override func tearDown() {
        h.tearDown()
        h = nil
        super.tearDown()
    }

    /// Begins a switch to `name` and returns its task (held open by the gated engine).
    private func beginSwitch(_ controller: EngineController, to name: String) -> Task<Void, Never> {
        controller.switchEngine(to: name)
        XCTAssertEqual(controller.pendingEngineName, name)
        return controller.engineSwitchTask!
    }

    // MARK: - Init and labels

    func testInitPublishesTheStartingEngine() {
        let c = h.makeController()

        XCTAssertEqual(c.activeEngineName, "parakeet")
        XCTAssertNil(c.pendingEngineName)
        XCTAssertNil(c.engineStatus)
        XCTAssertTrue((c.activeEngine as AnyObject) === h.parakeet)
        XCTAssertEqual(Set(c.engines.keys), ["parakeet", "whisper", "tiny"])
    }

    func testLabelNamesTheKnownEnginesAndPassesOthersThrough() {
        XCTAssertEqual(EngineController.label("parakeet"), "Parakeet")
        XCTAssertEqual(EngineController.label("whisper"), "Whisper")
        XCTAssertEqual(EngineController.label("tiny"), "tiny")
    }

    // MARK: - Begin

    func testBeginPublishesPendingAndLoadingWithoutCommitting() async {
        let c = h.makeController()

        _ = beginSwitch(c, to: "whisper")

        XCTAssertEqual(c.engineStatus, "Loading Whisper…")
        XCTAssertEqual(c.activeEngineName, "parakeet", "the radio keeps the committed engine until the load commits")
        XCTAssertEqual(h.settings.engine, "parakeet")
        XCTAssertTrue(h.commits.isEmpty)
        let started = await eventually { h.whisper.preloadCalls == 1 }
        XCTAssertTrue(started)
    }

    func testSelectingAnUnknownEngineIsIgnored() {
        let c = h.makeController()

        c.switchEngine(to: "gemma")

        XCTAssertNil(c.pendingEngineName)
        XCTAssertNil(c.engineStatus)
    }

    // MARK: - Commit

    func testCommitSwapsTheEnginePersistsTheChoiceAndClearsTheStatus() async {
        let c = h.makeController()
        let task = beginSwitch(c, to: "whisper")

        h.whisper.releasePreload(loaded: true)
        await task.value

        XCTAssertEqual(c.activeEngineName, "whisper")
        XCTAssertNil(c.pendingEngineName)
        XCTAssertNil(c.engineStatus)
        XCTAssertTrue((c.activeEngine as AnyObject) === h.whisper)
        XCTAssertEqual(h.settings.engine, "whisper")
        XCTAssertEqual(h.commits.count, 1)
        XCTAssertEqual(h.commits[0].engine, "whisper")
        XCTAssertEqual(h.commits[0].name, "whisper")
        XCTAssertTrue(h.logs.value.contains("switched engine to whisper"))
        XCTAssertEqual(h.whisper.unloadCalls, 0)
    }

    func testCommitCallbackRunsBeforeAnyStateMovesAndBeforeThePreviousEngineUnloads() async {
        let c = h.makeController()
        let task = beginSwitch(c, to: "whisper")

        h.whisper.releasePreload(loaded: true)
        await task.value

        // The pipeline must hold the new engine before the old one is unloaded and before the UI flips.
        XCTAssertEqual(h.commits[0].active, "parakeet")
        XCTAssertEqual(h.commits[0].pending, "whisper")
        XCTAssertEqual(h.commits[0].storedEngine, "parakeet")
        XCTAssertEqual(h.commits[0].previousUnloads, 0)
        XCTAssertEqual(h.parakeet.unloadCalls, 1)
    }

    func testRepeatSelectionOfTheCommittedEngineIsIgnoredAfterwards() async {
        let c = h.makeController()
        let task = beginSwitch(c, to: "whisper")
        h.whisper.releasePreload(loaded: true)
        await task.value

        c.switchEngine(to: "whisper")

        XCTAssertNil(c.pendingEngineName)
        XCTAssertEqual(h.whisper.preloadCalls, 1)
    }

    // MARK: - Failed load

    func testFailedLoadKeepsThePreviousEngineAndSaysSo() async {
        let c = h.makeController()
        let task = beginSwitch(c, to: "whisper")

        h.whisper.releasePreload(loaded: false)
        await task.value

        XCTAssertTrue(h.commits.isEmpty, "a failed load must never become the active engine")
        XCTAssertEqual(c.activeEngineName, "parakeet")
        XCTAssertTrue((c.activeEngine as AnyObject) === h.parakeet)
        XCTAssertNil(c.pendingEngineName)
        XCTAssertEqual(c.engineStatus, "Couldn't load Whisper — still using Parakeet")
        XCTAssertEqual(h.settings.engine, "parakeet")
        XCTAssertEqual(h.parakeet.unloadCalls, 0)
        XCTAssertTrue(h.logs.value.contains("engine switch to whisper failed to load"))
    }

    func testFailureStatusClearsAfterTheStickyWindow() async {
        let c = h.makeController(failureStickySeconds: 0.05)
        let task = beginSwitch(c, to: "whisper")
        h.whisper.releasePreload(loaded: false)
        await task.value
        XCTAssertNotNil(c.engineStatus)

        let cleared = await eventually { c.engineStatus == nil }

        XCTAssertTrue(cleared)
    }

    func testFailureStatusSticksUntilTheWindowEnds() async {
        let c = h.makeController(failureStickySeconds: 30)
        let task = beginSwitch(c, to: "whisper")
        h.whisper.releasePreload(loaded: false)
        await task.value

        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(c.engineStatus, "Couldn't load Whisper — still using Parakeet")
    }

    func testANewSwitchReplacesTheFailureAndTheOldWindowDoesNotClearIt() async {
        let c = h.makeController(failureStickySeconds: 0.05)
        let failed = beginSwitch(c, to: "whisper")
        h.whisper.releasePreload(loaded: false)
        await failed.value

        _ = beginSwitch(c, to: "tiny")
        XCTAssertEqual(c.engineStatus, "Loading tiny…")
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(c.engineStatus, "Loading tiny…", "the failure's clear must not wipe a newer status")
    }

    func testAFailedRetryAfterAFailureIsStillReported() async {
        let c = h.makeController(failureStickySeconds: 0.05)
        let first = beginSwitch(c, to: "tiny")
        h.tiny.releasePreload(loaded: false)
        await first.value

        let second = beginSwitch(c, to: "whisper")
        h.whisper.releasePreload(loaded: false)
        await second.value

        XCTAssertEqual(c.engineStatus, "Couldn't load Whisper — still using Parakeet")
        XCTAssertNil(c.pendingEngineName)
    }

    // MARK: - Revert

    func testRevertingMidLoadAbandonsTheSwitchAndUnloadsTheOrphan() async {
        let c = h.makeController()
        let task = beginSwitch(c, to: "whisper")

        c.switchEngine(to: "parakeet")

        XCTAssertNil(c.pendingEngineName)
        XCTAssertNil(c.engineStatus)
        XCTAssertNil(c.engineSwitchTask)
        XCTAssertTrue(task.isCancelled)

        h.whisper.releasePreload(loaded: true)
        await task.value

        XCTAssertEqual(h.whisper.unloadCalls, 1)
        XCTAssertTrue(h.commits.isEmpty)
        XCTAssertEqual(c.activeEngineName, "parakeet")
        XCTAssertEqual(h.parakeet.unloadCalls, 0)
        XCTAssertEqual(h.settings.engine, "parakeet")
        XCTAssertNil(c.engineStatus, "a revert must leave no status behind")
    }

    // MARK: - Ignore

    func testSelectingTheActiveEngineWithNothingPendingStartsNothing() {
        let c = h.makeController()

        c.switchEngine(to: "parakeet")

        XCTAssertNil(c.pendingEngineName)
        XCTAssertNil(c.engineSwitchTask)
        XCTAssertEqual(h.parakeet.preloadCalls, 0)
    }

    func testSelectingThePendingEngineStartsNothingNew() async {
        let c = h.makeController()
        let task = beginSwitch(c, to: "whisper")
        _ = await eventually { h.whisper.preloadCalls == 1 }

        c.switchEngine(to: "whisper")

        XCTAssertFalse(task.isCancelled)
        XCTAssertTrue(c.engineSwitchTask == task)
        XCTAssertEqual(h.whisper.preloadCalls, 1)
        XCTAssertEqual(c.engineStatus, "Loading Whisper…")
    }

    // MARK: - Supersede

    func testASupersededLoadIsUnloadedAndNeverCommitted() async {
        let c = h.makeController()
        let whisperTask = beginSwitch(c, to: "whisper")
        let tinyTask = beginSwitch(c, to: "tiny")

        XCTAssertTrue(whisperTask.isCancelled)
        XCTAssertEqual(c.engineStatus, "Loading tiny…")

        h.whisper.releasePreload(loaded: true)
        await whisperTask.value

        XCTAssertEqual(h.whisper.unloadCalls, 1)
        XCTAssertTrue(h.commits.isEmpty)
        XCTAssertEqual(c.pendingEngineName, "tiny", "the cancelled load must not clear the newer switch")
        XCTAssertEqual(c.engineStatus, "Loading tiny…")

        h.tiny.releasePreload(loaded: true)
        await tinyTask.value

        XCTAssertEqual(h.commits.map(\.name), ["tiny"])
        XCTAssertEqual(c.activeEngineName, "tiny")
        XCTAssertEqual(h.settings.engine, "tiny")
        XCTAssertEqual(h.tiny.unloadCalls, 0)
        XCTAssertEqual(h.parakeet.unloadCalls, 1)
    }

    func testASupersededLoadThatEndsNotLoadedDoesNotClobberTheNewerSwitch() async {
        let c = h.makeController()
        let whisperTask = beginSwitch(c, to: "whisper")
        let tinyTask = beginSwitch(c, to: "tiny")

        h.whisper.releasePreload(loaded: false)
        await whisperTask.value

        XCTAssertEqual(c.pendingEngineName, "tiny")
        XCTAssertEqual(c.engineStatus, "Loading tiny…", "no stale failure message from the old load")

        h.tiny.releasePreload(loaded: true)
        await tinyTask.value
        XCTAssertEqual(c.activeEngineName, "tiny")
    }

    func testReselectingAnEngineWhileItsOldLoadIsInFlightDoesNotUnloadIt() async {
        // Revert, then pick the same engine again: the newer switch shares the engine's single load.
        let c = h.makeController()
        let oldTask = beginSwitch(c, to: "whisper")
        c.switchEngine(to: "parakeet")
        let newTask = beginSwitch(c, to: "whisper")

        h.whisper.releasePreload(loaded: true)
        await oldTask.value
        await newTask.value

        XCTAssertEqual(h.whisper.unloadCalls, 0)
        XCTAssertEqual(h.commits.map(\.name), ["whisper"])
        XCTAssertEqual(c.activeEngineName, "whisper")
        XCTAssertEqual(h.settings.engine, "whisper")
    }

    func testASwitchCancelledWhileCheckingIsLoadedStillUnloadsInsteadOfCommitting() async {
        // The second cancellation check: a revert can land in the `isLoaded` await, after the first check
        // passed and before the commit.
        let c = h.makeController()
        let task = beginSwitch(c, to: "whisper")
        h.whisper.onIsLoaded = { c.switchEngine(to: "parakeet") }

        h.whisper.releasePreload(loaded: true)
        await task.value

        XCTAssertEqual(h.whisper.unloadCalls, 1)
        XCTAssertTrue(h.commits.isEmpty)
        XCTAssertEqual(c.activeEngineName, "parakeet")
        XCTAssertEqual(h.settings.engine, "parakeet")
        XCTAssertNil(c.pendingEngineName)
        XCTAssertNil(c.engineStatus)
    }

    func testASwitchSupersededWhileCheckingIsLoadedThatEndsNotLoadedDoesNotClobberTheNewerSwitch() async {
        // Same suspension point, failed load: the failure path must not clear the newer switch's pending
        // engine or overwrite its status.
        let c = h.makeController()
        let whisperTask = beginSwitch(c, to: "whisper")
        h.whisper.onIsLoaded = { c.switchEngine(to: "tiny") }

        h.whisper.releasePreload(loaded: false)
        await whisperTask.value

        XCTAssertEqual(c.pendingEngineName, "tiny")
        XCTAssertEqual(c.engineStatus, "Loading tiny…")
        XCTAssertTrue(h.commits.isEmpty)
        XCTAssertFalse(h.logs.value.contains("engine switch to whisper failed to load"))
        XCTAssertEqual(h.whisper.unloadCalls, 1)

        h.tiny.releasePreload(loaded: true)
        await c.engineSwitchTask?.value
        XCTAssertEqual(c.activeEngineName, "tiny")
    }

    // MARK: - Idle unload

    func testUnloadAllUnloadsEveryResidentEngineAndReportsIt() async {
        let c = h.makeController()
        h.whisper.loaded = true

        let unloaded = await c.unloadAll()

        XCTAssertTrue(unloaded)
        XCTAssertEqual(h.parakeet.unloadCalls, 1)
        XCTAssertEqual(h.whisper.unloadCalls, 1)
        XCTAssertEqual(h.tiny.unloadCalls, 0, "a cold engine has nothing to free")
    }

    func testUnloadAllReportsNothingWhenNoEngineIsResident() async {
        let c = h.makeController()
        h.parakeet.loaded = false

        let unloaded = await c.unloadAll()

        XCTAssertFalse(unloaded)
        XCTAssertEqual(h.parakeet.unloadCalls, 0)
        XCTAssertEqual(h.whisper.unloadCalls, 0)
    }

    func testUnloadAllSparesTheEngineASwitchIsAboutToCommit() async {
        let c = h.makeController()
        let task = beginSwitch(c, to: "whisper")
        h.whisper.loaded = true  // the load finished; the switch hasn't checked `isLoaded` yet

        _ = await c.unloadAll()

        XCTAssertEqual(h.whisper.unloadCalls, 0)
        XCTAssertEqual(h.parakeet.unloadCalls, 1)
        h.whisper.releasePreload()
        await task.value
        XCTAssertEqual(c.activeEngineName, "whisper")
    }
}
