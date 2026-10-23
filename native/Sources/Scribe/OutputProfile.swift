import Foundation

/// Per-app output rules, keyed by bundle id. Deterministic text tweaks only — no prompt change, so no new warm
/// prefix and no new eval. A nil `cleanup` or `voiceCommands` leaves the global switch in charge.
struct AppProfile: Codable, Equatable, Identifiable {
    var bundleID: String
    /// For the Settings list; a bundle id alone is unreadable.
    var appName: String
    var cleanup: Bool?
    var voiceCommands: Bool?
    var stripTrailingPeriod = false
    var lowercaseFirst = false

    var id: String { bundleID }
}

enum OutputProfile {
    /// After cleanup, replacements and snippets, right before the paste.
    static func apply(_ profile: AppProfile?, to text: String) -> String {
        guard let profile else { return text }
        var out = text
        if profile.stripTrailingPeriod { out = strippingTrailingPeriod(out) }
        if profile.lowercaseFirst { out = lowercasingFirst(out) }
        return out
    }

    /// One sentence-final period; an ellipsis ("..."), other punctuation and an abbreviation's own period
    /// ("p.m.", "U.S.") stay.
    static func strippingTrailingPeriod(_ text: String) -> String {
        guard text.hasSuffix("."), !text.hasSuffix("..") else { return text }
        let lastWord = text.split(whereSeparator: { $0.isWhitespace }).last ?? ""
        if lastWord.count >= 4,
            lastWord.enumerated().allSatisfy({ $0.offset % 2 == 0 ? $0.element.isLetter : $0.element == "." })
        { return text }
        return String(text.dropLast())
    }

    private static let openingMarks: Set<Character> = ["¿", "¡", "\"", "'", "\u{201C}", "\u{2018}", "«", "(", "["]

    /// Only a sentence-initial capital: "iPhone", "OK", "I" and "I'm" are left alone. An opening "¿", "¡" or quote
    /// comes before the capital in Spanish and in quoted speech.
    static func lowercasingFirst(_ text: String) -> String {
        guard let start = text.firstIndex(where: { !openingMarks.contains($0) }), text[start].isUppercase else { return text }
        let firstWord = text[start...].prefix { !$0.isWhitespace }
        guard TermReplacer.trimEdges(String(firstWord)) != "I", !firstWord.hasPrefix("I'"),
            !firstWord.hasPrefix("I\u{2019}"), firstWord.dropFirst().allSatisfy({ !$0.isUppercase })
        else { return text }
        return String(text[..<start]) + text[start].lowercased() + text[text.index(after: start)...]
    }

    /// Cleanup for this dictation: the profile's answer when it has one, else the global toggle.
    static func cleanupEnabled(_ profile: AppProfile?, global: Bool) -> Bool {
        profile?.cleanup ?? global
    }

    /// Voice commands and inline breaks for this dictation: the profile's answer when it has one, else the global
    /// switch. A Terminal wants them off even while everything else keeps them on.
    static func voiceCommandsEnabled(_ profile: AppProfile?, global: Bool) -> Bool {
        profile?.voiceCommands ?? global
    }

    /// Whether the cleanup model should be resident at launch: the global toggle, or any app that turns cleanup on.
    /// Otherwise that app's first dictation loads the model inside the cleanup deadline and pastes raw.
    static func warmUpNeeded(global: Bool, profiles: [AppProfile]) -> Bool {
        global || profiles.contains { $0.cleanup == true }
    }
}

extension AppProfile {
    /// Missing switches decode as off: the synthesized decoder would reject the whole file, and the next write
    /// would then overwrite every profile.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bundleID = try c.decode(String.self, forKey: .bundleID)
        appName = try c.decode(String.self, forKey: .appName)
        cleanup = try c.decodeIfPresent(Bool.self, forKey: .cleanup)
        voiceCommands = try c.decodeIfPresent(Bool.self, forKey: .voiceCommands)
        stripTrailingPeriod = try c.decodeIfPresent(Bool.self, forKey: .stripTrailingPeriod) ?? false
        lowercaseFirst = try c.decodeIfPresent(Bool.self, forKey: .lowercaseFirst) ?? false
    }
}
