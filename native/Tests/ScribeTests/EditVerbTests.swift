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

    func testDisplayNamesAndFlags() {
        XCTAssertEqual(EditVerb.list.displayName, "List")
        XCTAssertEqual(EditVerb.toSpanish.displayName, "To Spanish")
        XCTAssertTrue(EditVerb.list.keepsNewlines)
        XCTAssertFalse(EditVerb.formal.keepsNewlines)
        XCTAssertTrue(EditVerb.toEnglish.isTranslation)
        XCTAssertFalse(EditVerb.casual.isTranslation)
        XCTAssertEqual(EditVerb.allCases.count, 7)
    }

    func testLengthBandsAndTokenFactors() {
        XCTAssertEqual(EditVerb.shorter.lengthBand.low, 0.3); XCTAssertEqual(EditVerb.shorter.lengthBand.high, 0.9)
        XCTAssertEqual(EditVerb.fixGrammar.lengthBand.low, 0.8); XCTAssertEqual(EditVerb.fixGrammar.lengthBand.high, 1.25)
        XCTAssertEqual(EditVerb.toEnglish.lengthBand.high, 1.3)
        XCTAssertEqual(EditVerb.list.maxTokensFactor, 2.0)
        XCTAssertEqual(EditVerb.formal.maxTokensFactor, 1.5)
    }

    func testNoPhraseCollidesWithAVoiceCommand() {
        for phrase in EditVerb.phrases.keys {
            XCTAssertNil(VoiceCommand.match(phrase), phrase)
        }
    }
}
