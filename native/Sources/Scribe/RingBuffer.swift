import Foundation

/// Bounded, thread-safe sample accumulator for mic capture.
///
/// Ported from `scribe.recorder.RingBuffer` (src/scribe/recorder.py): whole
/// appends past capacity are dropped (never partially truncated), and
/// `drain()` hands back everything accumulated so far and empties the
/// buffer in one atomic step.
final class RingBuffer {
    private let cap: Int
    private var chunks: [[Float]] = []
    private var size = 0
    private let lock = NSLock()

    init(maxSeconds: Double, sampleRate: Double) {
        self.cap = Int(maxSeconds * sampleRate)
    }

    /// Drops the whole chunk (not a partial write) if it would exceed
    /// capacity — matches the Python reference's all-or-nothing append.
    func append(_ chunk: [Float]) {
        lock.lock()
        defer { lock.unlock() }
        guard size + chunk.count <= cap else { return }
        chunks.append(chunk)
        size += chunk.count
    }

    /// Returns the concatenation of everything accumulated since the last
    /// drain/clear, then empties the buffer.
    func drain() -> [Float] {
        lock.lock()
        let drained = chunks
        chunks = []
        size = 0
        lock.unlock()
        return drained.flatMap { $0 }
    }

    func clear() {
        _ = drain()
    }
}
