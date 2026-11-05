import Foundation

/// Codable mirror of `tests_models/edit.json` / `edit_guard.json` (snake_case on disk). Not a `GoldenCase`: an edit
/// case carries the spoken verb, and its text is the SELECTION, which `EditGates` needs to judge the result.
struct EditCase: Codable {
    let id: String
    /// `EditVerb.rawValue` ("fixGrammar", not the log name). Kept a String so one typo fails that case and is caught by
    /// `GoldenSetTests`, instead of making the whole file undecodable.
    let verb: String
    /// The selection the model is asked to edit.
    let text: String
    let mustContain: [String]
    let mustNotContain: [String]
    /// Case-SENSITIVE forbidden phrases. The ordinary checks lowercase everything, so they cannot see a model
    /// capitalising a selection word into a name ("rose" -> "Rose"), which gate 5 deliberately allows.
    let mustNotContainCased: [String]?
    let comment: String?
    /// Model ids allowed to fail this case (reported, not asserted). Only ever set with the user's sign-off; the
    /// default model may never be listed.
    let knownFailures: [String]?

    enum CodingKeys: String, CodingKey {
        case id, verb, text, comment
        case mustContain = "must_contain"
        case mustNotContain = "must_not_contain"
        case mustNotContainCased = "must_not_contain_cased"
        case knownFailures = "known_failures"
    }

    var editVerb: EditVerb? { EditVerb(rawValue: verb) }
}

struct EditCaseSet: Codable {
    let description: String?
    let cases: [EditCase]
}

func loadEditSet(_ file: String) throws -> EditCaseSet {
    let data = try Data(contentsOf: repoRoot().appendingPathComponent("tests_models/\(file)"))
    return try JSONDecoder().decode(EditCaseSet.self, from: data)
}

typealias EditEvaluation = (verdict: EditVerdict, missing: [String], present: [String])

/// The ONE pass/fail rule for an edit or edit-guard case. Pure, so `ScribeTests` can prove it fails when it should.
///
/// The output goes through `EditGates.accept` first, exactly as production does: a rejection pastes nothing, so it
/// fails the case, and there is no accepted text to run the phrase checks on (both lists stay empty). On acceptance,
/// every phrase is lowercase-compared against the accepted text, except phrases containing a newline, which read the
/// RAW output: the gates collapse whitespace (a list keeps its lines), so a "\n\n" in `must_not_contain` could never
/// match the accepted text and the check would be vacuous. `must_not_contain_cased` is matched as written.
func evaluateEditCase(_ testCase: EditCase, rawOutput: String) -> EditEvaluation {
    guard let verb = testCase.editVerb else {
        return (.rejected(.empty), ["a known verb (got \(testCase.verb))"], [])
    }
    let verdict = EditGates.accept(verb: verb, selection: testCase.text, result: rawOutput)
    guard case .accepted(let accepted) = verdict else { return (verdict, [], []) }
    let acceptedLow = accepted.lowercased()
    let rawLow = rawOutput.lowercased()
    func found(_ phrase: String) -> Bool {
        let p = phrase.lowercased()
        return (p.contains("\n") ? rawLow : acceptedLow).contains(p)
    }
    let missing = testCase.mustContain.filter { !found($0) }
    let present = testCase.mustNotContain.filter(found) + (testCase.mustNotContainCased ?? []).filter { accepted.contains($0) }
    return (verdict, missing, present)
}

/// A case passes only when the gates accepted the output AND every phrase check is clean.
func editCasePassed(_ evaluation: EditEvaluation) -> Bool {
    guard case .accepted = evaluation.verdict else { return false }
    return evaluation.missing.isEmpty && evaluation.present.isEmpty
}
