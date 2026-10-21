import Foundation

/// What a `scribe://` URL may ask for. No parameters are accepted: any process or web page can open a URL scheme,
/// so the surface is a fixed verb list, and it is off by default (Settings › General).
enum URLCommand: Equatable {
    case pasteLast

    static let scheme = "scribe"

    /// `scribe://paste-last` and `scribe:paste-last` both parse; a query, fragment, user, port or extra path refuses.
    static func parse(_ url: URL) -> URLCommand? {
        guard url.scheme?.lowercased() == scheme, url.query == nil, url.fragment == nil, url.user == nil, url.port == nil
        else { return nil }
        let verb: String
        if let host = url.host, !host.isEmpty {
            guard url.path.isEmpty || url.path == "/" else { return nil }
            verb = host
        } else {
            verb = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        switch verb.lowercased() {
        case "paste-last": return .pasteLast
        default: return nil
        }
    }
}

/// What the app does with an opened URL.
enum URLOutcome: Equatable {
    case run(URLCommand)
    /// A known verb while the scheme is off: tell the user where the switch is, at most once every 30 s.
    case refusedOff
    /// Not ours or malformed: logged, nothing shown.
    case ignored
}

extension URLCommand {
    static func outcome(for url: URL, enabled: Bool) -> URLOutcome {
        guard let command = parse(url) else { return .ignored }
        return enabled ? .run(command) : .refusedOff
    }
}

extension URLCommand {
    /// Fixed text: everything after the scheme is the opener's, and scribe.log is what users attach to reports.
    static func ignoredLogLine(for url: URL) -> String {
        url.isFileURL ? "url ignored: a file was opened" : "url ignored: not a scribe:// command"
    }
}

extension URLCommand {
    /// A looping opener would otherwise stack one banner per open.
    static func shouldNotifyRefusal(lastAt: Date?, now: Date) -> Bool {
        lastAt.map { now.timeIntervalSince($0) >= 30 } ?? true
    }
}
