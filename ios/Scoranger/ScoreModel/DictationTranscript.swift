import Foundation

/// The words of one dictation session, kept across the recogniser's pauses
/// (0.19.1).
///
/// On-device recognition reports ONE UTTERANCE at a time: after a pause of a
/// second or two the next partial result starts again from the new phrase,
/// and `bestTranscription` no longer holds what was said before it. The app
/// mirrored that string into the chat field, so pausing to think replaced the
/// prompt with its last phrase (Ali, 2026-10-10). The finished utterances are
/// kept here and the one in progress is added after them.
///
/// Two signals end an utterance:
///   - the result carries `speechRecognitionMetadata`, which the recogniser
///     attaches when it closes one -- the documented signal;
///   - the text starts over: a result that is SHORTER than the one before and
///     does not begin with the same word. A revision of the phrase in progress
///     keeps its start or grows; a new phrase does neither. This catches a
///     reset the metadata did not announce, and losing a prompt is the worse
///     of the two mistakes it can make.
struct DictationTranscript: Equatable {
    /// Utterances the recogniser has finished with.
    private(set) var committed = ""
    /// The utterance in progress, as last reported.
    private(set) var current = ""
    /// The utterance most recently finished, so a repeat of it -- a final
    /// result delivered after the one that closed it -- is not said twice.
    private var lastFinished = ""

    /// Everything said this session.
    var text: String { Self.join(committed, current) }

    mutating func receive(_ heard: String, utteranceEnded: Bool) {
        if current.isEmpty, !lastFinished.isEmpty, heard == lastFinished { return }
        if Self.startsOver(previous: current, next: heard) {
            finish(current)
        }
        current = heard
        if utteranceEnded {
            finish(current)
        }
    }

    private mutating func finish(_ utterance: String) {
        committed = Self.join(committed, utterance)
        lastFinished = utterance
        current = ""
    }

    private static func startsOver(previous: String, next: String) -> Bool {
        guard !previous.isEmpty, !next.isEmpty, next.count < previous.count else { return false }
        return firstWord(previous) != firstWord(next)
    }

    private static func firstWord(_ s: String) -> String {
        s.split(whereSeparator: \.isWhitespace).first.map { $0.lowercased() } ?? ""
    }

    private static func join(_ a: String, _ b: String) -> String {
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        return a + " " + b
    }
}
