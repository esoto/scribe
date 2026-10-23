import Foundation

/// The two model downloads' progress, kept off `AppModel` so an unrelated `AppModel` write (microphone list,
/// launch at login) never rebuilds the menu-bar glyph.
@MainActor
final class DownloadStatus: ObservableObject {
    /// "Downloading Parakeet Ultra… NN%" while the STT model downloads (first launch after upgrade); nil otherwise.
    @Published private(set) var sttStatus: String?
    /// The same download as a 0…1 fraction for the menu-bar glyph; nil once it completes.
    @Published private(set) var sttFraction: Double?
    /// "Downloading Enhance Audio… NN%" while its model downloads (first use after the toggle goes on); nil otherwise.
    @Published private(set) var enhancerStatus: String?

    /// FluidAudio reports every received chunk; the status line and the glyph only change with the whole percent,
    /// so anything else is dropped before it can rebuild a view.
    func report(stt label: String, fraction: Double) {
        let status = Self.status(label: label, fraction: fraction)
        guard status != sttStatus else { return }
        sttStatus = status
        sttFraction = fraction < 1 ? fraction : nil
    }

    func report(enhancer label: String, fraction: Double) {
        let status = Self.status(label: label, fraction: fraction)
        guard status != enhancerStatus else { return }
        enhancerStatus = status
    }

    /// Nil at 100 %: the download is over, and a load from disk has no percent to show.
    private static func status(label: String, fraction: Double) -> String? {
        fraction < 1 ? CleanupModelCatalog.statusText(label: label, fraction: fraction) : nil
    }

    /// The one definition of a whole percent, so the status text and every publish gate move together.
    nonisolated static func wholePercent(_ fraction: Double) -> Int {
        Int((fraction * 100).rounded(.down))
    }

    /// Whether a chunk's fraction is worth publishing after `previous` was. Nothing published yet counts as a change,
    /// and 1 is its own percent, so completion always gets through once.
    nonisolated static func wholePercentChanged(from previous: Double?, to fraction: Double) -> Bool {
        guard let previous else { return true }
        return wholePercent(previous) != wholePercent(fraction)
    }
}
