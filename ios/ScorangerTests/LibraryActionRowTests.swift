import CoreGraphics
import XCTest

/// §4C: Home is gone and its four actions move into My Library as a compact
/// row. What can be checked without a screen is the row's contract -- what is
/// in it, in what order, under which identifiers, and when Ask can be used.
final class LibraryActionRowTests: XCTestCase {

    /// The five ways in: a file, a photograph, a whole exported folder, a
    /// book to take arrangements out of, and -- 0.20.0 -- a search.
    ///
    /// The two creations left with the New band in 0.8.2 (item 13). `+ New`
    /// makes the thing the segment is showing rather than offering a list, so
    /// there is nothing for a quick action to carry.
    func testTheRowCarriesEveryActionInThePanelsOldOrder() {
        XCTAssertEqual(LibraryQuickAction.ordered,
                       [.importScore, .importPhotos, .importFolder,
                        .importBook, .search])
        XCTAssertEqual(LibraryQuickAction.ordered.count,
                       LibraryQuickAction.allCases.count,
                       "an action exists that the row does not show")
    }

    /// The ids move with the actions; `home-*` and `library-add` retire.
    ///
    /// Three of the four kept the identifier they had -- §14.3 says so in
    /// terms. `importScore` had to change: it was `library-import`, which is
    /// now the VERB button on the row. Two elements under one identifier is a
    /// test that taps whichever SwiftUI listed first.
    func testTheIdentifiersAreTheLibrarysNotHomes() {
        XCTAssertEqual(LibraryQuickAction.ordered.map(\.identifier),
                       ["library-import-score", "library-import-photos",
                        "library-import-folder", "library-import-book",
                        "library-import-search"])
        XCTAssertFalse(LibraryQuickAction.allCases
            .contains { $0.identifier.hasPrefix("home-") })
    }

    /// And no action shares an identifier with the verb that opens its band,
    /// which is the collision the rename above exists to prevent.
    func testNoActionCollidesWithItsVerb() {
        let verbs = Set(LibraryVerb.allCases.map(\.identifier))
        for action in LibraryQuickAction.allCases {
            XCTAssertFalse(verbs.contains(action.identifier),
                           "\(action) shares \(action.identifier) with a verb "
                           + "button, so a test cannot say which it tapped")
        }
        XCTAssertEqual(Set(LibraryQuickAction.allCases.map(\.identifier)).count,
                       LibraryQuickAction.allCases.count,
                       "two actions share an identifier")
    }

    func testEveryActionHasAGlyphAndAShortLabel() {
        for action in LibraryQuickAction.allCases {
            XCTAssertFalse(action.glyph.isEmpty, "\(action) has no glyph")
            XCTAssertFalse(action.title.isEmpty, "\(action) has no title")
            XCTAssertLessThanOrEqual(action.title.count, 12,
                                     "\(action)'s label is too long for a 32pt button")
        }
    }

    // MARK: the row's measurements (§4C)

    func testTheRowIsCompactOnANarrowScreenAndNotOnAWideOne() {
        XCTAssertTrue(LibraryActionRow.isCompact(width: 390))   // iPhone
        XCTAssertTrue(LibraryActionRow.isCompact(width: 699))
        XCTAssertFalse(LibraryActionRow.isCompact(width: 700))
        XCTAssertFalse(LibraryActionRow.isCompact(width: 1024)) // iPad
    }

    /// A width of zero is a view that has not been measured yet. It must not
    /// read as "very narrow" and flip the row to icons for one frame.
    func testAnUnmeasuredWidthIsNotTreatedAsNarrow() {
        XCTAssertFalse(LibraryActionRow.isCompact(width: 0))
    }

    func testTheButtonsFitTheRowWithRoomAboveAndBelow() {
        XCTAssertEqual(LibraryActionRow.height, 44)
        XCTAssertEqual(LibraryActionRow.buttonHeight, 32)
        XCTAssertEqual((LibraryActionRow.height - LibraryActionRow.buttonHeight) / 2, 6,
                       "6pt above and below, per the spec")
    }

    /// The buttons line up with the list rows' thumbnails, which is the whole
    /// reason the side padding is stated rather than chosen.
    func testItLinesUpWithTheListRows() {
        XCTAssertEqual(LibraryActionRow.sidePadding, Theme.Metric.s20)
    }

    func testTheClustersAreHeldFurtherApartThanTheirOwnButtons() {
        XCTAssertGreaterThan(LibraryActionRow.clusterGap, LibraryActionRow.gap)
    }

    // The Ask tests went with Ask (#47). It was removed from the library
    // action row -- the score's own Ask is where a question about an
    // arrangement belongs -- and `LastOpened`, which existed only to give it
    // something to open, went with it.
}
