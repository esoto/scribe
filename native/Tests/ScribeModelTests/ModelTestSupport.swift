import AVFoundation
import FluidAudio
import Foundation

/// Locates the repo root from this file's on-disk path so fixtures/golden.json
/// resolve regardless of the xcodebuild working directory. Mirrors the pattern
/// in `native/Sources/ScribeSpike/main.swift` — this file lives at the same
/// depth below the repo root (native/Tests/ScribeModelTests/*.swift vs.
/// native/Sources/ScribeSpike/main.swift), so the same four
/// `deletingLastPathComponent()` calls land on the repo root.
func repoRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
}

/// Loads a fixture WAV from `tests_models/fixtures/` and resamples it to the
/// Float PCM format the STT engines expect, via FluidAudio's `AudioConverter`
/// — same approach as the Task 1 spike.
func loadPcm(_ name: String) throws -> [Float] {
    let url = repoRoot().appendingPathComponent("tests_models/fixtures/\(name)")
    let file = try AVAudioFile(forReading: url)
    let fmt = file.processingFormat
    let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: buf)
    return try AudioConverter().resampleBuffer(buf)
}
