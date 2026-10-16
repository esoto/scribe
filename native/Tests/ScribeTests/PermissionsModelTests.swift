import Combine
import XCTest

@MainActor
final class PermissionsModelTests: XCTestCase {
    private var probe: FakeTCCProbe!
    private var micGranted = 0
    private var inputMonitoringGranted = 0
    private var cancellables: Set<AnyCancellable> = []

    override func setUp() {
        super.setUp()
        probe = FakeTCCProbe()
        micGranted = 0
        inputMonitoringGranted = 0
        cancellables = []
    }

    private func makeModel() -> PermissionsModel {
        PermissionsModel(
            probe: probe,
            onMicrophoneGranted: { [unowned self] in micGranted += 1 },
            onInputMonitoringGranted: { [unowned self] in inputMonitoringGranted += 1 })
    }

    /// Counts `objectWillChange` emissions, i.e. the menu-bar rebuilds a write would cause.
    private func countPublishes(_ model: PermissionsModel) -> () -> Int {
        var count = 0
        model.objectWillChange.sink { count += 1 }.store(in: &cancellables)
        return { count }
    }

    // MARK: - Seeding

    func testInitSeedsMicrophoneAndAccessibilityFromTheProbes() {
        probe.microphone = true
        probe.accessibility = true
        probe.inputMonitoring = true

        let model = makeModel()

        XCTAssertEqual(
            model.grants, GrantStatus(microphone: true, accessibility: true, inputMonitoring: false))
    }

    func testInitDoesNotProbeInputMonitoring() {
        // The hotkey install result decides it at launch; a preflight read would disagree with the real tap.
        _ = makeModel()
        XCTAssertFalse(probe.events.contains("probe-inputMonitoring"))
    }

    func testInitDoesNotFireReactions() {
        probe.microphone = true
        _ = makeModel()
        XCTAssertEqual(micGranted, 0)
        XCTAssertEqual(inputMonitoringGranted, 0)
    }

    // MARK: - grantsOk

    func testGrantsOkNeedsAllThree() {
        let model = makeModel()
        XCTAssertFalse(model.grantsOk)

        probe.microphone = true
        probe.accessibility = true
        model.refreshGrants()
        XCTAssertFalse(model.grantsOk)

        probe.inputMonitoring = true
        model.refreshGrants()
        XCTAssertTrue(model.grantsOk)
    }

    // MARK: - refreshGrants reactions

    func testMicrophoneFlipToGrantedFiresTheReactionOnce() {
        let model = makeModel()

        probe.microphone = true
        model.refreshGrants()
        model.refreshGrants()

        XCTAssertEqual(micGranted, 1)
        XCTAssertEqual(inputMonitoringGranted, 0)
        XCTAssertTrue(model.grants.microphone)
    }

    func testInputMonitoringFlipToGrantedFiresTheReactionOnce() {
        let model = makeModel()

        probe.inputMonitoring = true
        model.refreshGrants()
        model.refreshGrants()

        XCTAssertEqual(inputMonitoringGranted, 1)
        XCTAssertEqual(micGranted, 0)
        XCTAssertTrue(model.grants.inputMonitoring)
    }

    func testAccessibilityFlipHasNoReaction() {
        let model = makeModel()

        probe.accessibility = true
        model.refreshGrants()

        XCTAssertTrue(model.grants.accessibility)
        XCTAssertEqual(micGranted, 0)
        XCTAssertEqual(inputMonitoringGranted, 0)
    }

    func testRevocationPublishesButFiresNoReaction() {
        probe.microphone = true
        let model = makeModel()
        let publishes = countPublishes(model)

        probe.microphone = false
        model.refreshGrants()

        XCTAssertFalse(model.grants.microphone)
        XCTAssertEqual(publishes(), 1)
        XCTAssertEqual(micGranted, 0)
    }

    func testReGrantAfterRevocationFiresTheReactionAgain() {
        let model = makeModel()
        probe.microphone = true
        model.refreshGrants()
        probe.microphone = false
        model.refreshGrants()
        probe.microphone = true
        model.refreshGrants()

        XCTAssertEqual(micGranted, 2)
    }

    // MARK: - Publish only on change

    func testRefreshPublishesOnlyOnARealChange() {
        let model = makeModel()
        let publishes = countPublishes(model)

        model.refreshGrants()
        XCTAssertEqual(publishes(), 0)

        probe.accessibility = true
        model.refreshGrants()
        XCTAssertEqual(publishes(), 1)

        model.refreshGrants()
        XCTAssertEqual(publishes(), 1)
    }

    func testSetInputMonitoringPublishesOnlyOnChange() {
        let model = makeModel()
        let publishes = countPublishes(model)

        model.setInputMonitoring(false)
        XCTAssertEqual(publishes(), 0)

        model.setInputMonitoring(true)
        XCTAssertEqual(publishes(), 1)
        XCTAssertTrue(model.grants.inputMonitoring)

        model.setInputMonitoring(true)
        XCTAssertEqual(publishes(), 1)

        model.setInputMonitoring(false)
        XCTAssertEqual(publishes(), 2)
        XCTAssertFalse(model.grants.inputMonitoring)
    }

    func testSetInputMonitoringDoesNotFireReactions() {
        // The coordinator reports through this after a tap install; reacting would loop back into reinstall.
        let model = makeModel()
        model.setInputMonitoring(true)
        XCTAssertEqual(inputMonitoringGranted, 0)
    }

    // MARK: - request

    func testRequestMicrophoneAwaitsThePromptThenReprobes() async {
        probe.microphoneGrantedByRequest = true
        let model = makeModel()
        probe.resetEvents()

        await model.request(.microphone)

        XCTAssertEqual(probe.events.first, "request-microphone")
        XCTAssertTrue(probe.events.contains("probe-microphone"))
        XCTAssertTrue(model.grants.microphone)
        XCTAssertEqual(micGranted, 1)
    }

    func testRequestMicrophoneDeniedLeavesTheGrantOff() async {
        probe.microphoneGrantedByRequest = false
        let model = makeModel()

        await model.request(.microphone)

        XCTAssertFalse(model.grants.microphone)
        XCTAssertEqual(micGranted, 0)
    }

    func testRequestAccessibilityOnlyAsksTheProbe() async {
        let model = makeModel()
        probe.resetEvents()

        await model.request(.accessibility)

        XCTAssertEqual(probe.events, ["request-accessibility"])
    }

    func testRequestInputMonitoringOnlyAsksTheProbe() async {
        let model = makeModel()
        probe.resetEvents()

        await model.request(.inputMonitoring)

        XCTAssertEqual(probe.events, ["request-inputMonitoring"])
    }
}
