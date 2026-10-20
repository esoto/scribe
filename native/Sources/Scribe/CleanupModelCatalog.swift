import Foundation

/// Bridges GemmaBackend download progress (any thread) to CleanupModelController, which
/// can't be captured while its stored properties are still initializing.
final class ProgressRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((String, Double) -> Void)?

    func set(_ handler: @escaping (String, Double) -> Void) {
        lock.withLock { self.handler = handler }
    }

    func report(model label: String, fraction: Double) {
        let handler = lock.withLock { self.handler }
        handler?(label, fraction)
    }
}

/// The cleanup models scribe offers, and the pure rules that pick one at
/// launch, choose a fallback, and gate what each may see in its prompt.
/// Pure (no I/O) so the rules are unit-testable without a controller — same
/// idea as `EngineSwitch`.
enum CleanupModelID: String, CaseIterable, Sendable {
    case gemma3
    case gemma4
    case gemma4e2b
    case appleIntelligence
}

struct CleanupModelSpec: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case mlx(repoID: String, revision: String, extraEOSTokens: Set<String>)
        case appleIntelligence
    }

    let id: CleanupModelID
    let label: String
    let kind: Kind
    /// Shown before the user picks it; nil = nothing to download.
    let approxDownloadBytes: Int64?
    /// Measured to keep every word with learned vocabulary in its prompt
    /// (DictionaryFidelityTests, all conditions). Only these models are
    /// handed the learned glossary — the per-model learning gate.
    let fidelitySafe: Bool

    var repoID: String? {
        if case .mlx(let repoID, _, _) = kind { return repoID }
        return nil
    }

    var revision: String? {
        if case .mlx(_, let revision, _) = kind { return revision }
        return nil
    }
}

enum CleanupModelCatalog {
    // Each model is pinned to a commit: the cleanup model reads every dictation,
    // so a swapped upstream repo must not become a silent model swap. The SHAs
    // are `main` as resolved from the Hugging Face API on 2026-10-14. Moving
    // one means re-running the golden, guard and fidelity evals first.
    static let gemma3 = CleanupModelSpec(
        id: .gemma3, label: "Gemma 3 4B",
        kind: .mlx(
            repoID: "mlx-community/gemma-3-4b-it-qat-4bit",
            revision: "3d9ef289111449933c22761961f16a5df237ce2a",  // 2026-10-14
            extraEOSTokens: ["<end_of_turn>"]),
        approxDownloadBytes: 3_030_000_000, fidelitySafe: false)

    /// Plain 4-bit PTQ build. NOT the QAT-OptiQ build: that one answered the
    /// haiku injection case and peaks at 6.8 GB (2026-10-10 benchmark).
    static let gemma4 = CleanupModelSpec(
        id: .gemma4, label: "Gemma 4 E4B",
        kind: .mlx(
            repoID: "mlx-community/gemma-4-e4b-it-4bit",
            revision: "475b9088d29754a3379866cf5aeb6b41acd313c2",  // 2026-10-14
            extraEOSTokens: ["<turn|>"]),
        approxDownloadBytes: 5_180_000_000, fidelitySafe: true)

    /// Smaller sibling of E4B (2.3B effective vs 4.5B; 3.6 GB vs 5.2 GB) and
    /// the fastest local model measured (~330 ms vs E4B's ~460 ms). Keeps
    /// every word with learned vocabulary (DictionaryFidelityTests), so it is
    /// fidelity-safe — but golden is 8/10, so it stays opt-in, never the
    /// default.
    static let gemma4e2b = CleanupModelSpec(
        id: .gemma4e2b, label: "Gemma 4 E2B",
        kind: .mlx(
            repoID: "mlx-community/gemma-4-e2b-it-4bit",
            revision: "238767527555cb75a05732a84dff5d6ba0dd6809",  // 2026-10-14
            extraEOSTokens: ["<turn|>"]),
        approxDownloadBytes: 3_580_000_000, fidelitySafe: true)

    static let appleIntelligence = CleanupModelSpec(
        id: .appleIntelligence, label: "Apple Intelligence",
        kind: .appleIntelligence, approxDownloadBytes: nil, fidelitySafe: false)

    static let all: [CleanupModelSpec] = [gemma3, gemma4, gemma4e2b, appleIntelligence]

    /// Lets callers that only know the repo (the on-disk store) check the commit
    /// the app will actually load.
    static func pinnedRevision(repoID: String) -> String? {
        all.first { $0.repoID == repoID }?.revision
    }

    static func spec(_ id: CleanupModelID) -> CleanupModelSpec {
        switch id {
        case .gemma3: return gemma3
        case .gemma4: return gemma4
        case .gemma4e2b: return gemma4e2b
        case .appleIntelligence: return appleIntelligence
        }
    }

    /// What fresh installs get. Always a downloadable (MLX) model. Flipped
    /// to `.gemma4` in Task 11 only if Gemma 4 passes golden + guard +
    /// fidelity.
    static let defaultID: CleanupModelID = .gemma3

    enum Selection: Equatable, Sendable {
        case model(CleanupModelID)
        /// `cleanupModelPath` set via `defaults write` — overrides the picker.
        case custom(path: String)

        /// Value published as `CleanupModelController.activeCleanupModel` and logged.
        var storageID: String {
            switch self {
            case .model(let id): return id.rawValue
            case .custom: return "custom"
            }
        }

        /// A custom model's fidelity is unknown, so it never gets the glossary.
        var fidelitySafe: Bool {
            switch self {
            case .model(let id): return CleanupModelCatalog.spec(id).fidelitySafe
            case .custom: return false
            }
        }
    }

    /// The model to run at launch. A custom path wins. A stored, known id is
    /// kept — except Apple Intelligence while it's unavailable. With nothing
    /// stored, an install that already has Gemma 3 on disk stays on it (no
    /// surprise multi-GB download); a fresh install gets the default.
    static func resolve(
        stored: String?, customPath: String?,
        isDownloaded: (CleanupModelID) -> Bool, appleIntelligenceAvailable: Bool
    ) -> Selection {
        if let customPath { return .custom(path: customPath) }
        if let stored, let id = CleanupModelID(rawValue: stored) {
            if id == .appleIntelligence && !appleIntelligenceAvailable {
                return .model(fallbackID(isDownloaded: isDownloaded))
            }
            return .model(id)
        }
        if stored == nil && isDownloaded(.gemma3) { return .model(.gemma3) }
        return .model(defaultID)
    }

    /// Where to go when Apple Intelligence disappears: an already-downloaded
    /// model first (no download stall), the default otherwise.
    static func fallbackID(isDownloaded: (CleanupModelID) -> Bool) -> CleanupModelID {
        if isDownloaded(defaultID) { return defaultID }
        if isDownloaded(.gemma3) { return .gemma3 }
        return defaultID
    }

    /// The per-model learning gate: models not proven fidelity-safe never
    /// see the learned glossary (Gemma 3 measurably drops words with it).
    static func promptSnapshot(_ snapshot: DictionarySnapshot, for selection: Selection) -> DictionarySnapshot {
        selection.fidelitySafe ? snapshot : DictionarySnapshot(pairs: snapshot.pairs, glossary: [])
    }

    /// Menu status line while a cleanup model downloads/loads.
    static func statusText(label: String, fraction: Double) -> String {
        fraction < 1
            ? "Downloading \(label)… \(Int((fraction * 100).rounded(.down)))%"
            : "Loading \(label)…"
    }
}

extension CleanupModelCatalog {
    /// Constructs (never loads) the backend for a selection.
    static func makeBackend(
        _ selection: Selection, relay: ProgressRelay,
        onAppleIntelligenceLost: @escaping @Sendable () -> Void,
        onLog: (@Sendable (String) -> Void)? = nil
    ) -> any CleanupModelBackend {
        switch selection {
        case .custom(let path):
            return GemmaBackend(spec: gemma3, customModelPath: path, onLog: onLog)
        case .model(let id):
            let spec = spec(id)
            if case .appleIntelligence = spec.kind, #available(macOS 26.0, *) {
                return AppleIntelligenceBackend(onUnavailable: onAppleIntelligenceLost)
            }
            // Pre-26 never reaches here with AFM: resolve() and the picker only
            // offer it while AppleIntelligence.isAvailable.
            let mlxSpec = spec.repoID == nil ? gemma3 : spec
            return GemmaBackend(
                spec: mlxSpec, onProgress: { relay.report(model: mlxSpec.label, fraction: $0) }, onLog: onLog)
        }
    }
}

/// The model in use (or being switched to) can't be deleted, and Apple
/// Intelligence has nothing on disk to delete.
func canDeleteModel(_ id: CleanupModelID, active: String, pending: String?) -> Bool {
    CleanupModelCatalog.spec(id).repoID != nil && id.rawValue != active && id.rawValue != pending
}
