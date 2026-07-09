import MLX
import XCTest

@testable import Scribe

/// Proves that `GemmaBackend.unload()` actually returns the ~2.5 GB of
/// unified memory the 4-bit model occupies — not just drops the Swift
/// reference. The model's Metal allocations don't show up in RSS, only in
/// phys_footprint, and MLX parks freed buffers in its own cache pool, so
/// "unloaded" and "memory reclaimed" are separate claims. This test pins
/// the second one.
final class MemoryReclaimTests: XCTestCase {
    /// phys_footprint — the number Activity Monitor's Memory column shows,
    /// and the one that includes Metal/MLX allocations.
    private func physFootprint() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return -1 }
        return Int64(info.phys_footprint)
    }

    private func mb(_ bytes: Int64) -> String {
        String(format: "%.0f MB", Double(bytes) / 1_048_576)
    }

    /// Diagnostic: which bucket holds the pages (dirty heap vs IOKit/Metal
    /// vs compressed) — tells us WHO still pins memory after an unload.
    private func printVmBreakdown(label: String) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }
        let internalMB = mb(Int64(info.internal))
        let externalMB = mb(Int64(info.external))
        let compressedMB = mb(Int64(info.compressed))
        let reusableMB = mb(Int64(info.reusable))
        let graphicsMB = mb(info.ledger_tag_graphics_footprint)
        let footprintMB = mb(Int64(info.phys_footprint))
        var line = "[MemoryReclaim] \(label): internal=\(internalMB)"
        line += " external=\(externalMB) compressed=\(compressedMB)"
        line += " reusable=\(reusableMB) graphics=\(graphicsMB)"
        line += " phys_footprint=\(footprintMB)"
        print(line)
    }

    func testUnloadReclaimsGemmaMemory() async throws {
        let backend = GemmaBackend()
        let before = physFootprint()

        // Load + warm-up + one real generation, same as production use.
        _ = try await backend.clean(
            "so um hello there world this is just a memory test utterance okay")
        let loaded = physFootprint()
        XCTAssertGreaterThan(
            loaded - before, 1_000_000_000,
            "sanity: loading Gemma should cost >1 GB (got \(mb(loaded - before)))")

        await backend.unload()
        printVmBreakdown(label: "after-unload")

        // MLX releases its buffers synchronously (active/cache hit 0 inside
        // unload()), but the kernel scavenges the freed graphics pages
        // asynchronously — footprint drops from ~3.3 GB to ~200 MB within a
        // few seconds, not instantly. Poll rather than fixed-sleep.
        var after = physFootprint()
        for _ in 0..<30 where loaded - after < 1_500_000_000 {
            try await Task.sleep(nanoseconds: 500_000_000)
            after = physFootprint()
        }
        printVmBreakdown(label: "settled")

        // The 4-bit weights are ~2.5 GB; require most of the load cost back.
        XCTAssertGreaterThan(
            loaded - after, 1_500_000_000,
            "unload() must return the model's memory to the OS "
                + "(loaded=\(mb(loaded)) after=\(mb(after)), "
                + "mlxActive=\(mb(Int64(GPU.activeMemory))), "
                + "mlxCache=\(mb(Int64(GPU.cacheMemory))))")

        // Production flow after an idle unload: the next dictation reloads.
        // Pins that unload() left the backend reusable — including a fresh
        // warm-up, since unload() also drops the warm prefix state.
        let reloaded = try await backend.clean(
            "so um this checks that cleanup still works after an unload")
        XCTAssertFalse(reloaded.isEmpty)
    }
}
