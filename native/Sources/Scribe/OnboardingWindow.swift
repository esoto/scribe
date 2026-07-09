import ApplicationServices
import AVFoundation
import AppKit
import CoreGraphics
import SwiftUI

/// OS adapter for the three TCC (Transparency, Consent, and Control)
/// permissions scribe needs. Thin wrappers over macOS system APIs that
/// require live user-consent dialogs and a real TCC database — excluded
/// from unit test coverage for that reason. The pure decision logic that
/// consumes their results (`OnboardingState`) is fully unit-tested in
/// OnboardingStateTests.swift; verify this adapter manually via the app.
enum TCC {
    /// Reads the cached microphone authorization status. Does not prompt.
    static func microphoneGranted() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// Shows the system microphone-access prompt if the user hasn't
    /// decided yet; returns immediately (no dialog) once already decided.
    static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// Reads whether this process is trusted for accessibility. Does not prompt.
    static func accessibilityGranted() -> Bool {
        AXIsProcessTrusted()
    }

    /// Shows the system accessibility-trust prompt, which adds scribe
    /// (unchecked) to System Settings > Privacy & Security > Accessibility.
    static func requestAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)
    }

    /// Reads whether this process can listen to CGEvents. Does not prompt.
    static func inputMonitoringGranted() -> Bool {
        CGPreflightListenEventAccess()
    }

    /// Shows the system Input Monitoring prompt, which adds scribe
    /// (unchecked) to System Settings > Privacy & Security > Input Monitoring.
    static func requestInputMonitoring() {
        CGRequestListenEventAccess()
    }
}

/// Native first-run/"Doctor" permission window — reachable from the menu
/// bar item at any time, and auto-opened at launch while any permission is
/// missing (see `ScribeApp`). Three rows (microphone, accessibility, input
/// monitoring) show live ✓/✗ status polled from `TCC` every 2 s, each with
/// a "Request" and an "Open Settings" button. Once all three are granted,
/// the rows give way to a live "try it" test field.
struct OnboardingWindow: View {
    @ObservedObject var model: AppModel
    @State private var testText: String = ""

    /// The row to highlight — the next permission `OnboardingState` would
    /// have the user address, or nil once everything is granted.
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
            Text(OnboardingState.summary(model.grants))
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 420)
        .task {
            await pollLoop()
        }
        // scribe is a menu-bar app (LSUIElement) with no Dock icon or
        // ⌘Tab entry — correct while idle, but it makes an open setup
        // window unreachable once it's buried behind other apps. Promote
        // to a regular app while this window is open so ⌘Tab can reach
        // it, and drop back to menu-bar-only when it closes.
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
                Text(title)
                    .font(.headline)
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

    /// Polls the TCC probes every 2 s for as long as this window is open.
    /// SwiftUI cancels a `.task` automatically when its view disappears, so
    /// this loop stops on its own when the window closes.
    private func pollLoop() async {
        while !Task.isCancelled {
            refreshGrants()
            // Fixed 2 s even once all grants are green: this loop is also
            // how a revocation (or the TCC-reset dance) is noticed, and
            // AppModel documents the 2 s contract. The probes are cheap
            // cached-TCC reads, so backing off buys nothing meaningful.
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    /// Re-reads all three probes and updates `model.grants`. Microphone and
    /// Input Monitoring are both special-cased: on a false→true flip we
    /// hand off to `AppModel` so it can react immediately, without
    /// requiring an app restart — `prewarmRecorderIfGranted()` starts the
    /// audio engine ahead of the first key-down, and
    /// `activateHotkeyIfNeeded()` live-activates the hotkey tap.
    private func refreshGrants() {
        let microphone = TCC.microphoneGranted()
        let microphoneNewlyGranted = microphone && !model.grants.microphone
        model.grants.microphone = microphone
        if microphoneNewlyGranted {
            model.prewarmRecorderIfGranted()
        }

        model.grants.accessibility = TCC.accessibilityGranted()

        let inputMonitoring = TCC.inputMonitoringGranted()
        if inputMonitoring && !model.grants.inputMonitoring {
            model.activateHotkeyIfNeeded()
        } else {
            model.grants.inputMonitoring = inputMonitoring
        }
    }
}
