import XCTest

@MainActor
final class EnhanceAudioLifecycleTests: XCTestCase {
    private func make(_ factory: FakeVqeFactory, enabled: Bool) -> (EnhanceAudioLifecycle, LocalVQEEnhancer) {
        let enhancer = LocalVQEEnhancer(factory: { try await factory.make(progress: $0) })
        return (EnhanceAudioLifecycle(enhancer: enhancer, enabled: enabled), enhancer)
    }

    func testWarmUpWhileOffNeverLoads() async {
        let factory = FakeVqeFactory()
        let (lifecycle, _) = make(factory, enabled: false)
        await lifecycle.warmUp().value
        XCTAssertEqual(factory.calls, 0)
    }

    func testToggleOnLoadsAndToggleOffUnloads() async {
        let (lifecycle, enhancer) = make(FakeVqeFactory(), enabled: false)
        await lifecycle.setEnabled(true).value
        let on = await enhancer.isLoaded
        XCTAssertTrue(on)
        await lifecycle.setEnabled(false).value
        let off = await enhancer.isLoaded
        XCTAssertFalse(off)
    }

    func testALoadThatLandsAfterAToggleOffIsUndone() async {
        let factory = FakeVqeFactory(gated: true)
        let (lifecycle, enhancer) = make(factory, enabled: true)
        let warming = lifecycle.warmUp()
        let started = await eventually { factory.calls == 1 }
        XCTAssertTrue(started)
        await lifecycle.setEnabled(false).value
        factory.release()
        await warming.value
        let loaded = await enhancer.isLoaded
        XCTAssertFalse(loaded)
    }

    func testIdleUnloadReportsOnlyAResidentModel() async {
        let (lifecycle, _) = make(FakeVqeFactory(), enabled: true)
        let cold = await lifecycle.unloadIfResident()
        XCTAssertFalse(cold)
        await lifecycle.warmUp().value
        let warm = await lifecycle.unloadIfResident()
        XCTAssertTrue(warm)
    }
}
