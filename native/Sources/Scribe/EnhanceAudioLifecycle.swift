import Foundation

/// When Enhance Audio's model loads and unloads: on toggle-on, at launch and key-down while on, never from a
/// dictation. A load can't be cancelled, so one that lands after a toggle-off is undone.
@MainActor
final class EnhanceAudioLifecycle {
    private(set) var enabled: Bool
    private let enhancer: UnloadableEnhancer

    init(enhancer: UnloadableEnhancer, enabled: Bool) {
        self.enhancer = enhancer
        self.enabled = enabled
    }

    @discardableResult
    func setEnabled(_ on: Bool) -> Task<Void, Never> {
        enabled = on
        guard on else { return Task { [enhancer] in await enhancer.unload() } }
        return warmUp()
    }

    @discardableResult
    func warmUp() -> Task<Void, Never> {
        guard enabled else { return Task {} }
        return Task { [weak self, enhancer] in
            await enhancer.preload()
            if self?.enabled != true { await enhancer.unload() }
        }
    }

    func unloadIfResident() async -> Bool {
        guard await enhancer.isLoaded else { return false }
        await enhancer.unload()
        return true
    }
}
