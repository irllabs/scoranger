import CoreGraphics
import XCTest

/// The gesture arbitration from NAVIGATION_SYSTEM.md §6 -- one case per cell of
/// the table, because §9.3 is right that this is where regressions will be.
///
/// The thing being protected: the Pencil lasso. It selects music for chat, and
/// it is the same gesture as a page turn. These tests exist so that "the Pencil
/// turns pages" can never quietly become "the Pencil stopped selecting".
final class PageTurnTests: XCTestCase {

    // MARK: - The Pencil means one thing per mode

    func testThePencilStillLassosInReadMode() {
        XCTAssertFalse(PageTurn.mayTurn(isPencil: true, mode: .read),
                       "a Pencil swipe in read mode is a lasso and must stay one")
    }

    func testThePencilStillInksInEditMode() {
        XCTAssertFalse(PageTurn.mayTurn(isPencil: true, mode: .edit),
                       "a Pencil swipe in edit mode is ink")
    }

    func testThePencilTurnsOnlyInPerformanceMode() {
        XCTAssertTrue(PageTurn.mayTurn(isPencil: true, mode: .performance))
    }

    /// A finger neither selects nor inks, so its tap was free in every mode --
    /// a single-finger tap on the page did nothing at all before this.
    func testAFingerTapTurnsInEveryMode() {
        for mode in ScoreMode.allCases {
            XCTAssertTrue(PageTurn.mayTurn(isPencil: false, mode: mode),
                          "a finger tap should turn in \(mode)")
        }
    }

    // MARK: - A tap is still and quick, or it is a pan

    func testASlowPanNeverTurnsThePage() {
        XCTAssertFalse(PageTurn.isTap(movement: 120, elapsed: 0.2),
                       "movement means the reader is scrolling")
        XCTAssertNil(PageTurn.turn(isPencil: false, mode: .read, x: 30, width: 1000,
                                   movement: 120, elapsed: 0.2))
    }

    func testALongPressIsNotATap() {
        XCTAssertFalse(PageTurn.isTap(movement: 0, elapsed: 1.2))
    }

    func testAStillQuickTouchIsATap() {
        XCTAssertTrue(PageTurn.isTap(movement: PageTurn.tapSlop - 1,
                                     elapsed: PageTurn.tapWindow - 0.05))
    }

    // MARK: - Zones

    func testTheLeadingEdgeGoesBack() {
        XCTAssertEqual(PageTurn.zone(atX: 20, width: 1000), .previous)
    }

    func testTheTrailingEdgeGoesForward() {
        XCTAssertEqual(PageTurn.zone(atX: 980, width: 1000), .next)
    }

    func testTheMiddleOfTheScoreTurnsNothing() {
        XCTAssertEqual(PageTurn.zone(atX: 500, width: 1000), .centre)
        XCTAssertNil(PageTurn.turn(isPencil: false, mode: .read, x: 500, width: 1000,
                                   movement: 0, elapsed: 0.1),
                     "the music itself must not be a button")
    }

    func testTheZonesAreAThumbsReachAndNoMore() {
        // wide enough to hit without looking, narrow enough to leave the music
        XCTAssertGreaterThanOrEqual(PageTurn.zoneFraction, 0.15)
        XCTAssertLessThanOrEqual(PageTurn.zoneFraction, 0.25)
    }

    func testAZerroWidthCanvasTurnsNothing() {
        XCTAssertEqual(PageTurn.zone(atX: 0, width: 0), .centre)
    }

    // MARK: - The whole decision, one case per cell

    func testAPencilTapInPerformanceTurns() {
        XCTAssertEqual(PageTurn.turn(isPencil: true, mode: .performance, x: 950,
                                     width: 1000, movement: 2, elapsed: 0.1), .next)
    }

    func testAPencilTapInReadModeTurnsNothing() {
        // it is an add-or-drop on the selection, and must reach that path
        XCTAssertNil(PageTurn.turn(isPencil: true, mode: .read, x: 950, width: 1000,
                                   movement: 2, elapsed: 0.1))
    }

    func testAFingerTapAtTheEdgeTurnsEvenInEditMode() {
        XCTAssertEqual(PageTurn.turn(isPencil: false, mode: .edit, x: 10, width: 1000,
                                     movement: 1, elapsed: 0.1), .previous)
    }

    // The boundary-arithmetic tests went with `destination`: a turn changes an
    // index now, and PagedCanvasTests covers the stepping. What stays here is
    // the arbitration table, which is what protects the lasso.

    /// E (0.8.0 build 196): the back turn is the mirror of the forward one.
    func testTheSlideReversesForABackTurn() {
        let forward = PageTurn.slideEdges(forward: true)
        let back = PageTurn.slideEdges(forward: false)
        XCTAssertEqual(forward.enters, .trailing, "forward, the new page comes in from the right")
        XCTAssertEqual(forward.leaves, .leading)
        XCTAssertEqual(back.enters, .leading, "back, the new page comes in from the left")
        XCTAssertEqual(back.leaves, .trailing)
        XCTAssertNotEqual(forward.enters, back.enters, "the two turns must not slide the same way")
    }

    /// 0.23.4 (Ali, Espresso on build 219): a back turn after a forward one
    /// slid the old page out to the LEFT. The leaving page animates with the
    /// direction it was last built with, so a reversal changes the direction
    /// first and draws the new index only after.
    func testAReversalChangesDirectionBeforeTheIndex() {
        XCTAssertEqual(PageTurn.nextCanvasStep(drawing: 1, to: 0, lastForward: true),
                       .reverse(forward: false),
                       "back after forward: the leaving page must be rebuilt to leave rightwards first")
        XCTAssertEqual(PageTurn.nextCanvasStep(drawing: 0, to: 1, lastForward: false),
                       .reverse(forward: true))
    }

    func testATurnTheSameWayAsTheLastIsDrawnAtOnce() {
        XCTAssertEqual(PageTurn.nextCanvasStep(drawing: 0, to: 1, lastForward: true), .show(1))
        XCTAssertEqual(PageTurn.nextCanvasStep(drawing: 3, to: 1, lastForward: false), .show(1))
        XCTAssertEqual(PageTurn.nextCanvasStep(drawing: 2, to: 2, lastForward: true), .none)
    }
}
