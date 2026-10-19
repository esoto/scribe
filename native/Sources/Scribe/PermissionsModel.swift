import AppKit
import Foundation
import UserNotifications

/// Test seam over `TCC`: the probes are cheap cached reads, the requests are the only calls that can prompt.
protocol TCCProbing {
    func microphoneGranted() -> Bool
    func microphoneStatus() -> TCCStatus
    func accessibilityGranted() -> Bool
    func inputMonitoringGranted() -> Bool
    func inputMonitoringStatus() -> TCCStatus
    func requestMicrophone() async -> Bool
    func requestAccessibility()
    func requestInputMonitoring()
}

/// Live conformance. Excluded from unit tests like `TCC` itself: verify manually.
struct LiveTCCProbe: TCCProbing {
    func microphoneGranted() -> Bool { TCC.microphoneGranted() }
    func microphoneStatus() -> TCCStatus { TCC.microphoneStatus() }
    func accessibilityGranted() -> Bool { TCC.accessibilityGranted() }
    func inputMonitoringGranted() -> Bool { TCC.inputMonitoringGranted() }
    func inputMonitoringStatus() -> TCCStatus { TCC.inputMonitoringStatus() }
    func requestMicrophone() async -> Bool { await TCC.requestMicrophone() }
    func requestAccessibility() { TCC.requestAccessibility() }
    func requestInputMonitoring() { TCC.requestInputMonitoring() }
}

/// Test seam over `UNUserNotificationCenter`. Notifications are not a TCC grant: scribe works without them,
/// so they are never part of `grantsOk`.
protocol NotificationAuthorizing {
    func status() async -> NotificationAuthorization
    /// Shows the system prompt the first time; returns whether notifications are now allowed.
    func request() async -> Bool
}

/// Live conformance. Excluded from unit tests: the notification center needs a real app bundle.
struct LiveNotificationAuthorizer: NotificationAuthorizing {
    let log: @Sendable (String) -> Void

    func status() async -> NotificationAuthorization {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        default: return .authorized
        }
    }

    func request() async -> Bool {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            if !granted { log("notification authorization denied") }
            return granted
        } catch {
            log("notification authorization failed: \(error)")
            return false
        }
    }
}

/// The three TCC grants, plus the optional notification authorization, as the menu bar and Setup window see them. A false→true flip of the microphone or
/// Input Monitoring is reported through the init closures, so the owner reacts without a restart.
@MainActor
final class PermissionsModel: ObservableObject {
    @Published private(set) var grants: GrantStatus
    /// Microphone alone distinguishes "never asked" from "refused"; only the first can still show a prompt.
    @Published private(set) var microphoneStatus: TCCStatus
    /// Drives the Input Monitoring row's buttons only; the grant itself is the hotkey tap's install result.
    @Published private(set) var inputMonitoringStatus: TCCStatus
    @Published private(set) var notifications: NotificationAuthorization = .notDetermined

    var grantsOk: Bool { grants.microphone && grants.accessibility && grants.inputMonitoring }

    private let probe: TCCProbing
    private let notificationAuthorizer: NotificationAuthorizing
    private let onMicrophoneGranted: () -> Void
    private let onInputMonitoringGranted: () -> Void

    init(
        probe: TCCProbing,
        notificationAuthorizer: NotificationAuthorizing,
        onMicrophoneGranted: @escaping () -> Void,
        onInputMonitoringGranted: @escaping () -> Void
    ) {
        self.probe = probe
        self.notificationAuthorizer = notificationAuthorizer
        self.onMicrophoneGranted = onMicrophoneGranted
        self.onInputMonitoringGranted = onInputMonitoringGranted
        // Cached TCC reads (no prompt), seeded early so the launch auto-open decision is correct.
        // Input Monitoring is left to the hotkey install result (`setInputMonitoring`).
        grants = GrantStatus(
            microphone: probe.microphoneGranted(), accessibility: probe.accessibilityGranted(),
            inputMonitoring: false)
        microphoneStatus = probe.microphoneStatus()
        inputMonitoringStatus = probe.inputMonitoringStatus()
    }

    /// Re-reads all probes. A false→true flip on mic or Input Monitoring reacts without a restart.
    func refreshGrants() {
        let fresh = GrantStatus(
            microphone: probe.microphoneGranted(),
            accessibility: probe.accessibilityGranted(),
            inputMonitoring: probe.inputMonitoringGranted())
        let change = GrantChange(from: grants, to: fresh)
        let freshMicrophoneStatus = probe.microphoneStatus()
        let freshInputMonitoringStatus = probe.inputMonitoringStatus()

        // Publish only on change: each write rebuilds the menu bar and closes any open submenu.
        if change.publish {
            grants = fresh
        }
        if freshMicrophoneStatus != microphoneStatus {
            microphoneStatus = freshMicrophoneStatus
        }
        if freshInputMonitoringStatus != inputMonitoringStatus {
            inputMonitoringStatus = freshInputMonitoringStatus
        }
        if change.microphoneNewlyGranted {
            onMicrophoneGranted()
        }
        if change.inputMonitoringNewlyGranted {
            // The owner reinstalls the tap and reports the outcome back through `setInputMonitoring`.
            onInputMonitoringGranted()
        }
    }

    /// Async, so it is not part of `refreshGrants`; the Setup window's poll loop is the only caller that needs it.
    func refreshNotifications() async {
        let fresh = await notificationAuthorizer.status()
        if fresh != notifications {
            notifications = fresh
        }
    }

    /// Shows the system prompt (a no-op once the user has answered), then re-reads what the system decided.
    func requestNotifications() async {
        _ = await notificationAuthorizer.request()
        await refreshNotifications()
    }

    /// The hotkey tap install result is the real Input Monitoring answer; the preflight probe can disagree.
    func setInputMonitoring(_ granted: Bool) {
        guard grants.inputMonitoring != granted else { return }
        grants.inputMonitoring = granted
    }

    /// Shows the system prompt (or adds scribe to the pane, unchecked). Microphone re-probes once it resolves;
    /// the other two are noticed by the poll loop and the foreground refresh.
    func request(_ grant: Grant) async {
        switch grant {
        case .microphone:
            _ = await probe.requestMicrophone()
            refreshGrants()
        case .accessibility:
            probe.requestAccessibility()
        case .inputMonitoring:
            probe.requestInputMonitoring()
        }
    }

    /// Grants change in System Settings, which scribe can't observe, so re-probe on a timer and on return to the app.
    /// Without this a revoked permission only shows while the Setup window is open.
    func startWatching() {
        // Seeded once so the Setup window never shows Request for a frame to a user who already allowed notifications.
        Task { [weak self] in await self?.refreshNotifications() }
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled, let self else { return }
                self.refreshGrants()
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshGrants() }
        }
    }
}
