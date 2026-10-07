import Foundation

/// What the app says when an operation did not happen.
///
/// It exists because forty-odd failures were silent. Every one of them wrote a
/// reason into `AppState.lastError`, whose only reader is the "Render failed"
/// placeholder inside an OPEN score -- so a rename that the engine refused, an
/// export that never produced a file, an Import Book that died on a missing
/// Python module all looked, from the library, exactly like a button that did
/// nothing. The owner reported the last of those as "nothing happens", twice.
///
/// The destination is `AppState.notice`, which `NoticeBar` renders. This type
/// is the sentence-making, kept pure so the tests can reach it: the phrasing,
/// and the two things that make an engine failure fit in a bar -- a traceback
/// is several lines and a `ModuleNotFoundError` can run to hundreds of
/// characters.
enum OperationReport {

    /// Said when the error carries no words of its own. Better than a sentence
    /// that trails off after the colon.
    static let unexplained = "the engine gave no reason"

    /// How much of a reason reaches the bar. A traceback is diagnostic, not
    /// prose; past this the reader has stopped reading and the bar has covered
    /// the score.
    static let reasonLimit = 240

    /// The words an error has for a reader.
    ///
    /// `EngineError` carries the engine's own refusal ("no part named ..."),
    /// which is the useful half; anything else falls back to its description.
    static func reason(_ error: Error) -> String {
        let raw = (error as? EngineError)?.error ?? error.localizedDescription
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // The engine's REFUSALS are ValueErrors written as sentences for the
        // reader ("None of the tunes in this file could be read ..."); the
        // bridge prefixes the class, which is a word for a log. Any other
        // class is kept: it says the engine broke, not that it said no.
        if trimmed.hasPrefix("ValueError: ") {
            trimmed = String(trimmed.dropFirst("ValueError: ".count))
        }
        return trimmed.isEmpty ? unexplained : trimmed
    }

    /// One sentence: the action that did not happen, then why.
    ///
    /// `action` is the verb phrase, given at the call site and written for the
    /// reader rather than named after the op -- "rename that part", not
    /// "rename-part".
    static func failure(_ action: String, reason: String) -> String {
        "Couldn't \(action): \(condense(reason))"
    }

    /// The same, taking the error directly. This is the form AppState uses.
    static func failure(_ action: String, error: Error) -> String {
        failure(action, reason: reason(error))
    }

    /// A reason fit for one line of a bar: one line, bounded, punctuated once.
    private static func condense(_ reason: String) -> String {
        // A Python traceback names the failure on its LAST line; the frames
        // above it are for a log, not for someone holding an iPad.
        let lines = reason.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var text = lines.last ?? reason
        if lines.count > 1, text.count < 8, let longest = lines.max(by: { $0.count < $1.count }) {
            // a last line of "}" or ")" says nothing; take the substantial one
            text = longest
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { text = unexplained }

        if text.count > reasonLimit {
            text = String(text.prefix(reasonLimit)) + "…"
            return text   // an ellipsis is its own ending; no stop after it
        }
        // Exactly one ending. The engine punctuates some messages and not
        // others, and "no such version.." is how that shows.
        if let last = text.last, ".!?".contains(last) { return text }
        return text + "."
    }
}
