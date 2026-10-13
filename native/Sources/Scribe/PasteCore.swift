import Foundation

/// Error thrown when paste delivery fails.
struct PasteError: Error {
    let message: String
}

/// Restores the prior clipboard only if its changeCount is unchanged since the paste.
final class Paster {
    private let pasteboard: PasteboardLike
    private let postCmdV: () throws -> Void
    private let schedule: (Double, @escaping () -> Void) -> Void
    private let restoreDelay: Double

    init(
        pasteboard: PasteboardLike,
        postCmdV: @escaping () throws -> Void,
        schedule: @escaping (Double, @escaping () -> Void) -> Void,
        restoreDelay: Double
    ) {
        self.pasteboard = pasteboard
        self.postCmdV = postCmdV
        self.schedule = schedule
        self.restoreDelay = restoreDelay
    }

    func paste(_ text: String) throws {
        let saved = pasteboard.get()
        pasteboard.set(text)
        let setCount = pasteboard.changeCount()

        do {
            try postCmdV()
        } catch {
            throw PasteError(message: String(describing: error))
        }

        if saved != nil {
            schedule(restoreDelay) { [weak self] in
                self?.restore(saved: saved!, setCount: setCount)
            }
        }
    }

    private func restore(saved: String, setCount: Int) {
        if pasteboard.changeCount() == setCount {
            pasteboard.set(saved)
        }
    }
}
