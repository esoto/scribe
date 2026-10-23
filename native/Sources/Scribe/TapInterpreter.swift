import Foundation

/// What a key event means for the dictation, once taps and double taps are read.
enum HoldEvent: Equatable {
    /// Hold-to-talk began (also the first tap of a double tap; the pipeline discards a short hold itself).
    case start
    /// The key came up during hold-to-talk.
    case stop
    /// Second tap inside the window: record until the next tap.
    case startLatched
    /// The tap that ends a latched recording.
    case stopLatched
    /// A release that means nothing (the latching tap's own release, the stopping tap's release).
    case ignore
}

/// Turns `KeyStateMachine`'s down/up into hold-to-talk and, in `holdOrLatch`, a double tap that latches.
/// Pure; the coordinator feeds it the clock. `reset()` after a watchdog stop or system sleep.
struct TapInterpreter {
    var mode: HotkeyMode
    /// Two downs closer than this latch.
    let doubleTapWindow: Double
    /// A press shorter than this is a tap, same threshold the pipeline uses to discard one. Settings can change it.
    var tapMax: Double

    private(set) var isLatched = false
    private var downAt: Double?
    private var lastTapUp: Double?
    private var swallowNextUp = false

    init(mode: HotkeyMode, doubleTapWindow: Double = 0.4, tapMax: Double = 0.3) {
        self.mode = mode
        self.doubleTapWindow = doubleTapWindow
        self.tapMax = tapMax
    }

    mutating func down(at t: Double) -> HoldEvent {
        if isLatched {
            isLatched = false
            swallowNextUp = true
            lastTapUp = nil
            return .stopLatched
        }
        if mode == .holdOrLatch, let lastTapUp, t - lastTapUp <= doubleTapWindow {
            isLatched = true
            swallowNextUp = true
            self.lastTapUp = nil
            return .startLatched
        }
        downAt = t
        return .start
    }

    mutating func up(at t: Double) -> HoldEvent {
        if swallowNextUp {
            swallowNextUp = false
            return .ignore
        }
        guard let downAt else { return .ignore }
        self.downAt = nil
        lastTapUp = (t - downAt) < tapMax ? t : nil
        return .stop
    }

    /// `scribe://toggle` started a recording without the key: the next tap must stop it like a latched one.
    mutating func latchExternally() {
        isLatched = true
        downAt = nil
        lastTapUp = nil
        swallowNextUp = false
    }

    /// Forgets everything, including a latch: the recording it belonged to has already been ended by the caller.
    mutating func reset() {
        isLatched = false
        downAt = nil
        lastTapUp = nil
        swallowNextUp = false
    }
}
