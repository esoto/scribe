import XCTest

final class EditVerbTests: XCTestCase {
    func testEveryRequiredPhraseMatchesItsVerb() {
        let required: [(String, EditVerb)] = [
            ("make it shorter", .shorter), ("Shorten this.", .shorter), ("más corto", .shorter), ("Acórtalo", .shorter), ("resúmelo", .shorter),
            ("fix the grammar", .fixGrammar), ("fix spelling", .fixGrammar), ("fix it", .fixGrammar), ("corrige la gramática", .fixGrammar), ("corrígelo", .fixGrammar),
            ("make it formal", .formal), ("formal", .formal), ("más formal", .formal), ("hazlo formal", .formal),
            ("make it casual", .casual), ("casual", .casual), ("más informal", .casual), ("hazlo informal", .casual),
            ("make it a list", .list), ("bullet points", .list), ("as a list", .list), ("en viñetas", .list), ("como lista", .list), ("en una lista", .list),
            ("translate to Spanish", .toSpanish), ("in Spanish", .toSpanish), ("pásalo a español", .toSpanish), ("en español", .toSpanish), ("traduce al español", .toSpanish),
            ("translate to English", .toEnglish), ("in English", .toEnglish), ("pasa esto a inglés", .toEnglish), ("en inglés", .toEnglish), ("traduce al inglés", .toEnglish),
        ]
        for (phrase, verb) in required {
            XCTAssertEqual(EditVerb.match(phrase), verb, phrase)
        }
    }

    func testFoldingToleratesCaseAccentsAndPunctuation() {
        XCTAssertEqual(EditVerb.match("  Make It Shorter!  "), .shorter)
        XCTAssertEqual(EditVerb.match("Pásalo a español."), .toSpanish)
    }

    func testOnlyTheWholeUtteranceMatches() {
        XCTAssertNil(EditVerb.match("make it shorter please"))
        XCTAssertNil(EditVerb.match("please make it a list"))
        XCTAssertNil(EditVerb.match("make it longer"))
        XCTAssertNil(EditVerb.match(""))
    }

    func testFlagsAndCaseCount() {
        XCTAssertTrue(EditVerb.list.keepsNewlines)
        XCTAssertFalse(EditVerb.formal.keepsNewlines)
        XCTAssertTrue(EditVerb.toEnglish.isTranslation)
        XCTAssertFalse(EditVerb.casual.isTranslation)
        XCTAssertEqual(EditVerb.allCases.count, 7)
    }

    func testEveryLengthBandBoundIsPinned() {
        let bands: [(EditVerb, Double, Double)] = [
            (.shorter, 0.3, 0.9), (.fixGrammar, 0.8, 1.25), (.formal, 0.7, 1.4), (.casual, 0.35, 1.4),
            (.list, 0.6, 1.6), (.toSpanish, 0.8, 1.6), (.toEnglish, 0.6, 1.3),
        ]
        for (verb, low, high) in bands {
            XCTAssertEqual(verb.lengthBand.low, low, "\(verb) low")
            XCTAssertEqual(verb.lengthBand.high, high, "\(verb) high")
        }
    }

    func testTokenFactors() {
        XCTAssertEqual(EditVerb.list.maxTokensFactor, 2.0)
        XCTAssertEqual(EditVerb.formal.maxTokensFactor, 1.5)
    }

    func testEveryDisplayNameIsThePillCopy() {
        let names: [(EditVerb, String)] = [
            (.shorter, "Shorter"), (.fixGrammar, "Fix grammar"), (.formal, "Formal"), (.casual, "Casual"),
            (.list, "List"), (.toSpanish, "To Spanish"), (.toEnglish, "To English"),
        ]
        for (verb, name) in names { XCTAssertEqual(verb.displayName, name, "\(verb)") }
    }

    func testLogNamesAreSnakeCaseLikeVoiceCommands() {
        let names: [(EditVerb, String)] = [
            (.shorter, "shorter"), (.fixGrammar, "fix_grammar"), (.formal, "formal"), (.casual, "casual"),
            (.list, "list"), (.toSpanish, "to_spanish"), (.toEnglish, "to_english"),
        ]
        for (verb, name) in names { XCTAssertEqual(verb.logName, name, "\(verb)") }
    }

    func testEveryPhraseKeyIsItsOwnFold() {
        for phrase in EditVerb.phrases.keys {
            XCTAssertEqual(VoiceCommand.fold(phrase), phrase, "an unfolded key can never match")
        }
    }

    func testNoPhraseCollidesWithAVoiceCommand() {
        for phrase in EditVerb.phrases.keys {
            XCTAssertNil(VoiceCommand.match(phrase), phrase)
        }
    }
}
