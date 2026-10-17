import XCTest

/// A file of many tunes imports what it can and names the rest (0.19.0).
final class ImportReportTests: XCTestCase {

    func testNothingToSayWhenEveryTuneImported() {
        XCTAssertNil(ImportReport.notice(from: ["score": "a", "arrangements": [1, 2],
                                                "abc": ["decorations_carried": 4]]))
        XCTAssertNil(ImportReport.notice(from: ["score": "a"]))
    }

    func testSkippedTunesAreNamed() {
        let one = ImportReport.notice(from: [
            "arrangements": Array(repeating: 0, count: 29),
            "abc": ["tunes_skipped": [["title": "The Wind That Shakes The Barley",
                                       "reason": "Bad chord indicator"]]]])
        XCTAssertEqual(one, "Imported 29 of 30 tunes. This one could not be read: "
                       + "The Wind That Shakes The Barley.")
        let many = ImportReport.notice(from: [
            "arrangements": [0],
            "abc": ["tunes_skipped": ["A", "B", "C", "D", "E"].map { ["title": $0] }]])
        XCTAssertEqual(many, "Imported 1 of 6 tunes. These could not be read: "
                       + "A, B, C and 2 more.")
    }

    /// ABC words that could not be proved to belong to their notes are named
    /// (0.21.0), alongside anything else the import has to say.
    func testWithheldWordsAreNamed() {
        let said = ImportReport.notice(from: [
            "arrangements": [0],
            "abc": ["lyrics_carried": 12,
                    "lyrics_withheld": [["title": "Two Voices", "reason": "several voices"]]]])
        XCTAssertEqual(said, "The words of Two Voices could not be placed on their notes "
                       + "and were left off.")
    }

    /// A transcription imported with its PDF says what the PDF corrected.
    func testATextPassIsRelayed() {
        let said = ImportReport.notice(from: [
            "arrangements": [0],
            "text_pass": ["pages_lined_up": 1, "text_layer": true, "syllables": 98,
                          "chords": 23, "text_below_music": ["a", "b", "c"]]])
        XCTAssertEqual(said, "Words and chord names are as the PDF prints them: 98 syllables "
                       + "and 23 chords. 3 lines printed below the music are not lyrics "
                       + "and were left off.")
    }
}

/// What a transcription of a PDF tells the reader (0.21.0, pdftext).
final class TextPassReportTests: XCTestCase {

    func testNothingToSay() {
        XCTAssertNil(TextPassReport.notice(from: nil))
        XCTAssertNil(TextPassReport.notice(from: ["text_layer": false, "pages_lined_up": 0]))
    }

    func testAFailedPassKeepsTheScannersReading() {
        XCTAssertEqual(TextPassReport.notice(from: ["failed": "ValueError: x"]),
                       "The PDF's printed words could not be read, so the words and chords "
                       + "are as the scanner read them.")
    }

    func testAPageThatDidNotLineUp() {
        XCTAssertEqual(TextPassReport.notice(from: ["text_layer": true, "pages_lined_up": 0,
                                                    "text_below_music": ["one"]]),
                       "The PDF's printed words did not line up with the music, so the words "
                       + "are as the scanner read them. 1 line printed below the music is not "
                       + "a lyric and was left off.")
    }

    func testOneOfEach() {
        XCTAssertEqual(TextPassReport.notice(from: ["text_layer": true, "pages_lined_up": 1,
                                                    "syllables": 1, "chords": 1]),
                       "Words and chord names are as the PDF prints them: 1 syllable and 1 chord.")
    }
}
