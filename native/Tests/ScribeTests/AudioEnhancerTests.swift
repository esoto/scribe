import FluidAudio
import XCTest

@MainActor
final class AudioEnhancerTests: XCTestCase {
    private let enhanced = [Float](repeating: 0.5, count: 16000)
    private var logs: Locked<[String]>!
    private var progress: Locked<[Double]>!

    override func setUp() {
        super.setUp()
        logs = Locked([])
        progress = Locked([])
    }

    private func make(_ factory: FakeVqeFactory) -> LocalVQEEnhancer {
        let logs = self.logs!
        let progress = self.progress!
        return LocalVQEEnhancer(
            onDownloadProgress: { fraction in progress.mutate { $0.append(fraction) } },
            onLog: { line in logs.mutate { $0.append(line) } },
            factory: { try await factory.make(progress: $0) })
    }

    func testColdEnhanceReturnsTheInputAndNeverLoads() async throws {
        let factory = FakeVqeFactory()
        let enhancer = make(factory)

        let out = try await enhancer.enhance(VOICED)

        XCTAssertEqual(out, VOICED)
        XCTAssertEqual(factory.calls, 0, "a cold start must not download or compile on the dictation path")
        XCTAssertTrue(factory.vqe.received.isEmpty)
        let loaded = await enhancer.isLoaded
        XCTAssertFalse(loaded)
    }

    func testColdEnhanceLogsOncePerColdStretch() async throws {
        let enhancer = make(FakeVqeFactory())

        _ = try await enhancer.enhance(VOICED)
        _ = try await enhancer.enhance(VOICED)

        XCTAssertEqual(logs.value, ["enhance: model not loaded, raw audio used"])
    }

    func testEnhanceProcessesTheAudioOnceThePreloadFinished() async throws {
        let factory = FakeVqeFactory(vqe: FakeVqe(out: enhanced))
        let enhancer = make(factory)

        await enhancer.preload()
        let out = try await enhancer.enhance(VOICED)

        XCTAssertEqual(out, enhanced)
        XCTAssertEqual(factory.vqe.received, [VOICED])
        XCTAssertEqual(factory.calls, 1)
        let loaded = await enhancer.isLoaded
        XCTAssertTrue(loaded)
        XCTAssertTrue(logs.value.contains { $0.hasPrefix("enhance loaded in") }, "\(logs.value)")
    }

    func testUnloadMakesItColdAgainWithoutReloading() async throws {
        let factory = FakeVqeFactory(vqe: FakeVqe(out: enhanced))
        let enhancer = make(factory)
        await enhancer.preload()

        await enhancer.unload()
        let out = try await enhancer.enhance(VOICED)

        XCTAssertEqual(out, VOICED)
        XCTAssertEqual(factory.calls, 1, "unload must not be followed by a load on the dictation path")
        let loaded = await enhancer.isLoaded
        XCTAssertFalse(loaded)
    }

    func testEachColdStretchLogsItsOwnNotice() async throws {
        let enhancer = make(FakeVqeFactory())
        _ = try await enhancer.enhance(VOICED)
        await enhancer.preload()
        await enhancer.unload()
        _ = try await enhancer.enhance(VOICED)

        XCTAssertEqual(logs.value.filter { $0 == "enhance: model not loaded, raw audio used" }.count, 2)
    }

    func testEnhanceDuringALoadPassesTheAudioThroughInsteadOfWaitingForIt() async throws {
        let factory = FakeVqeFactory(vqe: FakeVqe(out: enhanced), gated: true)
        let enhancer = make(factory)
        let loading = Task { await enhancer.preload() }
        let started = await eventually { factory.calls == 1 }
        XCTAssertTrue(started)

        // Bounded, so a regression fails here instead of hanging the suite on the held load.
        let out: [Float]
        do {
            out = try await withDeadline(2.0) { try await enhancer.enhance(VOICED) }
        } catch {
            factory.release()
            XCTFail("enhance waited on the in-flight load: \(error)")
            return
        }

        XCTAssertEqual(out, VOICED, "a dictation must not wait on a model that is still loading")
        factory.release()
        await loading.value
        let later = try await enhancer.enhance(VOICED)
        XCTAssertEqual(later, enhanced)
    }

    func testAFailedLoadIsNotCachedSoTheNextPreloadRetries() async throws {
        let factory = FakeVqeFactory(vqe: FakeVqe(out: enhanced), failFirst: 1)
        let enhancer = make(factory)

        await enhancer.preload()
        let firstLoaded = await enhancer.isLoaded
        XCTAssertFalse(firstLoaded)
        XCTAssertTrue(logs.value.contains { $0.hasPrefix("enhance preload failed") }, "\(logs.value)")
        let whileCold = try await enhancer.enhance(VOICED)
        XCTAssertEqual(whileCold, VOICED)
        XCTAssertEqual(factory.calls, 1, "enhance must not retry the failed download")

        await enhancer.preload()

        XCTAssertEqual(factory.calls, 2)
        let secondLoaded = await enhancer.isLoaded
        XCTAssertTrue(secondLoaded)
    }

    func testDownloadProgressIsForwardedAndEndsAtOneWhetherTheLoadWorkedOrNot() async {
        await make(FakeVqeFactory()).preload()
        XCTAssertEqual(progress.value, [0.5, 1])

        progress.value = []
        await make(FakeVqeFactory(failFirst: 1)).preload()
        XCTAssertEqual(progress.value, [0.5, 1], "a failed download must still clear the menu's status line")
    }

    func testAProcessingFailurePropagatesSoThePipelineCanFallBack() async {
        let enhancer = make(FakeVqeFactory(vqe: FakeVqe(err: TestError(message: "model blew up"))))
        await enhancer.preload()

        do {
            _ = try await enhancer.enhance(VOICED)
            XCTFail("expected the failure to propagate")
        } catch {
            XCTAssertEqual("\(error)", "model blew up")
        }
    }

    // MARK: - Where the model lives

    func testPinnedRevisionIsACommitSha() {
        let sha = LocalVQEEnhancer.pinnedRevision
        XCTAssertEqual(sha.count, 40)
        XCTAssertTrue(sha.allSatisfy(\.isHexDigit), sha)
    }

    func testPinModelRevisionPointsFluidAudioAtThePinnedCommit() {
        let key = Repo.localVqe.remotePath
        let previous = ModelRegistry.revisionOverrides[key]
        defer { ModelRegistry.revisionOverrides[key] = previous }

        LocalVQEEnhancer.pinModelRevision()

        XCTAssertEqual(ModelRegistry.revisionOverrides[key], LocalVQEEnhancer.pinnedRevision)
    }
}
