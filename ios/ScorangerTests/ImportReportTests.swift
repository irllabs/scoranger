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
                                                    "pages_misaligned": 1,
                                                    "text_below_music": ["one"]]),
                       "The PDF's printed words did not line up with the music, so the words "
                       + "are as the scanner read them. 1 line printed below the music is not "
                       + "a lyric and was left off.")
    }

    /// The Cat's Meow (0.23.2): the PDF's text layer held its header and no
    /// words, and the reader was told the printed words did not line up.
    func testATextLayerWithNoWordsUnderTheMusicSaysNothing() {
        XCTAssertNil(TextPassReport.notice(from: ["text_layer": true, "pages_lined_up": 0,
                                                  "pages_misaligned": 0]))
    }

    func testOneOfEach() {
        XCTAssertEqual(TextPassReport.notice(from: ["text_layer": true, "pages_lined_up": 1,
                                                    "syllables": 1, "chords": 1]),
                       "Words and chord names are as the PDF prints them: 1 syllable and 1 chord.")
    }
}

/// After a search import the reader is told which piece the settings joined
/// (0.22.0): one setting added to a piece of 27 is "now has 28", not a
/// mystery 28 arrangements.
final class SearchImportSentenceTests: XCTestCase {

    private func manifest(arrangements: [String]) -> Manifest {
        Manifest(generated: nil, scores: [],
                 pieces: [PieceDoc(slug: "the-irish-washerwoman", name: "The Irish Washerwoman",
                                   arrangements: arrangements)],
                 setlists: nil, books: nil)
    }

    func testANewPieceIsNamed() {
        XCTAssertEqual(SearchImport.sentence(count: 2, slug: "a",
                                             manifest: manifest(arrangements: ["a", "b"])),
                       "Imported 2 settings as the piece The Irish Washerwoman.")
    }

    func testJoiningAPieceSaysHowManyItNowHas() {
        let held = (1...27).map { "w\($0)" } + ["new"]
        XCTAssertEqual(SearchImport.sentence(count: 1, slug: "new",
                                             manifest: manifest(arrangements: held)),
                       "Added 1 setting to The Irish Washerwoman, which now has 28 arrangements.")
    }

    func testNoManifestStillSaysWhatHappened() {
        XCTAssertEqual(SearchImport.sentence(count: 3, slug: "x", manifest: nil),
                       "Imported 3 settings.")
    }
}
