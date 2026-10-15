import AppKit
import Foundation

/// Test seam over `TCC`: the probes are cheap cached reads, the requests are the only calls that can prompt.
protocol TCCProbing {
    func microphoneGranted() -> Bool
    func accessibilityGranted() -> Bool
    func inputMonitoringGranted() -> Bool
    func requestMicrophone() async -> Bool
    func requestAccessibility()
    func requestInputMonitoring()
}

/// Live conformance. Excluded from unit tests like `TCC` itself: verify manually.
struct LiveTCCProbe: TCCProbing {
    func microphoneGranted() -> Bool { TCC.microphoneGranted() }
    func accessibilityGranted() -> Bool { TCC.accessibilityGranted() }
    func inputMonitoringGranted() -> Bool { TCC.inputMonitoringGranted() }
    func requestMicrophone() async -> Bool { await TCC.requestMicrophone() }
    func requestAccessibility() { TCC.requestAccessibility() }
    func requestInputMonitoring() { TCC.requestInputMonitoring() }
}

/// The three TCC grants as the menu bar and Setup window see them. A false→true flip of the microphone or
/// Input Monitoring is reported through the init closures, so the owner reacts without a restart.
@MainActor
final class PermissionsModel: ObservableObject {
    @Published private(set) var grants: GrantStatus

    var grantsOk: Bool { grants.microphone && grants.accessibility && grants.inputMonitoring }

    private let probe: TCCProbing
    private let onMicrophoneGranted: () -> Void
    private let onInputMonitoringGranted: () -> Void

    init(
        probe: TCCProbing,
        onMicrophoneGranted: @escaping () -> Void,
        onInputMonitoringGranted: @escaping () -> Void
    ) {
        self.probe = probe
        self.onMicrophoneGranted = onMicrophoneGranted
        self.onInputMonitoringGranted = onInputMonitoringGranted
        // Cached TCC reads (no prompt), seeded early so the launch auto-open decision is correct.
        // Input Monitoring is left to the hotkey install result (`setInputMonitoring`).
        grants = GrantStatus(
            microphone: probe.microphoneGranted(), accessibility: probe.accessibilityGranted(),
            inputMonitoring: false)
    }

    /// Re-reads all probes. A false→true flip on mic or Input Monitoring reacts without a restart.
    func refreshGrants() {
        let fresh = GrantStatus(
            microphone: probe.microphoneGranted(),
            accessibility: probe.accessibilityGranted(),
            inputMonitoring: probe.inputMonitoringGranted())
        let change = GrantChange(from: grants, to: fresh)

        // Publish only on change: each write rebuilds the menu bar and closes any open submenu.
        if change.publish {
            grants = fresh
        }
        if change.microphoneNewlyGranted {
            onMicrophoneGranted()
        }
        if change.inputMonitoringNewlyGranted {
            // The owner reinstalls the tap and reports the outcome back through `setInputMonitoring`.
            onInputMonitoringGranted()
        }
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
