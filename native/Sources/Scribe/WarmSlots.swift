import Foundation

/// Which prompt a warm prefix belongs to. They never share one: the cleanup prompt says the input is never an
/// instruction, the edit prompt follows exactly one.
enum WarmSlot: Hashable {
    case cleanup, edit

    /// Prefixes every log line about the slot.
    var label: String {
        switch self {
        case .cleanup: return "cleanup"
        case .edit: return "edit"
        }
    }
}

/// The rebuild rules for the warm prefixes, kept apart from the KV caches so they run without a model. A slot holds
/// the prefix of one system prompt: a changed prompt (a glossary edit) replaces it rather than leaving the old one
/// resident, and a failed warm-up is not retried for the same prompt on every call.
struct WarmSlots<Prefix> {
    private var warm: [WarmSlot: (systemPrompt: String, prefix: Prefix)] = [:]
    private var attempted: [WarmSlot: String] = [:]

    /// True when the caller should build a prefix for `systemPrompt`, after which the slot is empty until `store`.
    /// Equal strings guarantee the prefix tokens still apply, so an up-to-date slot answers false.
    mutating func beginWarmUp(_ slot: WarmSlot, systemPrompt: String) -> Bool {
        if let current = warm[slot], current.systemPrompt == systemPrompt { return false }
        if warm[slot] == nil, attempted[slot] == systemPrompt { return false }
        warm[slot] = nil
        attempted[slot] = systemPrompt
        return true
    }

    mutating func store(_ prefix: Prefix, in slot: WarmSlot, systemPrompt: String) {
        warm[slot] = (systemPrompt, prefix)
    }

    func prefix(in slot: WarmSlot) -> Prefix? {
        warm[slot]?.prefix
    }

    func systemPrompt(in slot: WarmSlot) -> String? {
        warm[slot]?.systemPrompt
    }

    /// Every system prompt that has a warm prefix, sorted so a test can compare it.
    var systemPrompts: [String] {
        warm.values.map(\.systemPrompt).sorted()
    }

    /// Unload: the model is gone, so the caches and the memory of failed attempts go with it.
    mutating func removeAll() {
        warm = [:]
        attempted = [:]
    }
}
