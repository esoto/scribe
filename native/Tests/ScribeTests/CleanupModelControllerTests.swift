import Combine
import XCTest

/// Pins the cleanup-model switch protocol (begin, commit, failed load, revert, supersede, Apple Intelligence
/// fallback) with gated fake backends, so cancellation orderings are driven by the test and not by timing.
@MainActor
final class CleanupModelControllerTests: XCTestCase {
    private struct FactoryCall {
        let selection: CleanupModelCatalog.Selection
        let relay: ProgressRelay
        let afmLost: @Sendable () -> Void
    }

    private final class Harness {
        let suiteName = UUID().uuidString
        let defaults: UserDefaults
        let settings: AppSettings
        /// One fake per factory call, in call order. Index 0 is the backend built at init.
        var backends: [FakeCleanupModelBackend] = []
        var factoryCalls: [FactoryCall] = []
        var committed: [(backend: any CleanupModelBackend, name: String)] = []
        var notifications: [String] = []
        var touchIdleCalls = 0
        /// `backends[0].unloadCalls` seen inside each commit callback: the old model must still be loaded then.
        var previousUnloadsAtCommit: [Int] = []
        var afmAvailable = true
        var afmReason: String?
        var snapshot = DictionarySnapshot(pairs: [], glossary: [])
        var initialBackendLoaded = false
        var failureStickySeconds: Double = 10
        /// nil = unknown, which never blocks a download; tests set a number to simulate a full disk.
        var freeDiskBytes: Int64?
        let statuses = Locked<[CleanupModelID: CleanupModelStore.Status]>([.gemma3: .downloaded(bytes: 100)])
        let statusComputations = Locked(0)
        let deletedRepos = Locked<[String]>([])
        let deleteError = Locked<Error?>(nil)
        let logs = Locked<[String]>([])

        init() {
            defaults = UserDefaults(suiteName: suiteName)!
            settings = AppSettings(defaults: defaults)
        }

        var relay: ProgressRelay { factoryCalls[0].relay }

        func tearDown() {
            // A suspended load would leak its task past the test.
            for backend in backends { backend.releasePreload() }
            defaults.removePersistentDomain(forName: suiteName)
        }

        @MainActor
        func makeController() -> CleanupModelController {
            let statuses = self.statuses
            let computations = self.statusComputations
            let deletedRepos = self.deletedRepos
            let deleteError = self.deleteError
            let logs = self.logs
            return CleanupModelController(
                settings: settings,
                makeBackend: { selection, relay, afmLost, _ in
                    let backend = FakeCleanupModelBackend(
                        loaded: self.backends.isEmpty && self.initialBackendLoaded, gatedPreload: true)
                    self.backends.append(backend)
                    self.factoryCalls.append(FactoryCall(selection: selection, relay: relay, afmLost: afmLost))
                    return backend
                },
                computeStatuses: {
                    computations.mutate { $0 += 1 }
                    return statuses.value
                },
                deleteModel: { repo in
                    if let error = deleteError.value { throw error }
                    deletedRepos.mutate { $0.append(repo) }
                },
                isAppleIntelligenceAvailable: { self.afmAvailable },
                appleIntelligenceUnavailableReason: { self.afmReason },
                dictionarySnapshot: { self.snapshot },
                onCleanerCommitted: { backend, name in
                    self.committed.append((backend, name))
                    self.previousUnloadsAtCommit.append(self.backends[0].unloadCalls)
                },
                notify: { self.notifications.append($0) },
                touchIdle: { self.touchIdleCalls += 1 },
                freeDiskBytes: { self.freeDiskBytes },
                failureStickySeconds: failureStickySeconds,
                log: { line in logs.mutate { $0.append(line) } })
        }
    }

    private var h: Harness!
    private var cancellables: Set<AnyCancellable> = []

    override func setUp() {
        super.setUp()
        h = Harness()
        h.settings.cleanupModel = CleanupModelID.gemma3.rawValue
        cancellables = []
    }

    override func tearDown() {
        h.tearDown()
        h = nil
        super.tearDown()
    }

    /// Begins a switch to `id` and returns its task and backend (gated, so the test decides the outcome).
    private func beginSwitch(
        _ controller: CleanupModelController, to id: CleanupModelID
    ) -> (task: Task<Void, Never>, backend: FakeCleanupModelBackend) {
        let before = h.backends.count
        controller.switchCleanupModel(to: id)
        XCTAssertEqual(h.backends.count, before + 1, "switching to \(id) should build exactly one backend")
        return (controller.cleanupSwitchTask!, h.backends[before])
    }

    // MARK: - Init

    func testInitBuildsTheResolvedBackendAndPublishesState() {
        h.statuses.value = [.gemma3: .downloaded(bytes: 100), .gemma4: .partial(bytes: 5)]
        h.afmReason = "Turn on Apple Intelligence in System Settings"

        let c = h.makeController()

        XCTAssertEqual(h.factoryCalls.count, 1)
        XCTAssertEqual(h.factoryCalls[0].selection, .model(.gemma3))
        XCTAssertEqual(c.activeSelection, .model(.gemma3))
        XCTAssertTrue(c.cleaner === h.backends[0])
        XCTAssertEqual(c.activeCleanupModel, "gemma3")
        XCTAssertNil(c.pendingCleanupModel)
        XCTAssertNil(c.cleanupModelStatus)
        XCTAssertNil(c.cleanupModelProgress)
        XCTAssertEqual(c.modelStatuses[.gemma4], .partial(bytes: 5))
        XCTAssertTrue(c.appleIntelligenceAvailable)
        XCTAssertEqual(c.appleIntelligenceUnavailableReason, "Turn on Apple Intelligence in System Settings")
        XCTAssertEqual(h.statusComputations.value, 1)
    }

    func testInitPinsTheResolvedChoiceWhenNothingIsStored() {
        h.settings.cleanupModel = nil

        _ = h.makeController()

        XCTAssertEqual(h.settings.cleanupModel, CleanupModelCatalog.defaultID.rawValue)
    }

    func testInitDoesNotOverwriteAStoredAppleIntelligenceChoiceWhenItIsTransientlyUnavailable() {
        h.settings.cleanupModel = CleanupModelID.appleIntelligence.rawValue
        h.afmAvailable = false

        let c = h.makeController()

        XCTAssertEqual(c.activeCleanupModel, "gemma3", "falls back to a Gemma for this run")
        XCTAssertEqual(h.settings.cleanupModel, "appleIntelligence", "but the stored choice survives")
    }

    func testCustomPathSelectionIsFidelityUnsafeAndNotPinned() {
        h.settings.cleanupModel = nil
        h.settings.cleanupModelPath = "/models/custom"

        let c = h.makeController()

        XCTAssertEqual(c.activeSelection, .custom(path: "/models/custom"))
        XCTAssertEqual(c.activeCleanupModel, "custom")
        XCTAssertFalse(c.activeCleanupFidelitySafe)
        XCTAssertEqual(c.activeSelectionLabel, "the custom model")
        XCTAssertNil(h.settings.cleanupModel)
    }

    func testFidelitySafetyFollowsTheActiveModel() {
        h.settings.cleanupModel = CleanupModelID.gemma4.rawValue
        let c = h.makeController()
        XCTAssertTrue(c.activeCleanupFidelitySafe)
        XCTAssertEqual(c.activeSelectionLabel, "Gemma 4 E4B")
    }

    // MARK: - 1. begin

    func testBeginBuildsABackendPrimesItAndShowsLoading() {
        h.snapshot = DictionarySnapshot(
            pairs: [ReplacementPair(original: "a", replacement: "b", addedAt: Date(timeIntervalSince1970: 0))],
            glossary: ["Terraform"])
        let c = h.makeController()

        let (_, backend) = beginSwitch(c, to: .gemma4)

        XCTAssertEqual(h.factoryCalls[1].selection, .model(.gemma4))
        // Gemma 4 E4B is fidelity-safe, so the glossary reaches its prompt. The dictionary lands before the load.
        XCTAssertEqual(backend.dictionaries, [h.snapshot])
        XCTAssertEqual(backend.events.first, "setDictionary")
        XCTAssertEqual(c.pendingCleanupModel, "gemma4")
        XCTAssertEqual(c.cleanupModelStatus, "Loading Gemma 4 E4B…")
        XCTAssertNil(c.cleanupModelProgress)
        XCTAssertEqual(c.activeCleanupModel, "gemma3", "nothing commits until the load finishes")
        XCTAssertTrue(c.cleaner === h.backends[0])
    }

    func testBeginGivesANonFidelitySafeModelOnlyThePairs() {
        h.snapshot = DictionarySnapshot(
            pairs: [ReplacementPair(original: "a", replacement: "b", addedAt: Date(timeIntervalSince1970: 0))],
            glossary: ["Terraform"])
        h.settings.cleanupModel = CleanupModelID.gemma4.rawValue
        let c = h.makeController()

        let (_, backend) = beginSwitch(c, to: .gemma3)

        XCTAssertEqual(backend.dictionaries, [DictionarySnapshot(pairs: h.snapshot.pairs, glossary: [])])
    }

    // MARK: - 2. commit

    func testCommitSwapsTheCleanerAndPersistsTheChoice() async {
        let c = h.makeController()
        let previous = h.backends[0]
        let (task, backend) = beginSwitch(c, to: .gemma4)
        h.statuses.value = [.gemma3: .downloaded(bytes: 100), .gemma4: .downloaded(bytes: 200)]

        backend.releasePreload(loaded: true)
        await task.value

        XCTAssertTrue(c.cleaner === backend)
        XCTAssertEqual(c.activeSelection, .model(.gemma4))
        XCTAssertEqual(h.committed.count, 1)
        XCTAssertTrue(h.committed[0].backend === backend)
        XCTAssertEqual(h.committed[0].name, "gemma4")
        XCTAssertEqual(c.activeCleanupModel, "gemma4")
        XCTAssertNil(c.pendingCleanupModel)
        XCTAssertEqual(h.settings.cleanupModel, "gemma4")
        XCTAssertNil(c.cleanupModelStatus)
        XCTAssertNil(c.cleanupModelProgress)
        XCTAssertEqual(previous.unloadCalls, 1)
        XCTAssertEqual(backend.unloadCalls, 0)
        XCTAssertEqual(h.touchIdleCalls, 1)
        XCTAssertTrue(h.logs.value.contains("switched cleanup model to gemma4"))
        // Disk state is re-read off the main actor after a commit.
        let refreshed = await eventually { c.modelStatuses[.gemma4] == .downloaded(bytes: 200) }
        XCTAssertTrue(refreshed)
        XCTAssertEqual(h.statusComputations.value, 2)
    }

    func testCommitUnloadsThePreviousBackendOnlyAfterTheSwap() async {
        let c = h.makeController()
        let previous = h.backends[0]
        let (task, backend) = beginSwitch(c, to: .gemma4)

        backend.releasePreload(loaded: true)
        await task.value

        // The old model must stay usable until the new one is in place: the commit callback saw it still loaded.
        XCTAssertEqual(h.previousUnloadsAtCommit, [0], "the old model is still loaded when the new one reaches the pipeline")
        XCTAssertEqual(previous.events.filter { $0 == "unload" }.count, 1)
        XCTAssertEqual(h.committed.count, 1)
    }

    func testRepeatSelectionOfTheCommittedModelIsIgnoredAfterwards() async {
        let c = h.makeController()
        let (task, backend) = beginSwitch(c, to: .gemma4)
        backend.releasePreload(loaded: true)
        await task.value

        c.switchCleanupModel(to: .gemma4)

        XCTAssertEqual(h.factoryCalls.count, 2)
    }

    // MARK: - 3. failed load

    func testFailedLoadKeepsThePreviousModelAndSaysSo() async {
        let c = h.makeController()
        let previous = h.backends[0]
        let (task, backend) = beginSwitch(c, to: .gemma4)

        backend.releasePreload(loaded: false)
        await task.value

        XCTAssertNil(c.pendingCleanupModel)
        XCTAssertEqual(c.cleanupModelStatus, "Couldn't load Gemma 4 E4B — still using Gemma 3 4B")
        XCTAssertNil(c.cleanupModelProgress)
        XCTAssertTrue(c.cleaner === previous)
        XCTAssertEqual(c.activeCleanupModel, "gemma3")
        XCTAssertEqual(h.committed.count, 0)
        XCTAssertEqual(h.settings.cleanupModel, "gemma3")
        XCTAssertEqual(previous.unloadCalls, 0)
        XCTAssertTrue(h.logs.value.contains("cleanup model switch to gemma4 failed to load"))
        let refreshed = await eventually { h.statusComputations.value == 2 }
        XCTAssertTrue(refreshed)
    }

    func testFailureStatusClearsAfterTheStickyWindow() async {
        h.failureStickySeconds = 0.05
        let c = h.makeController()
        let (task, backend) = beginSwitch(c, to: .gemma4)
        backend.releasePreload(loaded: false)
        await task.value
        XCTAssertNotNil(c.cleanupModelStatus)

        let cleared = await eventually { c.cleanupModelStatus == nil }

        XCTAssertTrue(cleared)
    }

    func testFailureStatusSticksUntilTheWindowEnds() async {
        let c = h.makeController()
        let (task, backend) = beginSwitch(c, to: .gemma4)
        backend.releasePreload(loaded: false)
        await task.value

        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(c.cleanupModelStatus, "Couldn't load Gemma 4 E4B — still using Gemma 3 4B")
    }

    func testANewSwitchReplacesTheFailureAndTheOldWindowDoesNotClearIt() async {
        h.failureStickySeconds = 0.05
        let c = h.makeController()
        let (failed, failedBackend) = beginSwitch(c, to: .gemma4)
        failedBackend.releasePreload(loaded: false)
        await failed.value

        _ = beginSwitch(c, to: .gemma4e2b)
        XCTAssertEqual(c.cleanupModelStatus, "Loading Gemma 4 E2B…")
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(c.cleanupModelStatus, "Loading Gemma 4 E2B…", "the failure's clear must not wipe a newer status")
    }

    // MARK: - Disk preflight

    private let gb: Int64 = 1_000_000_000

    /// `beginSwitch` force-unwraps the switch task, so a refusal would crash the run; this fails an assertion instead.
    private func assertSwitchProceeds(
        _ c: CleanupModelController, to id: CleanupModelID, file: StaticString = #filePath, line: UInt = #line
    ) {
        c.switchCleanupModel(to: id)
        XCTAssertEqual(h.backends.count, 2, "the switch should have built a backend", file: file, line: line)
        XCTAssertEqual(c.pendingCleanupModel, id.rawValue, file: file, line: line)
    }

    func testASwitchTheDiskCannotHoldIsRefusedBeforeAnythingIsBuilt() async {
        h.freeDiskBytes = gb
        h.failureStickySeconds = 0.05
        let c = h.makeController()

        c.switchCleanupModel(to: .gemma4)

        XCTAssertEqual(h.backends.count, 1, "only the init backend: a refused download builds nothing")
        XCTAssertNil(c.cleanupSwitchTask)
        XCTAssertNil(c.pendingCleanupModel)
        XCTAssertEqual(c.activeCleanupModel, "gemma3")
        XCTAssertTrue(c.cleaner === h.backends[0])
        let status = c.cleanupModelStatus ?? ""
        XCTAssertTrue(status.contains("Not enough free disk space"), status)
        XCTAssertTrue(status.contains("Gemma 4 E4B"), status)
        XCTAssertTrue(h.logs.value.contains("cleanup model switch to gemma4 refused: disk"), "\(h.logs.value)")
        let cleared = await eventually { c.cleanupModelStatus == nil }
        XCTAssertTrue(cleared, "the refusal clears after the sticky window like a failed load")
    }

    func testARefusalLeavesAPendingSwitchAlone() {
        let c = h.makeController()
        let (task, _) = beginSwitch(c, to: .gemma4)
        h.freeDiskBytes = gb

        c.switchCleanupModel(to: .gemma4e2b)

        XCTAssertEqual(h.backends.count, 2, "the refused switch builds no backend")
        XCTAssertEqual(c.pendingCleanupModel, "gemma4")
        XCTAssertFalse(task.isCancelled, "a refusal must not cancel the switch already in flight")
        XCTAssertTrue(c.cleanupSwitchTask == task)
    }

    func testAnAlreadyDownloadedModelSwitchesEvenWhenTheDiskIsShort() {
        h.statuses.mutate { $0[.gemma4] = .downloaded(bytes: 100) }
        h.freeDiskBytes = gb
        let c = h.makeController()

        assertSwitchProceeds(c, to: .gemma4)

        XCTAssertEqual(c.cleanupModelStatus, "Loading Gemma 4 E4B…")
    }

    func testASwitchProceedsWhenFreeSpaceIsUnknown() {
        h.freeDiskBytes = nil
        let c = h.makeController()

        assertSwitchProceeds(c, to: .gemma4)
    }

    func testASwitchProceedsWhenTheDiskHasRoom() {
        h.freeDiskBytes = 100 * gb
        let c = h.makeController()

        assertSwitchProceeds(c, to: .gemma4)

        XCTAssertEqual(c.cleanupModelStatus, "Loading Gemma 4 E4B…")
    }

    func testAppleIntelligenceHasNothingToDownloadSoTheDiskIsNeverChecked() {
        h.freeDiskBytes = 0
        let c = h.makeController()

        assertSwitchProceeds(c, to: .appleIntelligence)
    }

    // MARK: - 4. revert

    func testRevertingMidLoadAbandonsTheSwitchAndUnloadsTheOrphan() async {
        let c = h.makeController()
        let previous = h.backends[0]
        let (task, backend) = beginSwitch(c, to: .gemma4)

        c.switchCleanupModel(to: .gemma3)

        XCTAssertNil(c.pendingCleanupModel)
        XCTAssertNil(c.cleanupModelStatus)
        XCTAssertNil(c.cleanupModelProgress)
        XCTAssertNil(c.cleanupSwitchTask)
        XCTAssertEqual(h.factoryCalls.count, 2, "reverting builds nothing")

        backend.releasePreload(loaded: true)
        await task.value

        XCTAssertEqual(backend.unloadCalls, 1)
        XCTAssertEqual(h.committed.count, 0)
        XCTAssertTrue(c.cleaner === previous)
        XCTAssertEqual(previous.unloadCalls, 0)
        XCTAssertEqual(h.settings.cleanupModel, "gemma3")
    }

    func testRevertingStopsLateProgressTicksFromResurrectingTheStatusLine() async {
        let c = h.makeController()
        _ = beginSwitch(c, to: .gemma4)
        c.switchCleanupModel(to: .gemma3)

        h.relay.report(model: "Gemma 4 E4B", fraction: 0.5)
        // The relay hops to the main actor; two yields let that queued hop run before asserting.
        await Task.yield()
        await Task.yield()

        XCTAssertNil(c.cleanupModelStatus)
        XCTAssertNil(c.cleanupModelProgress)
    }

    // MARK: - 5. ignore

    func testSelectingTheActiveModelWithNothingPendingBuildsNothing() {
        let c = h.makeController()

        c.switchCleanupModel(to: .gemma3)

        XCTAssertEqual(h.factoryCalls.count, 1)
        XCTAssertNil(c.pendingCleanupModel)
    }

    func testSelectingThePendingModelBuildsNothing() {
        let c = h.makeController()
        _ = beginSwitch(c, to: .gemma4)

        c.switchCleanupModel(to: .gemma4)

        XCTAssertEqual(h.factoryCalls.count, 2)
        XCTAssertEqual(c.pendingCleanupModel, "gemma4")
    }

    // MARK: - 6. supersede

    func testASupersededLoadIsUnloadedAndNeverCommitted() async {
        let c = h.makeController()
        let (taskB, backendB) = beginSwitch(c, to: .gemma4)
        let (taskC, backendC) = beginSwitch(c, to: .gemma4e2b)

        XCTAssertTrue(taskB.isCancelled)
        XCTAssertEqual(c.pendingCleanupModel, "gemma4e2b")
        XCTAssertEqual(c.cleanupModelStatus, "Loading Gemma 4 E2B…")

        backendB.releasePreload(loaded: true)
        await taskB.value

        XCTAssertEqual(backendB.unloadCalls, 1)
        XCTAssertEqual(h.committed.count, 0)
        XCTAssertEqual(c.pendingCleanupModel, "gemma4e2b", "the cancelled load must not clear the newer switch")
        XCTAssertEqual(c.cleanupModelStatus, "Loading Gemma 4 E2B…")
        // The newer switch still owns the progress line: the cancelled load must not have cleared the in-flight flag.
        h.relay.report(model: "Gemma 4 E2B", fraction: 0.5)
        let stillShown = await eventually { c.cleanupModelProgress == 0.5 }
        XCTAssertTrue(stillShown)

        backendC.releasePreload(loaded: true)
        await taskC.value

        XCTAssertEqual(h.committed.count, 1)
        XCTAssertTrue(h.committed[0].backend === backendC)
        XCTAssertEqual(h.committed[0].name, "gemma4e2b")
        XCTAssertTrue(c.cleaner === backendC)
        XCTAssertEqual(backendC.unloadCalls, 0)
        XCTAssertEqual(h.settings.cleanupModel, "gemma4e2b")
    }

    func testASupersededLoadThatEndsNotLoadedDoesNotClobberTheNewerSwitch() async {
        let c = h.makeController()
        let (taskB, backendB) = beginSwitch(c, to: .gemma4)
        let (taskC, backendC) = beginSwitch(c, to: .gemma4e2b)

        backendB.releasePreload(loaded: false)
        await taskB.value

        XCTAssertEqual(c.pendingCleanupModel, "gemma4e2b")
        XCTAssertEqual(c.cleanupModelStatus, "Loading Gemma 4 E2B…", "no stale failure message from the old load")
        XCTAssertEqual(backendB.unloadCalls, 1)

        backendC.releasePreload(loaded: true)
        await taskC.value
        XCTAssertEqual(c.activeCleanupModel, "gemma4e2b")
    }

    func testASwitchCancelledWhileCheckingIsLoadedStillUnloadsInsteadOfCommitting() async {
        // The second cancellation check: a revert or newer switch can land in the `isLoaded` await,
        // after the first check passed and before the commit.
        let c = h.makeController()
        let (task, backend) = beginSwitch(c, to: .gemma4)
        backend.onIsLoaded = { task.cancel() }

        backend.releasePreload(loaded: true)
        await task.value

        XCTAssertEqual(backend.unloadCalls, 1)
        XCTAssertEqual(h.committed.count, 0)
        XCTAssertEqual(c.activeCleanupModel, "gemma3")
        XCTAssertEqual(h.settings.cleanupModel, "gemma3")
    }

    func testASwitchSupersededWhileCheckingIsLoadedThatEndsNotLoadedDoesNotClobberTheNewerSwitch() async {
        // Same suspension point, failed load: the stale failure must not clear the newer switch's pending model,
        // overwrite its status, or arm a clear over it.
        h.failureStickySeconds = 0.05
        let c = h.makeController()
        let (taskA, backendA) = beginSwitch(c, to: .gemma4)
        backendA.onIsLoaded = { c.switchCleanupModel(to: .gemma4e2b) }

        backendA.releasePreload(loaded: false)
        await taskA.value

        XCTAssertEqual(c.pendingCleanupModel, "gemma4e2b")
        XCTAssertEqual(c.cleanupModelStatus, "Loading Gemma 4 E2B…")
        XCTAssertFalse(h.logs.value.contains("cleanup model switch to gemma4 failed to load"))
        XCTAssertTrue(h.committed.isEmpty)
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(c.cleanupModelStatus, "Loading Gemma 4 E2B…", "no stale failure clear over the newer switch")

        h.backends.last!.releasePreload(loaded: true)
        await c.cleanupSwitchTask?.value
        XCTAssertEqual(c.activeCleanupModel, "gemma4e2b")
    }

    // MARK: - 7. download notification

    func testDownloadProgressDuringASwitchUpdatesStatusAndAnnouncesCompletion() async {
        let c = h.makeController()
        let (task, backend) = beginSwitch(c, to: .gemma4)

        h.relay.report(model: "Gemma 4 E4B", fraction: 0.4)

        let ticked = await eventually { c.cleanupModelProgress == 0.4 }
        XCTAssertTrue(ticked)
        XCTAssertEqual(
            c.cleanupModelStatus, CleanupModelCatalog.statusText(label: "Gemma 4 E4B", fraction: 0.4))

        backend.releasePreload(loaded: true)
        await task.value

        XCTAssertEqual(h.notifications, ["Gemma 4 E4B is ready."])
        XCTAssertNil(c.cleanupModelProgress)
        XCTAssertNil(c.cleanupModelStatus)
    }

    func testCompletionTickAtOneAloneDoesNotAnnounce() async {
        let c = h.makeController()
        let (task, backend) = beginSwitch(c, to: .gemma4)

        h.relay.report(model: "Gemma 4 E4B", fraction: 1)
        let ticked = await eventually { c.cleanupModelStatus == "Loading Gemma 4 E4B…" && c.cleanupModelProgress == 1 }
        XCTAssertTrue(ticked)

        backend.releasePreload(loaded: true)
        await task.value

        XCTAssertEqual(h.notifications, [])
    }

    func testASwitchWithoutADownloadDoesNotAnnounce() async {
        let c = h.makeController()
        let (task, backend) = beginSwitch(c, to: .gemma4)

        backend.releasePreload(loaded: true)
        await task.value

        XCTAssertEqual(h.notifications, [])
    }

    func testTheDownloadFlagResetsForTheNextSwitch() async {
        let c = h.makeController()
        let (first, firstBackend) = beginSwitch(c, to: .gemma4)
        h.relay.report(model: "Gemma 4 E4B", fraction: 0.5)
        _ = await eventually { c.cleanupModelProgress == 0.5 }
        firstBackend.releasePreload(loaded: true)
        await first.value
        XCTAssertEqual(h.notifications, ["Gemma 4 E4B is ready."])

        let (second, secondBackend) = beginSwitch(c, to: .gemma3)
        secondBackend.releasePreload(loaded: true)
        await second.value

        XCTAssertEqual(h.notifications, ["Gemma 4 E4B is ready."], "a switch with no download must stay quiet")
    }

    func testAFailedDownloadDoesNotLeakIntoTheNextSwitchsAnnouncement() async {
        let c = h.makeController()
        let (failed, failedBackend) = beginSwitch(c, to: .gemma4)
        h.relay.report(model: "Gemma 4 E4B", fraction: 0.5)
        let ticked = await eventually { c.cleanupModelProgress == 0.5 }
        XCTAssertTrue(ticked)
        failedBackend.releasePreload(loaded: false)
        await failed.value

        let (next, nextBackend) = beginSwitch(c, to: .gemma4e2b)
        nextBackend.releasePreload(loaded: true)
        await next.value

        XCTAssertEqual(h.notifications, [], "the second switch downloaded nothing")
    }

    func testAProgressTickWithNoLoadInFlightIsIgnored() async {
        let c = h.makeController()

        h.relay.report(model: "Gemma 3 4B", fraction: 0.5)
        // The relay hops to the main actor; two yields let that queued hop run before asserting.
        await Task.yield()
        await Task.yield()

        XCTAssertNil(c.cleanupModelStatus)
        XCTAssertNil(c.cleanupModelProgress)
    }

    // MARK: - 8. Apple Intelligence lost

    private func makeAppleIntelligenceController() -> CleanupModelController {
        h.settings.cleanupModel = CleanupModelID.appleIntelligence.rawValue
        let c = h.makeController()
        h.afmAvailable = false
        h.afmReason = "Apple Intelligence is still downloading"
        return c
    }

    func testLosingAppleIntelligenceNotifiesOnceAndSwitchesToTheFallback() {
        let c = makeAppleIntelligenceController()
        XCTAssertEqual(c.activeCleanupModel, "appleIntelligence")

        c.handleAppleIntelligenceLost()

        XCTAssertFalse(c.appleIntelligenceAvailable)
        XCTAssertEqual(c.appleIntelligenceUnavailableReason, "Apple Intelligence is still downloading")
        XCTAssertEqual(h.notifications, ["Apple Intelligence is unavailable — switching cleanup to Gemma 3 4B…"])
        XCTAssertEqual(h.factoryCalls.count, 2)
        XCTAssertEqual(h.factoryCalls[1].selection, .model(.gemma3))
        XCTAssertEqual(c.pendingCleanupModel, "gemma3")
        XCTAssertTrue(h.logs.value.contains("apple intelligence unavailable — switching cleanup to gemma3"))
    }

    func testASecondLossWhileTheFallbackIsPendingDoesNotNotifyAgain() {
        let c = makeAppleIntelligenceController()
        c.handleAppleIntelligenceLost()

        c.handleAppleIntelligenceLost()

        XCTAssertEqual(h.notifications.count, 1)
        XCTAssertEqual(h.factoryCalls.count, 2)
    }

    func testALossWhileTheFallbackIsPendingStaysQuietEvenIfAvailabilityFlapped() {
        let c = makeAppleIntelligenceController()
        c.handleAppleIntelligenceLost()
        XCTAssertEqual(c.pendingCleanupModel, "gemma3")

        // A flap clears the once-only flag; the in-flight fallback alone must keep the next loss quiet.
        h.afmAvailable = true
        h.afmReason = nil
        c.refreshAppleIntelligenceAvailability()
        h.afmAvailable = false
        h.afmReason = "Apple Intelligence is still downloading"
        c.refreshAppleIntelligenceAvailability()

        XCTAssertEqual(h.notifications.count, 1)
        XCTAssertEqual(h.factoryCalls.count, 2)
    }

    func testAFailedFallbackDoesNotRenotifyOnTheNextAvailabilityRefresh() async {
        let c = makeAppleIntelligenceController()
        c.handleAppleIntelligenceLost()
        let task = c.cleanupSwitchTask!
        h.backends[1].releasePreload(loaded: false)
        await task.value
        XCTAssertNil(c.pendingCleanupModel)
        XCTAssertEqual(c.activeCleanupModel, "appleIntelligence", "the failed fallback leaves AFM active")

        // Every key-down refreshes availability; none of them may retry or re-notify.
        c.refreshAppleIntelligenceAvailability()
        c.refreshAppleIntelligenceAvailability()

        XCTAssertEqual(h.notifications.count, 1)
        XCTAssertEqual(h.factoryCalls.count, 2)
    }

    func testAppleIntelligenceReturningClearsTheFlagSoALaterLossNotifiesAgain() async {
        let c = makeAppleIntelligenceController()
        c.handleAppleIntelligenceLost()
        let task = c.cleanupSwitchTask!
        h.backends[1].releasePreload(loaded: false)
        await task.value

        h.afmAvailable = true
        h.afmReason = nil
        c.refreshAppleIntelligenceAvailability()
        XCTAssertTrue(c.appleIntelligenceAvailable)
        XCTAssertNil(c.appleIntelligenceUnavailableReason)

        h.afmAvailable = false
        h.afmReason = "Apple Intelligence is still downloading"
        c.refreshAppleIntelligenceAvailability()

        XCTAssertEqual(h.notifications.count, 2)
        XCTAssertEqual(h.factoryCalls.count, 3)
    }

    func testTheBackendsLostSignalReachesTheHandler() async {
        let c = makeAppleIntelligenceController()
        _ = c

        h.factoryCalls[0].afmLost()

        let notified = await eventually { !h.notifications.isEmpty }
        XCTAssertTrue(notified)
        XCTAssertEqual(h.factoryCalls.count, 2)
    }

    /// Counts `objectWillChange` emissions, i.e. the menu, Models pane and Dictionary window rebuilds a write causes.
    private func countPublishes(_ controller: CleanupModelController) -> () -> Int {
        var count = 0
        controller.objectWillChange.sink { count += 1 }.store(in: &cancellables)
        return { count }
    }

    func testRefreshingUnchangedAvailabilityPublishesNothing() {
        let c = h.makeController()
        let publishes = countPublishes(c)

        c.refreshAppleIntelligenceAvailability()
        c.refreshAppleIntelligenceAvailability()

        XCTAssertEqual(publishes(), 0, "refresh runs on every key-down")
    }

    func testRefreshingAnUnchangedLossPublishesOnlyTheFirstTime() {
        let c = h.makeController()
        h.afmAvailable = false
        h.afmReason = "Turn on Apple Intelligence in System Settings"
        let publishes = countPublishes(c)

        c.refreshAppleIntelligenceAvailability()
        let afterTheChange = publishes()
        c.refreshAppleIntelligenceAvailability()
        c.refreshAppleIntelligenceAvailability()

        XCTAssertGreaterThan(afterTheChange, 0, "going unavailable is a real change")
        XCTAssertEqual(publishes(), afterTheChange, "repeating it must not rebuild the views again")
        XCTAssertEqual(c.appleIntelligenceUnavailableReason, "Turn on Apple Intelligence in System Settings")
    }

    func testAChangedReasonPublishesAgain() {
        let c = h.makeController()
        h.afmAvailable = false
        h.afmReason = "Apple Intelligence is still downloading"
        c.refreshAppleIntelligenceAvailability()
        let publishes = countPublishes(c)

        h.afmReason = "Turn on Apple Intelligence in System Settings"
        c.refreshAppleIntelligenceAvailability()

        XCTAssertGreaterThan(publishes(), 0)
        XCTAssertEqual(c.appleIntelligenceUnavailableReason, "Turn on Apple Intelligence in System Settings")
    }

    func testLossWhileAGemmaIsActiveOnlyMarksAppleIntelligenceUnavailable() {
        let c = h.makeController()
        h.afmAvailable = false
        h.afmReason = "This Mac doesn't support Apple Intelligence"

        c.refreshAppleIntelligenceAvailability()

        XCTAssertFalse(c.appleIntelligenceAvailable)
        XCTAssertEqual(c.appleIntelligenceUnavailableReason, "This Mac doesn't support Apple Intelligence")
        XCTAssertEqual(h.notifications, [])
        XCTAssertEqual(h.factoryCalls.count, 1)
    }

    // MARK: - 9. Apple Intelligence selection while unavailable

    func testSelectingAppleIntelligenceWhileUnavailableBuildsNothingAndRefreshesAvailability() {
        let c = h.makeController()
        XCTAssertTrue(c.appleIntelligenceAvailable)
        h.afmAvailable = false

        c.switchCleanupModel(to: .appleIntelligence)

        XCTAssertEqual(h.factoryCalls.count, 1)
        XCTAssertFalse(c.appleIntelligenceAvailable)
        XCTAssertNil(c.pendingCleanupModel)
    }

    // MARK: - 10. custom path

    func testSwitchingIsANoOpWhileACustomPathOverridesThePicker() {
        h.settings.cleanupModelPath = "/models/custom"
        let c = h.makeController()

        c.switchCleanupModel(to: .gemma4)

        XCTAssertEqual(h.factoryCalls.count, 1)
        XCTAssertNil(c.pendingCleanupModel)
        XCTAssertEqual(c.activeCleanupModel, "custom")
    }

    // MARK: - 11. delete

    func testDeleteIsRefusedForTheActiveModel() {
        let c = h.makeController()
        XCTAssertNil(c.deleteCleanupModel(.gemma3))
        XCTAssertEqual(h.deletedRepos.value, [])
    }

    func testDeleteIsRefusedForThePendingModel() {
        let c = h.makeController()
        _ = beginSwitch(c, to: .gemma4)
        XCTAssertNil(c.deleteCleanupModel(.gemma4))
        XCTAssertEqual(h.deletedRepos.value, [])
    }

    func testDeleteIsRefusedForAppleIntelligence() {
        let c = h.makeController()
        XCTAssertNil(c.deleteCleanupModel(.appleIntelligence))
        XCTAssertEqual(h.deletedRepos.value, [])
    }

    func testDeleteRemovesTheRepoAndRefreshesStatuses() async {
        let c = h.makeController()
        h.statuses.value = [.gemma3: .downloaded(bytes: 100)]

        let task = c.deleteCleanupModel(.gemma4)
        await task?.value

        XCTAssertNotNil(task)
        XCTAssertEqual(h.deletedRepos.value, ["mlx-community/gemma-4-e4b-it-4bit"])
        XCTAssertTrue(h.logs.value.contains("deleted cleanup model gemma4"))
        let refreshed = await eventually { h.statusComputations.value == 2 }
        XCTAssertTrue(refreshed)
    }

    func testDeleteFailureIsLoggedAndStatusesAreStillRefreshed() async {
        let c = h.makeController()
        h.deleteError.value = TestError(message: "permission denied")

        await c.deleteCleanupModel(.gemma4)?.value

        XCTAssertEqual(h.deletedRepos.value, [])
        XCTAssertTrue(h.logs.value.contains("deleting cleanup model gemma4 failed: permission denied"))
        let refreshed = await eventually { h.statusComputations.value == 2 }
        XCTAssertTrue(refreshed)
    }

    func testRefreshDownloadedModelsPublishesTheFreshStatuses() async {
        let c = h.makeController()
        h.statuses.value = [.gemma4e2b: .downloaded(bytes: 7)]

        await c.refreshDownloadedModels().value

        XCTAssertEqual(c.modelStatuses, [.gemma4e2b: .downloaded(bytes: 7)])
    }

    func testComputeModelStatusesCoversEveryDownloadableModel() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }

        let statuses = CleanupModelController.computeModelStatuses(CleanupModelStore(root: root))

        XCTAssertEqual(Set(statuses.keys), [.gemma3, .gemma4, .gemma4e2b])
        XCTAssertTrue(statuses.values.allSatisfy { $0 == .notDownloaded })
    }

    // MARK: - 12. startup preload

    func testStartupPreloadHoldsTheStatusLineWhileLoadingThenClearsIt() async {
        let c = h.makeController()
        let initial = h.backends[0]
        let load = Task { await c.preloadAtStartup(initial, enabled: true) }
        _ = await eventually { initial.preloadCalls == 1 }

        // A download tick is shown while the startup preload is in flight.
        h.relay.report(model: "Gemma 3 4B", fraction: 0.3)
        let shown = await eventually { c.cleanupModelProgress == 0.3 }
        XCTAssertTrue(shown)
        XCTAssertEqual(c.cleanupModelStatus, "Downloading Gemma 3 4B… 30%")

        initial.releasePreload(loaded: true)
        let loaded = await load.value

        XCTAssertTrue(loaded)
        XCTAssertNil(c.cleanupModelStatus)
        XCTAssertNil(c.cleanupModelProgress)
    }

    func testStartupPreloadReportsAFailedLoadOfTheCurrentCleaner() async {
        let c = h.makeController()
        let initial = h.backends[0]
        let load = Task { await c.preloadAtStartup(initial, enabled: true) }
        _ = await eventually { initial.preloadCalls == 1 }

        initial.releasePreload(loaded: false)

        let loaded = await load.value
        XCTAssertFalse(loaded)
        XCTAssertNil(c.cleanupModelStatus)
    }

    func testStartupPreloadWhenDisabledSucceedsWithoutLoading() async {
        let c = h.makeController()
        h.backends[0].releasePreload()  // a regression must fail the assertion, not hang on the gate

        let loaded = await c.preloadAtStartup(h.backends[0], enabled: false)

        XCTAssertTrue(loaded)
        XCTAssertEqual(h.backends[0].preloadCalls, 0)
    }

    func testStartupPreloadSkipsACleanerThatHasBeenReplaced() async {
        let c = h.makeController()
        let stale = FakeCleanupModelBackend()  // ungated: a regression must fail, not hang

        let loaded = await c.preloadAtStartup(stale, enabled: true)

        XCTAssertTrue(loaded, "superseded is not a failure")
        XCTAssertEqual(stale.preloadCalls, 0, "preloading a replaced cleaner would resurrect an orphan")
    }

    func testStartupPreloadCountsASwitchThatCommittedMidLoadAsSuperseded() async {
        let c = h.makeController()
        let initial = h.backends[0]
        let load = Task { await c.preloadAtStartup(initial, enabled: true) }
        _ = await eventually { initial.preloadCalls == 1 }
        let (task, backend) = beginSwitch(c, to: .gemma4)
        backend.releasePreload(loaded: true)
        await task.value
        XCTAssertEqual(initial.unloadCalls, 1)

        initial.releasePreload()
        let loaded = await load.value

        XCTAssertTrue(loaded, "the commit unloaded the captured cleaner; that is superseded, not failed")
        XCTAssertTrue(c.cleaner === backend)
    }

    func testStartupPreloadLeavesTheStatusLineToAnInFlightUserSwitch() async {
        let c = h.makeController()
        let initial = h.backends[0]
        let load = Task { await c.preloadAtStartup(initial, enabled: true) }
        _ = await eventually { initial.preloadCalls == 1 }
        _ = beginSwitch(c, to: .gemma4)

        initial.releasePreload(loaded: true)
        let loaded = await load.value

        XCTAssertTrue(loaded)
        XCTAssertEqual(c.pendingCleanupModel, "gemma4")
        XCTAssertEqual(c.cleanupModelStatus, "Loading Gemma 4 E4B…", "the switch owns the status line now")
    }

    // MARK: - Key-down warm-up

    func testWarmUpPreloadsAColdCurrentCleaner() async {
        let c = h.makeController()
        let cleaner = h.backends[0]
        cleaner.loaded = false
        let warm = Task { await c.warmUpIfNeeded(cleaner, enabled: true) }
        let started = await eventually { cleaner.preloadCalls == 1 }
        XCTAssertTrue(started)

        cleaner.releasePreload(loaded: true)
        await warm.value
    }

    func testWarmUpLeavesAResidentCleanerAlone() async {
        let c = h.makeController()
        let cleaner = h.backends[0]
        cleaner.loaded = true
        cleaner.releasePreload()  // a regression must fail the assertion, not hang on the gate

        await c.warmUpIfNeeded(cleaner, enabled: true)

        XCTAssertEqual(cleaner.preloadCalls, 0)
    }

    func testWarmUpDoesNothingWhenCleanupIsDisabled() async {
        let c = h.makeController()
        let cleaner = h.backends[0]
        cleaner.releasePreload()  // a regression must fail the assertion, not hang on the gate

        await c.warmUpIfNeeded(cleaner, enabled: false)

        XCTAssertEqual(cleaner.preloadCalls, 0)
    }

    func testWarmUpSkipsACleanerThatASwitchReplaced() async {
        let c = h.makeController()
        let stale = h.backends[0]
        let (task, backend) = beginSwitch(c, to: .gemma4)
        backend.releasePreload(loaded: true)
        await task.value
        stale.releasePreload()  // a regression must fail the assertion, not hang on the gate

        await c.warmUpIfNeeded(stale, enabled: true)

        XCTAssertEqual(stale.preloadCalls, 0, "stale cleaners must not be reloaded after being unloaded")
    }

    // MARK: - Idle unload

    func testUnloadIfResidentUnloadsALoadedCleaner() async {
        let c = h.makeController()
        h.backends[0].loaded = true

        let unloaded = await c.unloadIfResident()

        XCTAssertTrue(unloaded)
        XCTAssertEqual(h.backends[0].unloadCalls, 1)
    }

    func testUnloadIfResidentSkipsAColdCleaner() async {
        let c = h.makeController()

        let unloaded = await c.unloadIfResident()

        XCTAssertFalse(unloaded)
        XCTAssertEqual(h.backends[0].unloadCalls, 0)
    }

    func testUnloadIfResidentSkipsABackendThatHoldsNoMemory() async {
        // Apple Intelligence keeps nothing resident in our process, so idle unload has nothing to reclaim.
        let c = h.makeController()
        h.backends[0].loaded = true
        h.backends[0].holdsMemory = false

        let unloaded = await c.unloadIfResident()

        XCTAssertFalse(unloaded)
        XCTAssertEqual(h.backends[0].unloadCalls, 0)
    }
}
