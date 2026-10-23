import XCTest

/// L11: the library's count was a bare number -- "My library 1", and "My
/// library 0" on the screen a new user meets first.
///
/// #39: then it counted an unfiled ARRANGEMENT as a piece, so two unfiled rows
/// read "2 pieces · 2 arrangements" -- the same music counted twice, under a
/// name it does not have, over rows that say UNFILED on their face.
final class LibraryCountTests: XCTestCase {

    private func piece(_ id: String, arrangements: Int = 1) -> LibraryRow {
        LibraryRow(id: id, title: id, subtitle: "unknown · \(arrangements) arrangements",
                   chips: [], meta: "", sortName: id, composer: "", changed: "",
                   arrangementCount: arrangements)
    }

    private func unfiled(_ id: String, versions: Int = 1) -> LibraryRow {
        LibraryRow(id: id, title: id, subtitle: "unknown · \(versions) versions",
                   chips: [.init(text: "UNFILED", kind: .warning)],
                   meta: "", sortName: id, composer: "", changed: "",
                   arrangementCount: 1)
    }

    /// Ali's screenshot: one filed piece and three loose arrangements. Four
    /// rows on screen, and a header that adds up to four.
    func testItCountsTheRowsOnScreenByWhatTheyAre() {
        let phrase = LibraryModel.countPhrase(
            segment: .pieces,
            rows: [piece("sous-le-ciel", arrangements: 2),
                   unfiled("a"), unfiled("b"), unfiled("c")])
        XCTAssertEqual(phrase, "1 piece · 3 unfiled")
    }

    /// The defect itself: an unfiled arrangement is not a piece.
    func testAnUnfiledArrangementIsNeverCountedAsAPiece() {
        XCTAssertEqual(LibraryModel.countPhrase(segment: .pieces,
                                                rows: [unfiled("a", versions: 9),
                                                       unfiled("b", versions: 9)]),
                       "2 unfiled arrangements")
        XCTAssertFalse(LibraryModel.countPhrase(segment: .pieces,
                                                rows: [unfiled("a"), unfiled("b")])
            .contains("piece"))
    }

    func testOnlyPiecesReadsAsPiecesAlone() {
        XCTAssertEqual(LibraryModel.countPhrase(segment: .pieces,
                                                rows: [piece("a"), piece("b")]),
                       "2 pieces")
        XCTAssertEqual(LibraryModel.countPhrase(segment: .pieces, rows: [piece("a")]),
                       "1 piece")
    }

    func testOneUnfiledIsSingular() {
        XCTAssertEqual(LibraryModel.countPhrase(segment: .pieces, rows: [unfiled("a")]),
                       "1 unfiled arrangement")
        XCTAssertEqual(LibraryModel.countPhrase(segment: .pieces,
                                                rows: [piece("a"), unfiled("b")]),
                       "1 piece · 1 unfiled")
    }

    /// Zero is a sentence, not a number: this is the first screen a new user
    /// sees, and "0" tells them nothing about what to do.
    func testAnEmptyLibrarySaysSoInWords() {
        XCTAssertEqual(LibraryModel.countPhrase(segment: .pieces, rows: []),
                       "No pieces yet")
        XCTAssertEqual(LibraryModel.countPhrase(segment: .setlists, rows: []),
                       "No set lists yet")
        for segment in LibrarySegment.allCases {
            XCTAssertFalse(LibraryModel.countPhrase(segment: segment, rows: [])
                .contains("0"), "an empty library still counts in digits")
        }
    }

    func testSetlistsAreCountedAsSetLists() {
        XCTAssertEqual(LibraryModel.countPhrase(segment: .setlists,
                                                rows: [piece("a"), piece("b")]),
                       "2 set lists")
        XCTAssertEqual(LibraryModel.countPhrase(segment: .setlists, rows: [piece("a")]),
                       "1 set list")
    }

    /// The requirement stated as a property: whatever the mix, the numbers in
    /// the header add up to the number of rows under it.
    func testTheHeaderAlwaysAddsUpToTheRowsOnScreen() {
        for pieces in 0...3 {
            for loose in 0...3 where pieces + loose > 0 {
                let rows = (0..<pieces).map { piece("p\($0)", arrangements: 4) }
                    + (0..<loose).map { unfiled("u\($0)", versions: 7) }
                let phrase = LibraryModel.countPhrase(segment: .pieces, rows: rows)
                let numbers = phrase.split(whereSeparator: { !$0.isNumber })
                    .compactMap { Int($0) }
                XCTAssertEqual(numbers.reduce(0, +), rows.count,
                               "\(pieces) pieces + \(loose) unfiled reads "
                               + "\"\(phrase)\" over \(rows.count) rows")
            }
        }
    }

    /// And it never reports a total that is not on screen -- the arrangements
    /// inside a piece are visible when you open it.
    func testItDoesNotCountArrangementsInsidePieces() {
        let phrase = LibraryModel.countPhrase(segment: .pieces,
                                              rows: [piece("a", arrangements: 12)])
        XCTAssertEqual(phrase, "1 piece")
        XCTAssertFalse(phrase.contains("12"))
    }

    func testTheNounIsNeverDropped() {
        for count in [0, 1, 2, 17] {
            XCTAssertTrue(LibraryModel.plural(count, "piece").contains("piece"))
        }
        XCTAssertEqual(LibraryModel.plural(0, "piece"), "0 pieces")
    }

    /// The header and the Unfiled filter read the same signal, so they cannot
    /// disagree about what is unfiled.
    func testUnfiledIsTheSameJudgementTheFilterMakes() {
        XCTAssertTrue(LibraryModel.isUnfiled(unfiled("a")))
        XCTAssertFalse(LibraryModel.isUnfiled(piece("a")))
    }

    /// 2026-10-22: a filter that hides every set list made the header say
    /// there were none. It counts what EXISTS, and how many are shown.
    func testAFilteredSegmentCountsWhatExistsAndWhatIsShown() {
        let three = [piece("a"), piece("b"), piece("c")]
        XCTAssertEqual(LibraryModel.countPhrase(segment: .setlists, rows: [],
                                                existing: three),
                       "3 set lists · 0 shown")
        XCTAssertEqual(LibraryModel.countPhrase(segment: .setlists, rows: [three[0]],
                                                existing: three),
                       "3 set lists · 1 shown")
        XCTAssertEqual(LibraryModel.countPhrase(segment: .pieces, rows: [piece("a")],
                                                existing: [piece("a"), unfiled("b")]),
                       "1 piece · 1 unfiled · 1 shown")
    }

    /// Nothing hidden, nothing added: the phrase is the one it always was.
    func testAnUnfilteredSegmentReadsAsBefore() {
        let two = [piece("a"), piece("b")]
        XCTAssertEqual(LibraryModel.countPhrase(segment: .setlists, rows: two,
                                                existing: two),
                       "2 set lists")
        XCTAssertEqual(LibraryModel.countPhrase(segment: .setlists, rows: [],
                                                existing: []),
                       "No set lists yet")
    }
}
