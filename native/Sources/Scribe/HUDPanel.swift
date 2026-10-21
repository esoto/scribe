import AppKit
import Combine
import SwiftUI

/// The recording pill: a non-activating panel above the Dock, on every Space and over full-screen apps. It never
/// becomes key — ⌘V must keep landing in the app the user is dictating into. Untested: it is a window.
@MainActor
final class HUDPanel {
    private let panel: NSPanel
    private var phaseWatcher: AnyCancellable?

    init(model: HUDModel) {
        panel = NonKeyPanel(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 40),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let hosting = NSHostingView(rootView: HUDView(model: model))
        hosting.frame = panel.contentRect(forFrameRect: panel.frame)
        panel.contentView = hosting
        phaseWatcher = model.$phase
            .receive(on: RunLoop.main)
            .sink { [weak self] phase in
                MainActor.assumeIsolated { self?.setVisible(phase != .hidden) }
            }
    }

    func setVisible(_ visible: Bool) {
        if visible {
            position()
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
    }

    /// Bottom centre of the screen with the menu bar, clear of the Dock.
    private func position() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let area = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: area.midX - size.width / 2, y: area.minY + 24))
    }
}

private final class NonKeyPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

struct HUDView: View {
    @ObservedObject var model: HUDModel

    var body: some View {
        HStack(spacing: 10) {
            Text(hudGlyph(model.phase))
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(model.phase == .listening ? Color.red : Color.primary)
            Text(hudLabel(model.phase))
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
            if model.phase == .listening {
                LevelBars(level: model.level)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .frame(width: 220, height: 40)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("scribe \(hudLabel(model.phase))")
    }
}

/// Five bars; a dead or wrong microphone shows as five flat bars.
private struct LevelBars: View {
    let level: Double

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<5, id: \.self) { index in
                Capsule()
                    .fill(Color.primary)
                    .frame(width: 3, height: 4 + 12 * barHeight(level, index: index))
            }
        }
        .frame(height: 16)
    }
}
