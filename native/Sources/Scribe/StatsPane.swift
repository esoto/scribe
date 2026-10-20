import SwiftUI

/// The Stats pane's view of the store: three windows, recomputed on the main actor after every recorded dictation.
@MainActor
final class StatsModel: ObservableObject {
    @Published private(set) var today: StatsSummary
    @Published private(set) var week: StatsSummary
    @Published private(set) var month: StatsSummary

    private let store: StatsStore
    private let now: () -> Date

    init(store: StatsStore, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.now = now
        let at = now()
        today = store.summary(days: 1, now: at)
        week = store.summary(days: 7, now: at)
        month = store.summary(days: 30, now: at)
        store.onChange = { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        let at = now()
        let fresh = (store.summary(days: 1, now: at), store.summary(days: 7, now: at), store.summary(days: 30, now: at))
        if fresh.0 != today { today = fresh.0 }
        if fresh.1 != week { week = fresh.1 }
        if fresh.2 != month { month = fresh.2 }
    }

    func reset() { store.reset() }
}

/// "12 dictations · 480 words · ≈ 12 min of typing"
func statsCountsLine(_ s: StatsSummary) -> String {
    guard s.dictations > 0 else { return "No dictations" }
    let dictations = s.dictations == 1 ? "1 dictation" : "\(s.dictations) dictations"
    return "\(dictations) · \(s.words) words · ≈ \(s.typingMinutesReplaced) min of typing"
}

/// Medians first, then the slow tail; nil when nothing was transcribed.
func statsLatencyLine(_ s: StatsSummary) -> String? {
    guard let sttP50 = s.sttP50, let sttP95 = s.sttP95 else { return nil }
    var line = "Transcription \(sttP50) ms"
    if let cleanupP50 = s.cleanupP50 { line += " · cleanup \(cleanupP50) ms" }
    line += " (median) · slowest 5%: \(sttP95)"
    if let cleanupP95 = s.cleanupP95 { line += " / \(cleanupP95)" }
    return line + " ms"
}

/// How often cleanup cost nothing but time; nil when it never ran.
func statsFallbackLine(_ s: StatsSummary) -> String? {
    guard let percent = s.rawFallbackPercent else { return nil }
    return "Pasted raw \(s.rawFallbacks) of \(s.cleaned + s.rawFallbacks) cleanups (\(percent)%)"
}

struct StatsPane: View {
    @ObservedObject var model: StatsModel

    var body: some View {
        Form {
            statsBlock("Today", model.today)
            statsBlock("Last 7 days", model.week)
            statsBlock("Last 30 days", model.month)
            Text("Counts and timings only — no text is kept. The raw rate says whether the cleanup model or its timeout is costing you words.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Reset Stats") { model.reset() }
                    .disabled(model.month.dictations == 0)
            }
        }
        .padding(16)
        .onAppear { model.refresh() }
    }

    @ViewBuilder
    private func statsBlock(_ title: String, _ s: StatsSummary) -> some View {
        Section(title) {
            Text(statsCountsLine(s))
            if let latency = statsLatencyLine(s) {
                Text(latency).font(.caption).foregroundStyle(.secondary)
            }
            if let fallback = statsFallbackLine(s) {
                Text(fallback).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
