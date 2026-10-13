import MLX
import XCTest

/// Checks that `GemmaBackend.unload()` returns the model's memory to the OS, not just drops the reference.
final class MemoryReclaimTests: XCTestCase {
    /// Includes Metal/MLX allocations, unlike RSS.
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

    /// Diagnostic breakdown of which VM bucket still holds memory after unload.
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

        _ = try await backend.clean(
            "so um hello there world this is just a memory test utterance okay")
        let loaded = physFootprint()
        XCTAssertGreaterThan(
            loaded - before, 1_000_000_000,
            "sanity: loading Gemma should cost >1 GB (got \(mb(loaded - before)))")

        await backend.unload()
        printVmBreakdown(label: "after-unload")

        // The kernel reclaims freed graphics pages asynchronously, so poll instead of sleeping once.
        var after = physFootprint()
        for _ in 0..<30 where loaded - after < 1_500_000_000 {
            try await Task.sleep(nanoseconds: 500_000_000)
            after = physFootprint()
        }
        printVmBreakdown(label: "settled")

        XCTAssertGreaterThan(
            loaded - after, 1_500_000_000,
            "unload() must return the model's memory to the OS "
                + "(loaded=\(mb(loaded)) after=\(mb(after)), "
                + "mlxActive=\(mb(Int64(GPU.activeMemory))), "
                + "mlxCache=\(mb(Int64(GPU.cacheMemory))))")

        // Backend must stay reusable after unload.
        let reloaded = try await backend.clean(
            "so um this checks that cleanup still works after an unload")
        XCTAssertFalse(reloaded.isEmpty)
    }
}
