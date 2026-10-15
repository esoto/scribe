import AppKit
import SwiftUI

struct ModelRow: Identifiable, Equatable {
    let id: CleanupModelID
    let label: String
    let detail: String
    let isActive: Bool
    let canUse: Bool
    let canDelete: Bool
    let bytesOnDisk: Int64
    let useLabel: String
    let canCancel: Bool
}

/// Decimal GB/MB with a POSIX "." separator. Free function, unit-tested.
func formatBytes(_ bytes: Int64) -> String {
    let mb = Double(bytes) / 1_000_000
    // Round before choosing the unit: 999_999_999 bytes is 1000 MB after
    // rounding, which must read "1.0 GB" rather than "1000 MB".
    if mb.rounded() >= 1000 { return String(format: "%.1f GB", Double(bytes) / 1_000_000_000) }
    return String(format: "%.0f MB", mb)
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
                canDelete: false, bytesOnDisk: 0, useLabel: "Use", canCancel: false)
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
            bytesOnDisk: status.bytes,
            useLabel: status.isDownloaded ? "Use" : "Download & Use",
            canCancel: spec.id.rawValue == pending)
    }
}

/// Shown under the Dictionary window's "Learn new terms" toggle when the active model is gated off.
func learningNote(fidelitySafe: Bool, learningOn: Bool) -> String? {
    guard learningOn, !fidelitySafe else { return nil }
    return "Learned terms aren't sent to this model — it can drop words"
}

func deleteConfirmationTitle(_ row: ModelRow?) -> String {
    guard let row else { return "" }
    return "Delete \(row.label) (\(formatBytes(row.bytesOnDisk)))?"
}

/// Settings › Models: every cleanup model with its disk state. Use one, cancel a switch in flight, or delete a
/// downloaded one you're done trying. The model in use can't be deleted.
struct ModelsPane: View {
    @ObservedObject var model: CleanupModelController
    @State private var pendingDelete: ModelRow?

    private var rows: [ModelRow] {
        modelRows(
            statuses: model.modelStatuses, active: model.activeCleanupModel,
            pending: model.pendingCleanupModel,
            appleIntelligenceReason: model.appleIntelligenceUnavailableReason)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if model.activeCleanupModel == "custom" {
                Text("A custom model is set via `defaults write dev.esoto.scribe cleanupModelPath`; it overrides this list.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let status = model.cleanupModelStatus {
                HStack(spacing: 8) {
                    if let fraction = model.cleanupModelProgress, fraction < 1 {
                        ProgressView(value: fraction)
                            .progressViewStyle(.linear)
                            .frame(width: 140)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
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
                            if row.canCancel {
                                // Selecting the model already in use is the revert path.
                                Button("Cancel") {
                                    if let active = CleanupModelID(rawValue: model.activeCleanupModel) {
                                        model.switchCleanupModel(to: active)
                                    }
                                }
                            }
                            Button(row.useLabel) { model.switchCleanupModel(to: row.id) }
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
            HStack {
                Text("On disk: \(formatBytes(rows.map(\.bytesOnDisk).reduce(0, +)))")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([ModelStore.baseDirectory])
                }
            }
        }
        .padding(16)
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
