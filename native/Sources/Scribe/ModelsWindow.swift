import AppKit
import SwiftUI

/// Scene id for the cleanup-models window, shared by the menu's
/// "Manage Models…" item and the scene in `ScribeApp`.
let modelsWindowID = "models"

func openModelsWindow(_ openWindow: OpenWindowAction) {
    NSApp.activate(ignoringOtherApps: true)
    openWindow(id: modelsWindowID)
}

struct ModelRow: Identifiable, Equatable {
    let id: CleanupModelID
    let label: String
    let detail: String
    let isActive: Bool
    let canUse: Bool
    let canDelete: Bool
    let bytesOnDisk: Int64
}

/// Decimal GB/MB with a POSIX "." separator. Free function, unit-tested.
func formatBytes(_ bytes: Int64) -> String {
    let gb = Double(bytes) / 1_000_000_000
    if gb >= 1 { return String(format: "%.1f GB", gb) }
    return String(format: "%.0f MB", Double(bytes) / 1_000_000)
}

/// One row per catalog model. Free function, unit-tested.
func modelRows(
    statuses: [CleanupModelID: CleanupModelStore.Status], active: String, pending: String?,
    appleIntelligenceReason: String?
) -> [ModelRow] {
    CleanupModelCatalog.all.map { spec in
        let isActive = spec.id.rawValue == active
        guard spec.repoID != nil else {
            return ModelRow(
                id: spec.id, label: spec.label,
                detail: isActive ? "In use · built into macOS" : (appleIntelligenceReason ?? "Built into macOS · no download"),
                isActive: isActive, canUse: appleIntelligenceReason == nil && !isActive,
                canDelete: false, bytesOnDisk: 0)
        }
        let status = statuses[spec.id] ?? .notDownloaded
        let detail: String
        switch status {
        case .downloaded(let bytes): detail = "\(isActive ? "In use" : "Downloaded") · \(formatBytes(bytes))"
        case .partial(let bytes): detail = "Incomplete download · \(formatBytes(bytes))"
        case .notDownloaded: detail = "Not downloaded · ~\(formatBytes(spec.approxDownloadBytes ?? 0))"
        }
        return ModelRow(
            id: spec.id, label: spec.label, detail: detail, isActive: isActive,
            canUse: !isActive && spec.id.rawValue != pending,
            canDelete: status != .notDownloaded && canDeleteModel(spec.id, active: active, pending: pending),
            bytesOnDisk: status.bytes)
    }
}

/// Menu label: download size until it's on disk; AFM labelled honestly.
func pickerLabel(_ spec: CleanupModelSpec, status: CleanupModelStore.Status) -> String {
    guard let bytes = spec.approxDownloadBytes else { return "\(spec.label) (fastest, less accurate)" }
    return status.isDownloaded ? spec.label : "\(spec.label) — \(formatBytes(bytes)) download"
}

/// Shown under "Learn New Terms" when the active model is gated off.
func learningNote(fidelitySafe: Bool, learningOn: Bool) -> String? {
    guard learningOn, !fidelitySafe else { return nil }
    return "Learned terms aren't sent to this model — it can drop words"
}

func deleteConfirmationTitle(_ row: ModelRow?) -> String {
    guard let row else { return "" }
    return "Delete \(row.label) (\(formatBytes(row.bytesOnDisk)))?"
}

/// Lists every cleanup model with its disk state: use one, or delete a
/// downloaded one you're done trying. The model in use can't be deleted.
struct ModelsWindow: View {
    @ObservedObject var model: AppModel
    @State private var pendingDelete: ModelRow?

    private var rows: [ModelRow] {
        modelRows(
            statuses: model.modelStatuses, active: model.activeCleanupModel,
            pending: model.pendingCleanupModel,
            appleIntelligenceReason: model.appleIntelligenceUnavailableReason)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Cleanup Models").font(.title2.bold())
            if model.activeCleanupModel == "custom" {
                Text("A custom model is set via `defaults write dev.esoto.scribe cleanupModelPath`; it overrides this list.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(rows) { row in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.label).fontWeight(row.isActive ? .semibold : .regular)
                                Text(row.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Use") { model.switchCleanupModel(to: row.id) }
                                .disabled(!row.canUse || model.activeCleanupModel == "custom")
                            Button {
                                pendingDelete = row
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .disabled(!row.canDelete)
                            .help(row.canDelete ? "Delete the downloaded files" : "Nothing to delete, or the model is in use")
                        }
                    }
                }
                .padding(4)
            }
            Text("On disk: \(formatBytes(rows.map(\.bytesOnDisk).reduce(0, +)))")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            model.refreshDownloadedModels()
            model.refreshAppleIntelligenceAvailability()
        }
        .confirmationDialog(
            deleteConfirmationTitle(pendingDelete),
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let row = pendingDelete { model.deleteCleanupModel(row.id) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("It downloads again if you select it later.")
        }
    }
}
