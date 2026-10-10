import XCTest

/// Dictation keeps what was said before a pause (0.19.1). Ali: "if i pause
/// for a few seconds the next phrase replaces the last phrase and i lose my
/// prompt up to that point."
final class DictationTranscriptTests: XCTestCase {

    func testPartialResultsRefineOneUtterance() {
        var t = DictationTranscript()
        t.receive("drop", utteranceEnded: false)
        t.receive("drop the", utteranceEnded: false)
        t.receive("drop the piano", utteranceEnded: false)
        XCTAssertEqual(t.text, "drop the piano")
    }

    /// The recogniser announces the end of an utterance and starts the next
    /// phrase from nothing.
    func testAPauseTheRecogniserAnnouncesKeepsTheFirstPhrase() {
        var t = DictationTranscript()
        t.receive("drop the piano", utteranceEnded: false)
        t.receive("drop the piano", utteranceEnded: true)
        t.receive("and", utteranceEnded: false)
        t.receive("and transpose up", utteranceEnded: false)
        XCTAssertEqual(t.text, "drop the piano and transpose up")
    }

    /// The text starts over with no announcement: shorter, a different first word.
    func testAPauseItDoesNotAnnounceStillKeepsTheFirstPhrase() {
        var t = DictationTranscript()
        t.receive("drop the piano", utteranceEnded: false)
        t.receive("then", utteranceEnded: false)
        t.receive("then transpose it up a tone", utteranceEnded: false)
        XCTAssertEqual(t.text, "drop the piano then transpose it up a tone")
    }

    /// A revision that shortens the phrase but keeps its start is a revision.
    func testARevisionIsNotANewPhrase() {
        var t = DictationTranscript()
        t.receive("give the cello line to a viola", utteranceEnded: false)
        t.receive("give the cello line", utteranceEnded: false)
        XCTAssertEqual(t.text, "give the cello line")
    }

    /// A final result repeating the utterance that was just closed is said once.
    func testAClosedUtteranceRepeatedIsNotDoubled() {
        var t = DictationTranscript()
        t.receive("drop the piano", utteranceEnded: true)
        t.receive("drop the piano", utteranceEnded: true)
        XCTAssertEqual(t.text, "drop the piano")
        t.receive("now the flute", utteranceEnded: false)
        XCTAssertEqual(t.text, "drop the piano now the flute")
    }

    func testThreePhrases() {
        var t = DictationTranscript()
        t.receive("one", utteranceEnded: true)
        t.receive("two", utteranceEnded: true)
        t.receive("three", utteranceEnded: false)
        XCTAssertEqual(t.text, "one two three")
    }
}
