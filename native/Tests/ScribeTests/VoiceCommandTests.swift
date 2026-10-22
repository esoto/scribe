import XCTest

final class VoiceCommandTests: XCTestCase {
    func testMatchesWholeUtteranceDespiteAsrPunctuationAndCasing() {
        XCTAssertEqual(VoiceCommand.match("Send it."), .pressReturn)
        XCTAssertEqual(VoiceCommand.match("ENTER"), .pressReturn)
        XCTAssertEqual(VoiceCommand.match("New line"), .newLine)
        XCTAssertEqual(VoiceCommand.match("new paragraph."), .newParagraph)
        XCTAssertEqual(VoiceCommand.match("Scratch that!"), .undo)
    }

    func testMatchesSpanishWithAndWithoutAccents() {
        XCTAssertEqual(VoiceCommand.match("Enviar."), .pressReturn)
        XCTAssertEqual(VoiceCommand.match("Envíalo"), .pressReturn)
        XCTAssertEqual(VoiceCommand.match("nueva línea"), .newLine)
        XCTAssertEqual(VoiceCommand.match("nueva linea"), .newLine)
        XCTAssertEqual(VoiceCommand.match("Nuevo párrafo."), .newParagraph)
        XCTAssertEqual(VoiceCommand.match("¡Borra eso!"), .undo)
    }

    func testNeverMatchesInsideASentence() {
        XCTAssertNil(VoiceCommand.match("please add a new line after the title"))
        XCTAssertNil(VoiceCommand.match("send it to the team tomorrow"))
        XCTAssertNil(VoiceCommand.match("enter the building"))
    }

    func testBareSendIsText() {
        // "Send." is a plausible one-word reply, so only "send it" / "send that" are commands.
        XCTAssertNil(VoiceCommand.match("Send."))
        XCTAssertNil(VoiceCommand.match(""))
    }

    func testFoldCollapsesWhitespaceAndStripsPunctuationAndAccents() {
        XCTAssertEqual(VoiceCommand.fold("  ¿Nueva   línea?  "), "nueva linea")
        XCTAssertEqual(VoiceCommand.fold("new-line"), "new line")
    }

    func testEveryCommandHasAHintAndALogToken() {
        for command in VoiceCommand.allCases {
            XCTAssertFalse(command.hint.isEmpty)
            XCTAssertFalse(command.logName.isEmpty)
            XCTAssertFalse(command.logName.contains(" "))
        }
    }

    func testEveryPhraseInTheTableMatchesItsCommand() {
        let table: [(String, VoiceCommand)] = [
            ("enter", .pressReturn), ("press enter", .pressReturn), ("send it", .pressReturn),
            ("send that", .pressReturn), ("enviar", .pressReturn), ("envíalo", .pressReturn),
            ("mándalo", .pressReturn), ("presiona enter", .pressReturn),
            ("new line", .newLine), ("newline", .newLine), ("line break", .newLine), ("new line break", .newLine),
            ("nueva línea", .newLine), ("línea nueva", .newLine), ("salto de línea", .newLine),
            ("new paragraph", .newParagraph), ("nuevo párrafo", .newParagraph), ("párrafo nuevo", .newParagraph),
            ("scratch that", .undo), ("undo that", .undo), ("undo", .undo),
            ("borra eso", .undo), ("deshacer", .undo), ("deshace eso", .undo),
        ]
        for (phrase, command) in table {
            XCTAssertEqual(VoiceCommand.match(phrase), command, phrase)
        }
    }
}
