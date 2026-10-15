import ApplicationServices
import AVFoundation
import AppKit
import CoreGraphics
import SwiftUI

/// Thin TCC wrappers; excluded from unit tests. Verify manually. The logic consuming them is in `OnboardingState`.
enum TCC {
    static func microphoneGranted() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
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

/// First-run and Doctor permission window. Polls `TCC` every 2 s while open.
struct OnboardingWindow: View {
    @ObservedObject var model: AppModel
    @State private var testText: String = ""

    private var highlighted: Grant? {
        if case .request(let grant) = OnboardingState.nextStep(model.grants) {
            return grant
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("scribe setup")
                .font(.title2)
                .bold()

            VStack(spacing: 8) {
                row(
                    .microphone,
                    title: "Microphone",
                    detail: "Needed to hear you while you hold the dictation key.",
                    systemImage: "mic.fill"
                )
                row(
                    .accessibility,
                    title: "Accessibility",
                    detail: "Needed to paste transcribed text into the focused app.",
                    systemImage: "accessibility"
                )
                row(
                    .inputMonitoring,
                    title: "Input Monitoring",
                    detail: "Needed to detect the hold-to-talk key.",
                    systemImage: "keyboard"
                )
            }

            if model.grantsOk {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("Hold \(model.settings.hotkey.displayName) and speak")
                        .font(.headline)
                    TextField("Try dictating here…", text: $testText)
                        .textFieldStyle(.roundedBorder)
                }
            }

            Divider()
            HStack {
                Text(OnboardingState.summary(model.grants))
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
        // LSUIElement has no ⌘Tab entry, so promote to a regular app while this window is open.
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
        .onDisappear {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    @ViewBuilder
    private func row(_ grant: Grant, title: String, detail: String, systemImage: String) -> some View {
        let granted = isGranted(grant)
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(granted ? .green : .red)
                .imageScale(.large)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: systemImage)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text(title)
                        .font(.headline)
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if !granted {
                Button("Request") { request(grant) }
                Button("Open Settings") { openSettings(grant) }
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(highlighted == grant ? Color.accentColor.opacity(0.12) : Color.clear)
        )
    }

    private func isGranted(_ grant: Grant) -> Bool {
        switch grant {
        case .microphone: return model.grants.microphone
        case .accessibility: return model.grants.accessibility
        case .inputMonitoring: return model.grants.inputMonitoring
        }
    }

    private func request(_ grant: Grant) {
        switch grant {
        case .microphone:
            Task {
                _ = await TCC.requestMicrophone()
                refreshGrants()
            }
        case .accessibility:
            TCC.requestAccessibility()
        case .inputMonitoring:
            TCC.requestInputMonitoring()
        }
    }

    private func openSettings(_ grant: Grant) {
        NSWorkspace.shared.open(OnboardingState.settingsUrl(for: grant))
    }

    /// SwiftUI cancels the `.task` when the window closes, which stops this loop.
    private func pollLoop() async {
        while !Task.isCancelled {
            refreshGrants()
            // Stays at 2 s even when all green, so revocations are still noticed.
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    /// Re-reads all probes. A false→true flip on mic or Input Monitoring calls into `AppModel` to react without a restart.
    private func refreshGrants() {
        let fresh = GrantStatus(
            microphone: TCC.microphoneGranted(),
            accessibility: TCC.accessibilityGranted(),
            inputMonitoring: TCC.inputMonitoringGranted())

        let microphoneNewlyGranted = fresh.microphone && !model.grants.microphone
        let inputMonitoringNewlyGranted = fresh.inputMonitoring && !model.grants.inputMonitoring

        // Publish only on change: each write rebuilds the menu bar and closes any open submenu.
        if fresh != model.grants {
            model.grants = fresh
        }
        if microphoneNewlyGranted {
            model.prewarmRecorderIfGranted()
        }
        if inputMonitoringNewlyGranted {
            // Reinstalls the tap; on failure it flips
            // grants.inputMonitoring back to false itself.
            model.activateHotkeyIfNeeded()
        }
    }
}
