import Foundation

/// The seven instructions edit-by-voice understands, matched as the whole utterance with the voice-command folding.
/// Fixed on purpose: each verb is one tested prompt line, and the only text the model can be attacked through is the
/// selection itself. "Make it longer" is left out because it invites invention.
enum EditVerb: String, CaseIterable, Equatable {
    case shorter, fixGrammar, formal, casual, list, toSpanish, toEnglish

    /// The pill's verdict after a successful edit.
    var displayName: String {
        switch self {
        case .shorter: return "Shorter"
        case .fixGrammar: return "Fix grammar"
        case .formal: return "Formal"
        case .casual: return "Casual"
        case .list: return "List"
        case .toSpanish: return "To Spanish"
        case .toEnglish: return "To English"
        }
    }

    /// The instruction line inside <instruction>; the few-shots teach the shape, this line names the change.
    var instruction: String {
        switch self {
        case .shorter: return "Rewrite it shorter, keeping its meaning."
        case .fixGrammar: return "Fix grammar, spelling and punctuation; change nothing else."
        case .formal: return "Rewrite it in a formal register."
        case .casual: return "Rewrite it in a casual, friendly register."
        case .list: return "Turn it into a bulleted list, one point per line, each line starting with \"- \"."
        case .toSpanish: return "Translate it to Spanish."
        case .toEnglish: return "Translate it to English."
        }
    }

    var keepsNewlines: Bool { self == .list }
    var isTranslation: Bool { self == .toSpanish || self == .toEnglish }

    /// Character ratio result/selection the gate accepts; starting values, tuned by the edit golden set.
    var lengthBand: (low: Double, high: Double) {
        switch self {
        case .shorter: return (0.3, 0.9)
        case .fixGrammar: return (0.8, 1.25)
        case .formal: return (0.7, 1.4)
        // Natural casual rewrites of a stiff selection measured 0.37–0.57, so the formal floor would reject them.
        case .casual: return (0.4, 1.4)
        case .list: return (0.6, 1.6)
        case .toSpanish: return (0.8, 1.6)
        case .toEnglish: return (0.6, 1.3)
        }
    }

    /// Lists and translations can legitimately grow; the rest should not.
    var maxTokensFactor: Double { isTranslation || self == .list ? 2.0 : 1.5 }

    /// What scribe.log records; never the utterance. snake_case like VoiceCommand.logName so log greps do not mix styles.
    var logName: String {
        switch self {
        case .shorter: return "shorter"
        case .fixGrammar: return "fix_grammar"
        case .formal: return "formal"
        case .casual: return "casual"
        case .list: return "list"
        case .toSpanish: return "to_spanish"
        case .toEnglish: return "to_english"
        }
    }

    /// Folded (lowercase, no accents, no punctuation) phrases, EN and ES side by side. Whole utterance only.
    static let phrases: [String: EditVerb] = [
        "make it shorter": .shorter, "make this shorter": .shorter, "shorten this": .shorter, "shorten it": .shorter, "shorter": .shorter,
        "mas corto": .shorter, "acortalo": .shorter, "resumelo": .shorter, "hazlo mas corto": .shorter,
        "fix the grammar": .fixGrammar, "fix grammar": .fixGrammar, "fix spelling": .fixGrammar, "fix the spelling": .fixGrammar, "fix it": .fixGrammar,
        "corrige la gramatica": .fixGrammar, "corrigelo": .fixGrammar, "arregla la gramatica": .fixGrammar,
        "make it formal": .formal, "make this formal": .formal, "formal": .formal, "mas formal": .formal, "hazlo formal": .formal,
        "make it casual": .casual, "make this casual": .casual, "casual": .casual, "informal": .casual, "mas informal": .casual, "hazlo informal": .casual,
        "make it a list": .list, "make this a list": .list, "make a list": .list, "bullet points": .list, "as a list": .list,
        "en vinetas": .list, "como lista": .list, "en una lista": .list, "hazlo una lista": .list,
        "translate to spanish": .toSpanish, "to spanish": .toSpanish, "in spanish": .toSpanish,
        "pasalo a espanol": .toSpanish, "pasa esto a espanol": .toSpanish, "en espanol": .toSpanish, "traduce al espanol": .toSpanish, "traducelo al espanol": .toSpanish,
        "translate to english": .toEnglish, "to english": .toEnglish, "in english": .toEnglish,
        "pasa esto a ingles": .toEnglish, "pasalo a ingles": .toEnglish, "en ingles": .toEnglish, "traduce al ingles": .toEnglish, "traducelo al ingles": .toEnglish,
    ]

    /// Tolerates ASR casing, accents and punctuation ("Pásalo a español." → pasalo a espanol). nil for anything else.
    static func match(_ utterance: String) -> EditVerb? {
        phrases[VoiceCommand.fold(utterance)]
    }
}
