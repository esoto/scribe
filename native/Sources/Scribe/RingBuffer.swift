import Foundation

/// Thread-safe sample accumulator; appends that would exceed capacity are dropped whole.
final class RingBuffer {
    private let cap: Int
    private var chunks: [[Float]] = []
    private var size = 0
    private let lock = NSLock()

    init(maxSeconds: Double, sampleRate: Double) {
        self.cap = Int(maxSeconds * sampleRate)
    }

    func append(_ chunk: [Float]) {
        lock.lock()
        defer { lock.unlock() }
        guard size + chunk.count <= cap else { return }
        chunks.append(chunk)
        size += chunk.count
    }

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
