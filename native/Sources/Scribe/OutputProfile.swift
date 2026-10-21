import Foundation

/// Per-app output rules, keyed by bundle id. Deterministic text tweaks only — no prompt change, so no new warm
/// prefix and no new eval. A nil `cleanup` leaves the global toggle in charge.
struct AppProfile: Codable, Equatable, Identifiable {
    var bundleID: String
    /// For the Settings list; a bundle id alone is unreadable.
    var appName: String
    var cleanup: Bool?
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

    /// One sentence-final period; an ellipsis ("...") and other punctuation stay.
    static func strippingTrailingPeriod(_ text: String) -> String {
        guard text.hasSuffix("."), !text.hasSuffix("..") else { return text }
        return String(text.dropLast())
    }

    /// Only a sentence-initial capital: "iPhone", "OK", "I" and "I'm" are left alone.
    static func lowercasingFirst(_ text: String) -> String {
        guard let first = text.first, first.isUppercase else { return text }
        let firstWord = text.prefix { !$0.isWhitespace }
        guard firstWord != "I", !firstWord.hasPrefix("I'"), !firstWord.hasPrefix("I\u{2019}"),
            firstWord.dropFirst().allSatisfy({ !$0.isUppercase })
        else { return text }
        return first.lowercased() + text.dropFirst()
    }

    /// Cleanup for this dictation: the profile's answer when it has one, else the global toggle.
    static func cleanupEnabled(_ profile: AppProfile?, global: Bool) -> Bool {
        profile?.cleanup ?? global
    }
}
