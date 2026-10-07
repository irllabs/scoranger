import XCTest

/// The words and decisions of the Extract screen (0.19.0,
/// design/BOOK_EXTRACT_0.19.md §C).
final class ExtractModelTests: XCTestCase {

    private let pieces = [PieceDoc(slug: "autumn-leaves", name: "Autumn Leaves", arrangements: ["a", "b"])]

    func testNewPieceSaysWhereTheTuneGoes() {
        XCTAssertEqual(ExtractModel.newPieceLine(name: "", pieces: pieces),
                       "A new piece, named after the tune.")
        XCTAssertEqual(ExtractModel.newPieceLine(name: "Blue Bossa", pieces: pieces),
                       "A new piece called “Blue Bossa”.")
        // the engine joins a piece of the same name, so the line says so first
        XCTAssertEqual(ExtractModel.newPieceLine(name: " autumn leaves ", pieces: pieces),
                       "You already have a piece called “Autumn Leaves”, so it goes there.")
    }

    func testWhereTheListCameFrom() {
        let entry = { (e: String?) in BookEntry(id: "x", title: "T", from: 1, to: 1, evidence: e) }
        XCTAssertEqual(ExtractModel.source(of: [entry("bookmark")], saved: false),
                       "From the book's bookmarks")
        XCTAssertEqual(ExtractModel.source(of: [entry("bookmark"), entry("ocr")], saved: false),
                       "From the book's bookmarks and read from its scanned pages")
        XCTAssertEqual(ExtractModel.source(of: [entry(nil)], saved: true), "Your tune list")
    }

    func testButtonsAndTheRangeLine() {
        XCTAssertEqual(ExtractModel.extractTunesTitle(1), "Extract 1 tune")
        XCTAssertEqual(ExtractModel.extractTunesTitle(123, busy: true), "Extracting 123 tunes…")
        XCTAssertEqual(ExtractModel.extractPagesTitle(from: 30, to: 31), "Extract pages 30–31")
        XCTAssertEqual(ExtractModel.extractPagesTitle(from: 30, to: 30), "Extract page 30")
        XCTAssertEqual(ExtractModel.rangeLine(from: nil, to: nil),
                       "Turn to the tune's first page, then press Start.")
        XCTAssertEqual(ExtractModel.rangeLine(from: 30, to: nil), "Now its last page, then End.")
        XCTAssertEqual(ExtractModel.rangeLine(from: 30, to: 31), "Pages 30–31")
        XCTAssertEqual(ExtractModel.rangeLine(from: 30, to: 30), "Page 30")
    }

    /// Start fills the name from a found tune, but never over typed text.
    func testStartFillsTheNameButNeverOverwritesTyping() {
        let tunes = [BookEntry(id: "1", title: "Autumn Leaves", from: 30, to: 31, evidence: nil)]
        XCTAssertEqual(ExtractModel.prefill(at: 30, entries: tunes, current: "", lastFill: nil),
                       "Autumn Leaves")
        XCTAssertNil(ExtractModel.prefill(at: 30, entries: tunes, current: "My title", lastFill: nil))
        XCTAssertEqual(ExtractModel.prefill(at: 30, entries: tunes, current: "Old fill",
                                            lastFill: "Old fill"), "Autumn Leaves")
        XCTAssertNil(ExtractModel.prefill(at: 31, entries: tunes, current: "", lastFill: nil))
    }

    func testAPageSaysWhereItSitsInTheRange() {
        let marks = BookPageMarks(current: 30, span: 30...32)
        XCTAssertEqual(marks.label(page: 30, of: 480), "Page 30 of 480, start of the range")
        XCTAssertEqual(marks.label(page: 31, of: 480), "Page 31 of 480, in the range")
        XCTAssertEqual(marks.label(page: 32, of: 480), "Page 32 of 480, end of the range")
        XCTAssertEqual(marks.label(page: 40, of: 480), "Page 40 of 480")
    }
}
