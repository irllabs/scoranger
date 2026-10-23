import CoreGraphics
import XCTest

/// What the counters say (NAVIGATION_SYSTEM.md 12.11).
///
/// §7 expected `bar N` to wait on a parallel session for the geometry layer. It
/// did not have to: ScoreGeometry is already here and every element carries the
/// measure it belongs to, so the counter ships for real rather than as pages
/// alone.
final class ScorePositionTests: XCTestCase {

    // MARK: - Pages

    func testASinglePageReadsAsOne() {
        XCTAssertEqual(ScorePosition.pageLabel(visible: [2], total: 12), "p. 3 / 12")
    }

    func testASpreadReadsAsARange() {
        XCTAssertEqual(ScorePosition.pageLabel(visible: [2, 3], total: 12), "pp. 3–4 / 12")
    }

    /// Page indices are zero-based inside the app and one-based to a reader.
    /// Getting that wrong is off-by-one in the most visible place there is.
    func testTheFirstPageIsPageOneNotPageZero() {
        XCTAssertEqual(ScorePosition.pageLabel(visible: [0], total: 12), "p. 1 / 12")
    }

    func testNothingVisibleSaysNothing() {
        XCTAssertEqual(ScorePosition.pageLabel(visible: [], total: 12), "")
    }

    func testAnEmptyDocumentSaysNothing() {
        XCTAssertEqual(ScorePosition.pageLabel(visible: [0], total: 0), "")
    }

    /// First pages laid out ahead of the rest: the length is not known, and
    /// the counter does not make one up.
    func testAnUnknownLengthIsNotCounted() {
        XCTAssertEqual(ScorePosition.pageLabel(visible: [0], total: nil), "p. 1")
        XCTAssertEqual(ScorePosition.pageLabel(visible: [0, 1], total: nil), "pp. 1–2")
        XCTAssertEqual(ScorePosition.pageLabel(visible: [], total: nil), "")
    }

    // MARK: - Which pages are on screen

    private let bands: [(index: Int, span: ClosedRange<CGFloat>)] = [
        (0, 0...800), (1, 812...1612), (2, 1624...2424),
    ]

    func testThePageUnderTheViewportIsVisible() {
        XCTAssertEqual(ScorePosition.visiblePages(bands: bands,
                                                  visible: CGRect(x: 0, y: 0, width: 600, height: 400)),
                       [0])
    }

    func testAViewportStraddlingTwoPagesReportsBoth() {
        XCTAssertEqual(ScorePosition.visiblePages(bands: bands,
                                                  visible: CGRect(x: 0, y: 700, width: 600, height: 300)),
                       [0, 1])
    }

    func testZoomedInOnOnePageReportsOnlyThatPage() {
        XCTAssertEqual(ScorePosition.visiblePages(bands: bands,
                                                  visible: CGRect(x: 0, y: 900, width: 100, height: 80)),
                       [1])
    }

    /// Mid-resize the viewport can be outside the content entirely. Better the
    /// first page than an empty counter that looks like a fault.
    func testAViewportOutsideTheContentStillReportsSomething() {
        XCTAssertEqual(ScorePosition.visiblePages(bands: bands,
                                                  visible: CGRect(x: 0, y: 99_000, width: 600, height: 400)),
                       [0])
    }

    // MARK: - Which bar

    /// The start of what you can see, not the nearest to the centre: a reader
    /// asking "where am I?" means the top of the page, and it does not jump
    /// about as a system scrolls past the midpoint.
    func testTheBarIsTheLowestOnScreen() {
        XCTAssertEqual(ScorePosition.bar(measuresOnScreen: [24, 21, 23, 22]), 21)
    }

    /// Measure 0 is the parser's marker for "not measure-specific", not a bar
    /// anyone can be told about -- the same convention staff 0 follows.
    func testTheNotMeasureSpecificMarkerIsNeverReported() {
        XCTAssertEqual(ScorePosition.bar(measuresOnScreen: [0, 0, 14]), 14)
    }

    func testNoBarsOnScreenReportsNothingRatherThanZero() {
        XCTAssertNil(ScorePosition.bar(measuresOnScreen: []))
        XCTAssertNil(ScorePosition.bar(measuresOnScreen: [0, 0]))
    }
}

/// L29: the page and bar counters were drawn over the chat panel's header,
/// burying the model chip under "pp. 1–2 / 9".
final class CounterPlacementTests: XCTestCase {

    func testTheCountersStayOverTheMusicWhenChatOpens() {
        let inset = ScorePosition.counterTrailingInset(chatOpen: true, isCompact: false,
                                                       chatWidth: 380, base: 12)
        XCTAssertEqual(inset, 392, accuracy: 0.001,
                       "the counters should clear the whole chat panel")
    }

    func testWithoutChatTheySitWhereTheyAlwaysDid() {
        XCTAssertEqual(ScorePosition.counterTrailingInset(chatOpen: false, isCompact: false,
                                                          chatWidth: 380, base: 12),
                       12, accuracy: 0.001)
    }

    /// On a compact width the chat COVERS the score instead of sitting beside
    /// it, so there is nothing to clear -- insetting there would push the
    /// counters into the middle of the page.
    func testOnACompactWidthTheyDoNotMove() {
        XCTAssertEqual(ScorePosition.counterTrailingInset(chatOpen: true, isCompact: true,
                                                          chatWidth: 380, base: 12),
                       12, accuracy: 0.001)
    }
}
