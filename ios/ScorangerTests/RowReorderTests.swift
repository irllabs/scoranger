import XCTest

/// Dragging a row by its ☰ (`RowReorder`) and swiping one open to its trash
/// button (`RowSwipe`): where the row lands, where its neighbours stand while
/// it is held, and when a movement is a swipe rather than a scroll.
final class RowReorderTests: XCTestCase {

    private let even: [CGFloat] = [64, 64, 64, 64]

    // MARK: - Picking a row up

    func testARowThatIsNotThereCannotBePickedUp() {
        XCTAssertNil(RowReorder(heights: even, from: 4))
        XCTAssertNil(RowReorder(heights: even, from: -1))
        XCTAssertNil(RowReorder(heights: [], from: 0))
    }

    /// Before the rows are measured every height is 0, and every neighbour's
    /// middle is then the top of the list: the first point of movement would
    /// carry the row to the end.
    func testAListThatHasNotBeenMeasuredCannotBePickedUp() {
        XCTAssertNil(RowReorder(heights: [64, 0, 64], from: 0))
    }

    // MARK: - Where it lands

    func testStandingStillLandsWhereItStarted() {
        let r = RowReorder(heights: even, from: 1)!
        XCTAssertEqual(r.landing(translation: 0), 1)
    }

    /// Half a row of travel passes one neighbour, either way, and not less.
    func testHalfARowPassesANeighbour() {
        let r = RowReorder(heights: even, from: 1)!
        XCTAssertEqual(r.landing(translation: 31), 1, "under half a row moved it")
        XCTAssertEqual(r.landing(translation: 33), 2, "over half a row did not")
        XCTAssertEqual(r.landing(translation: -31), 1)
        XCTAssertEqual(r.landing(translation: -33), 0)
    }

    func testFirstToLast() {
        let r = RowReorder(heights: even, from: 0)!
        // centre of the first row to the centre of the last: three rows down
        XCTAssertEqual(r.landing(translation: 3 * 64), 3)
    }

    func testLastToFirst() {
        let r = RowReorder(heights: even, from: 3)!
        XCTAssertEqual(r.landing(translation: -3 * 64), 0)
    }

    /// A finger dragged past either end of the list leaves the row in the
    /// end slot, not off the list.
    func testTravelStopsAtTheEndsOfTheList() {
        let r = RowReorder(heights: even, from: 1)!
        XCTAssertEqual(r.landing(translation: 10_000), 3)
        XCTAssertEqual(r.landing(translation: -10_000), 0)
        XCTAssertEqual(r.clamped(10_000), 2 * 64, "the held row ran past the last slot")
        XCTAssertEqual(r.clamped(-10_000), -64, "the held row ran past the first slot")
    }

    /// Rows of different heights -- a row whose name wraps at a large text
    /// size -- are passed by their own middle, not by an average row.
    func testRowsOfDifferentHeightsArePassedAtTheirOwnMiddle() {
        let r = RowReorder(heights: [64, 120, 64], from: 0)!
        // The held row's bottom edge starts at 64; the tall row's middle is at
        // 64 + 60 = 124.
        XCTAssertEqual(r.landing(translation: 59), 0)
        XCTAssertEqual(r.landing(translation: 61), 1)
        // and the short row under it, whose middle is at 184 + 32 = 216
        XCTAssertEqual(r.landing(translation: 151), 1)
        XCTAssertEqual(r.landing(translation: 153), 2)
    }

    // MARK: - The neighbours make room

    func testMovingDownTheRowsPassedStepUpByTheHeldRowsHeight() {
        let r = RowReorder(heights: [80, 64, 64, 64], from: 0)!
        XCTAssertEqual(r.displacement(ofRow: 1, landing: 2), -80)
        XCTAssertEqual(r.displacement(ofRow: 2, landing: 2), -80)
        XCTAssertEqual(r.displacement(ofRow: 3, landing: 2), 0, "a row not passed moved")
        XCTAssertEqual(r.displacement(ofRow: 0, landing: 2), 0,
                       "the held row follows the finger, not this")
    }

    func testMovingUpTheRowsPassedStepDown() {
        let r = RowReorder(heights: even, from: 3)!
        XCTAssertEqual(r.displacement(ofRow: 0, landing: 1), 0)
        XCTAssertEqual(r.displacement(ofRow: 1, landing: 1), 64)
        XCTAssertEqual(r.displacement(ofRow: 2, landing: 1), 64)
    }

    func testNothingMovesWhileTheRowIsOverItsOwnSlot() {
        let r = RowReorder(heights: even, from: 2)!
        for i in 0..<4 { XCTAssertEqual(r.displacement(ofRow: i, landing: 2), 0) }
    }

    /// The slot a row lands in is where the rows that stepped aside left room:
    /// the held row's offset to it equals the room they made.
    func testTheSlotIsTheRoomTheNeighboursMade() {
        let r = RowReorder(heights: [64, 90, 64, 70], from: 1)!
        XCTAssertEqual(r.slotOffset(3), 64 + 70)
        XCTAssertEqual(r.slotOffset(0), -64)
        XCTAssertEqual(r.slotOffset(1), 0)
        XCTAssertEqual(r.landing(translation: r.slotOffset(3)), 3)
        XCTAssertEqual(r.landing(translation: r.slotOffset(0)), 0)
    }

    // MARK: - The order that is committed

    func testMovingAnItemKeepsEverythingElseInOrder() {
        XCTAssertEqual(RowReorder.moving(["a", "b", "c", "d"], from: 0, to: 3), ["b", "c", "d", "a"])
        XCTAssertEqual(RowReorder.moving(["a", "b", "c", "d"], from: 3, to: 0), ["d", "a", "b", "c"])
        XCTAssertEqual(RowReorder.moving(["a", "b", "c", "d"], from: 1, to: 2), ["a", "c", "b", "d"])
    }

    func testAMoveToItsOwnPlaceOrOffTheListChangesNothing() {
        XCTAssertEqual(RowReorder.moving(["a", "b"], from: 1, to: 1), ["a", "b"])
        XCTAssertEqual(RowReorder.moving(["a", "b"], from: 0, to: 5), ["a", "b"])
    }

    /// The whole drag, as the list performs it: pick up, travel, land, commit.
    func testADragFromFirstToLastCommitsThatOrder() {
        let items = ["quartet", "solo", "trio"]
        let r = RowReorder(heights: [64, 64, 64], from: 0)!
        let to = r.landing(translation: 140)
        XCTAssertEqual(RowReorder.moving(items, from: r.from, to: to), ["solo", "trio", "quartet"])
    }

    // MARK: - Swiping to the trash button

    func testAShortMovementDecidesNothing() {
        XCTAssertNil(RowSwipe.axis(dx: -6, dy: 2))
    }

    func testASidewaysMovementIsASwipe() {
        XCTAssertEqual(RowSwipe.axis(dx: -20, dy: 4), .horizontal)
        XCTAssertEqual(RowSwipe.axis(dx: 20, dy: -4), .horizontal)
    }

    /// A finger scrolling the page drifts sideways. A diagonal is a scroll, so
    /// scrolling never twitches a row open.
    func testADiagonalIsAScroll() {
        XCTAssertEqual(RowSwipe.axis(dx: -14, dy: 12), .vertical)
        XCTAssertEqual(RowSwipe.axis(dx: 2, dy: 30), .vertical)
    }

    /// UIKit begins a pan after a few points: too short for `axis`, so the
    /// finger's speed decides, by the same dominance.
    func testAPanTooShortToMeasureIsJudgedByItsSpeed() {
        XCTAssertTrue(RowSwipe.isSideways(translation: CGSize(width: -4, height: 1),
                                          velocity: CGSize(width: -600, height: 80)))
        XCTAssertFalse(RowSwipe.isSideways(translation: CGSize(width: -3, height: 4),
                                           velocity: CGSize(width: -200, height: 500)),
                       "a scroll that drifts sideways began a swipe")
    }

    /// Once the movement is long enough to say, it is the movement that says.
    func testAPanLongEnoughToMeasureIsJudgedByItsMovement() {
        XCTAssertFalse(RowSwipe.isSideways(translation: CGSize(width: -4, height: 20),
                                           velocity: CGSize(width: -900, height: 10)))
        XCTAssertTrue(RowSwipe.isSideways(translation: CGSize(width: -20, height: 3),
                                          velocity: .zero))
    }

    /// A flick opens a row a slow drag of the same length would not, and a
    /// flick back closes an open one.
    func testAFlickCarriesTheRow() {
        let short: CGFloat = -30
        XCTAssertFalse(RowSwipe.restsOpen(predicted: RowSwipe.offset(
            start: 0, dx: RowSwipe.projected(dx: short, velocity: 0))))
        XCTAssertTrue(RowSwipe.restsOpen(predicted: RowSwipe.offset(
            start: 0, dx: RowSwipe.projected(dx: short, velocity: -600))))
        XCTAssertFalse(RowSwipe.restsOpen(predicted: RowSwipe.offset(
            start: -RowSwipe.revealWidth, dx: RowSwipe.projected(dx: 20, velocity: 600))))
    }

    func testAClosedRowDoesNotSlideRight() {
        XCTAssertEqual(RowSwipe.offset(start: 0, dx: 40), 0)
    }

    func testTheRowFollowsTheFingerUpToTheButtonsWidth() {
        XCTAssertEqual(RowSwipe.offset(start: 0, dx: -50), -50)
        XCTAssertEqual(RowSwipe.offset(start: 0, dx: -RowSwipe.revealWidth), -RowSwipe.revealWidth)
    }

    func testPastTheButtonTheRowResists() {
        let far = RowSwipe.offset(start: 0, dx: -RowSwipe.revealWidth - 100)
        XCTAssertLessThan(far, -RowSwipe.revealWidth)
        XCTAssertGreaterThan(far, -RowSwipe.revealWidth - 100, "no resistance past the button")
    }

    func testAnOpenRowSwipedRightClosesAndGoesNoFurther() {
        XCTAssertEqual(RowSwipe.offset(start: -RowSwipe.revealWidth, dx: 40),
                       -RowSwipe.revealWidth + 40)
        XCTAssertEqual(RowSwipe.offset(start: -RowSwipe.revealWidth, dx: 400), 0)
    }

    func testItRestsOpenPastHalfTheButton() {
        XCTAssertTrue(RowSwipe.restsOpen(predicted: -RowSwipe.revealWidth / 2 - 1))
        XCTAssertFalse(RowSwipe.restsOpen(predicted: -RowSwipe.revealWidth / 2 + 1))
        XCTAssertFalse(RowSwipe.restsOpen(predicted: 0))
    }

    /// The button is a target, not a sliver: at least a hit target wide.
    func testTheRevealedButtonIsAtLeastAHitTargetWide() {
        XCTAssertGreaterThanOrEqual(RowSwipe.revealWidth, Theme.Metric.hitTarget)
    }
}
