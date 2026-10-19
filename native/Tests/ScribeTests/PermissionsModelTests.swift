import Combine
import XCTest

@MainActor
final class PermissionsModelTests: XCTestCase {
    private var probe: FakeTCCProbe!
    private var authorizer: FakeNotificationAuthorizer!
    private var micGranted = 0
    private var inputMonitoringGranted = 0
    private var cancellables: Set<AnyCancellable> = []

    override func setUp() {
        super.setUp()
        probe = FakeTCCProbe()
        authorizer = FakeNotificationAuthorizer()
        micGranted = 0
        inputMonitoringGranted = 0
        cancellables = []
    }

    private func makeModel() -> PermissionsModel {
        PermissionsModel(
            probe: probe,
            notificationAuthorizer: authorizer,
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

    func testInitDoesNotProbeTheInputMonitoringGrantButReadsItsStatus() {
        // The hotkey install result decides the grant at launch; a preflight read would disagree with the real tap.
        // The tri-state only picks the row's buttons, so it is read straight away.
        _ = makeModel()
        XCTAssertFalse(probe.events.contains("probe-inputMonitoring"))
        XCTAssertTrue(probe.events.contains("probe-inputMonitoringStatus"))
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
        probe.microphoneDenied = true
        model.refreshGrants()

        XCTAssertFalse(model.grants.microphone)
        XCTAssertEqual(model.microphoneStatus, .denied)
        // The grant and its tri-state each publish once.
        XCTAssertEqual(publishes(), 2)
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

    // MARK: - Microphone tri-state

    func testInitSeedsTheMicrophoneStatusFromTheProbe() {
        probe.microphoneDenied = true

        XCTAssertEqual(makeModel().microphoneStatus, .denied)
    }

    func testMicrophoneStatusPublishesOnlyOnChange() {
        let model = makeModel()
        let publishes = countPublishes(model)

        model.refreshGrants()
        XCTAssertEqual(publishes(), 0)
        XCTAssertEqual(model.microphoneStatus, .notDetermined)

        // notDetermined → denied leaves the boolean grant false, so only the tri-state publishes.
        probe.microphoneDenied = true
        model.refreshGrants()
        XCTAssertEqual(publishes(), 1)
        XCTAssertEqual(model.microphoneStatus, .denied)

        model.refreshGrants()
        XCTAssertEqual(publishes(), 1)
    }

    func testMicrophoneStatusFollowsTheGrant() {
        let model = makeModel()

        probe.microphone = true
        model.refreshGrants()

        XCTAssertEqual(model.microphoneStatus, .authorized)
    }

    func testDecliningThePromptLeavesTheStatusDenied() async {
        probe.microphoneGrantedByRequest = false
        let model = makeModel()

        await model.request(.microphone)

        XCTAssertEqual(model.microphoneStatus, .denied)
    }

    // MARK: - Input Monitoring tri-state

    func testInputMonitoringStatusSeedsFromTheProbe() {
        probe.inputMonitoringAnswer = .denied

        XCTAssertEqual(makeModel().inputMonitoringStatus, .denied)
    }

    func testInputMonitoringStatusPublishesOnlyOnChange() {
        let model = makeModel()
        let publishes = countPublishes(model)

        model.refreshGrants()
        model.refreshGrants()
        XCTAssertEqual(publishes(), 0)
        XCTAssertEqual(model.inputMonitoringStatus, .notDetermined)

        // Only the tri-state changes here; the boolean grant stays false, so this is the one publish.
        probe.inputMonitoringAnswer = .authorized
        model.refreshGrants()
        XCTAssertEqual(publishes(), 1)
        XCTAssertEqual(model.inputMonitoringStatus, .authorized)

        model.refreshGrants()
        XCTAssertEqual(publishes(), 1)
    }

    // MARK: - Notifications

    func testNotificationsStartUndetermined() {
        XCTAssertEqual(makeModel().notifications, .notDetermined)
    }

    func testRefreshNotificationsPublishesOnlyOnChange() async {
        let model = makeModel()
        let publishes = countPublishes(model)

        await model.refreshNotifications()
        XCTAssertEqual(publishes(), 0)

        authorizer.current = .denied
        await model.refreshNotifications()
        XCTAssertEqual(publishes(), 1)
        XCTAssertEqual(model.notifications, .denied)

        await model.refreshNotifications()
        XCTAssertEqual(publishes(), 1)
    }

    func testRequestNotificationsPromptsThenReadsBackTheAnswer() async {
        authorizer.answerToRequest = .authorized
        let model = makeModel()

        await model.requestNotifications()

        XCTAssertEqual(authorizer.events, ["request", "status"])
        XCTAssertEqual(model.notifications, .authorized)
    }

    func testRequestNotificationsDeclinedPublishesDenied() async {
        authorizer.answerToRequest = .denied
        let model = makeModel()
        let publishes = countPublishes(model)

        await model.requestNotifications()

        XCTAssertEqual(model.notifications, .denied)
        XCTAssertEqual(publishes(), 1)
    }

    func testNotificationsNeverChangeGrantsOk() async {
        probe.microphone = true
        probe.accessibility = true
        probe.inputMonitoring = true
        let model = makeModel()
        model.refreshGrants()
        XCTAssertTrue(model.grantsOk)

        authorizer.current = .denied
        await model.refreshNotifications()

        XCTAssertTrue(model.grantsOk)
        XCTAssertEqual(model.grants, GrantStatus(microphone: true, accessibility: true, inputMonitoring: true))
    }
}
