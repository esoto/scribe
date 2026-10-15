import ApplicationServices
import AVFoundation
import AppKit
import CoreGraphics
import SwiftUI

/// Thin TCC wrappers; excluded from unit tests. Verify manually. The logic consuming them is in `OnboardingState` and `PermissionsModel`.
enum TCC {
    static func microphoneGranted() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// Restricted (parental controls, MDM) can't be prompted for either, so it reads as denied.
    static func microphoneStatus() -> TCCStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined: return .notDetermined
        case .authorized: return .authorized
        default: return .denied
        }
    }

    /// Returns without a dialog once the user has already decided.
    static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    static func accessibilityGranted() -> Bool {
        AXIsProcessTrusted()
    }

    /// Adds scribe to the Accessibility list, unchecked.
    static func requestAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)
    }

    static func inputMonitoringGranted() -> Bool {
        CGPreflightListenEventAccess()
    }

    /// Adds scribe to the Input Monitoring list, unchecked.
    static func requestInputMonitoring() {
        CGRequestListenEventAccess()
    }
}

/// First-run and Doctor window: the three TCC grants, the models, and the optional notifications row.
/// Polls the probes every 2 s while open.
struct OnboardingWindow: View {
    @ObservedObject var permissions: PermissionsModel
    /// Read for `sttDownloadStatus` only.
    @ObservedObject var model: AppModel
    @ObservedObject var cleanupModels: CleanupModelController
    @ObservedObject var settingsModel: SettingsModel
    @State private var testText: String = ""
    @FocusState private var testFieldFocused: Bool

    private var highlighted: Grant? {
        if case .request(let grant) = OnboardingState.nextStep(permissions.grants) {
            return grant
        }
        return nil
    }

    private var models: (detail: String, ready: Bool) {
        OnboardingState.modelsRow(
            sttDownload: model.sttDownloadStatus, cleanupStatus: cleanupModels.cleanupModelStatus)
    }

    /// Dictating into the field needs the grants and loaded models; before that it would only fail.
    private var testFieldVisible: Bool { permissions.grantsOk && models.ready }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("scribe setup")
                .font(.title2)
                .bold()

            VStack(spacing: 8) {
                permissionRow(
                    .microphone,
                    detail: "Needed to hear you while you hold the dictation key.",
                    systemImage: "mic.fill"
                )
                permissionRow(
                    .accessibility,
                    detail: "Needed to paste transcribed text into the focused app.",
                    systemImage: "accessibility"
                )
                permissionRow(
                    .inputMonitoring,
                    detail: "Needed to detect the hold-to-talk key.",
                    systemImage: "keyboard"
                )
                modelsRow
                notificationsRow
            }

            if testFieldVisible {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("Hold \(settingsModel.hotkey.displayName) and speak")
                        .font(.headline)
                    TextField("Try dictating here…", text: $testText)
                        .textFieldStyle(.roundedBorder)
                        .focused($testFieldFocused)
                }
            }

            Divider()
            HStack {
                // Notifications are optional, so they stay out of this count.
                Text(OnboardingState.summary(permissions.grants))
                    .foregroundStyle(.secondary)
                Spacer()
                // "Error — check log" names this file; this is the one place in the app that opens it.
                Button("Show Log in Finder") {
                    if FileManager.default.fileExists(atPath: FileLogger.logFileURL.path) {
                        NSWorkspace.shared.activateFileViewerSelecting([FileLogger.logFileURL])
                    } else {
                        // Deleted and not yet recreated by the next write: show the folder instead of doing nothing.
                        NSWorkspace.shared.open(FileLogger.logsDirectory)
                    }
                }
            }
        }
        .padding(24)
        .frame(width: 420)
        .task {
            await pollLoop()
        }
        .onAppear {
            WindowActivation.shared.windowAppeared()
            NSApp.activate(ignoringOtherApps: true)
        }
        .onDisappear { WindowActivation.shared.windowDisappeared() }
        // The field either exists at open or appears once the last step finishes; focus it either way.
        .onAppear { testFieldFocused = true }
        .onChange(of: testFieldVisible) { _, visible in
            if visible { testFieldFocused = true }
        }
    }

    // MARK: - Rows

    private enum RowIndicator {
        case granted, missing, working
    }

    private func permissionRow(_ grant: Grant, detail: String, systemImage: String) -> some View {
        let granted = isGranted(grant)
        return row(
            title: OnboardingState.title(grant),
            detail: detail,
            systemImage: systemImage,
            indicator: granted ? .granted : .missing,
            value: granted ? "granted" : "not granted",
            isNextStep: highlighted == grant,
            actions: OnboardingState.actions(
                for: grant, granted: granted,
                microphoneStatus: grant == .microphone ? permissions.microphoneStatus : nil),
            voiceOverLabel: { OnboardingState.accessibilityLabel($0, for: grant) },
            perform: { action in
                switch action {
                case .request: Task { await permissions.request(grant) }
                case .openSystemSettings: NSWorkspace.shared.open(OnboardingState.settingsUrl(for: grant))
                }
            })
    }

    private var modelsRow: some View {
        row(
            title: "Models",
            detail: models.detail,
            systemImage: "arrow.down.circle",
            indicator: models.ready ? .granted : .working,
            value: models.ready ? "ready" : "loading",
            isNextStep: false)
    }

    private var notificationsRow: some View {
        let authorized = permissions.notifications == .authorized
        return row(
            title: "Notifications",
            detail: OnboardingState.notificationsDetail(permissions.notifications),
            systemImage: "bell",
            indicator: authorized ? .granted : .missing,
            value: authorized ? "granted" : "not granted",
            isNextStep: false,
            actions: OnboardingState.notificationsActions(permissions.notifications),
            voiceOverLabel: OnboardingState.notificationsAccessibilityLabel,
            perform: { action in
                switch action {
                case .request: Task { await permissions.requestNotifications() }
                case .openSystemSettings: NSWorkspace.shared.open(OnboardingState.notificationsSettingsUrl)
                }
            })
    }

    @ViewBuilder
    private func row(
        title: String,
        detail: String,
        systemImage: String,
        indicator: RowIndicator,
        value: String,
        isNextStep: Bool,
        actions: [PermissionAction] = [],
        voiceOverLabel: @escaping (PermissionAction) -> String = { _ in "" },
        perform: @escaping (PermissionAction) -> Void = { _ in }
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            indicatorView(indicator)
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 8) {
                // Combined so VoiceOver reads one "Microphone, needed to …, not granted" element. The buttons stay
                // outside it: inside, they would fold into the label and stop being focusable.
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Image(systemName: systemImage)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text(title)
                            .font(.headline)
                    }
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityValue(value)

                if !actions.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(Array(actions.enumerated()), id: \.element) { index, action in
                            actionButton(
                                action, prominent: isNextStep && index == 0,
                                voiceOverLabel: voiceOverLabel(action), perform: perform)
                        }
                    }
                }
            }

            Spacer()
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isNextStep ? Color.accentColor.opacity(0.12) : Color.clear)
        )
    }

    @ViewBuilder
    private func indicatorView(_ indicator: RowIndicator) -> some View {
        switch indicator {
        case .granted:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).imageScale(.large)
        case .missing:
            Image(systemName: "xmark.circle").foregroundStyle(.red).imageScale(.large)
        case .working:
            ProgressView().controlSize(.small)
        }
    }

    /// The step the user should take next stands out; a second route on the same row stays secondary.
    @ViewBuilder
    private func actionButton(
        _ action: PermissionAction, prominent: Bool, voiceOverLabel: String,
        perform: @escaping (PermissionAction) -> Void
    ) -> some View {
        let button = Button(OnboardingState.buttonTitle(action)) { perform(action) }
            .accessibilityLabel(voiceOverLabel)
        if prominent {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }

    private func isGranted(_ grant: Grant) -> Bool {
        switch grant {
        case .microphone: return permissions.grants.microphone
        case .accessibility: return permissions.grants.accessibility
        case .inputMonitoring: return permissions.grants.inputMonitoring
        }
    }

    /// SwiftUI cancels the `.task` when the window closes, which stops this loop.
    private func pollLoop() async {
        while !Task.isCancelled {
            permissions.refreshGrants()
            await permissions.refreshNotifications()
            // Stays at 2 s even when all green, so revocations are still noticed.
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }
}
