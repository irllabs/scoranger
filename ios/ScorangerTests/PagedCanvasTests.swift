import CoreGraphics
import XCTest

/// The paged canvas (NAV_REVISION §6, carried into 0.4.2).
///
/// Written before the view, because the spec is explicit that ZoomableScroll
/// has been rebuilt three times and is the highest-risk edit in the revision.
/// What can be decided arithmetically is decided here, where a wrong answer
/// costs a second rather than a device.
final class PagedCanvasTests: XCTestCase {

    // MARK: - The unit on screen

    func testOnePageAtATimeWithTheSpreadOff() {
        XCTAssertEqual(PagedCanvas.unit(at: 3, pageCount: 12, spread: false), [3])
    }

    func testASpreadShowsAPair() {
        XCTAssertEqual(PagedCanvas.unit(at: 2, pageCount: 12, spread: true), [2, 3])
    }

    /// Units start on even indices, so page 1 belongs to the 0–1 spread rather
    /// than starting one of its own -- the way a title page sits alone.
    func testASpreadIsAlignedSoAPageBelongsToOneUnit() {
        XCTAssertEqual(PagedCanvas.unit(at: 3, pageCount: 12, spread: true), [2, 3])
        XCTAssertEqual(PagedCanvas.unit(at: 0, pageCount: 12, spread: true), [0, 1])
    }

    func testTheLastPageOfAnOddScoreSitsAlone() {
        XCTAssertEqual(PagedCanvas.unit(at: 4, pageCount: 5, spread: true), [4])
    }

    func testAnEmptyDocumentShowsNothing() {
        XCTAssertEqual(PagedCanvas.unit(at: 0, pageCount: 0, spread: false), [])
    }

    func testAnIndexOutsideTheDocumentShowsNothing() {
        XCTAssertEqual(PagedCanvas.unit(at: 99, pageCount: 12, spread: false), [])
    }

    // MARK: - Stepping

    func testATurnMovesOnePage() {
        XCTAssertEqual(PagedCanvas.step(from: 3, by: 1, pageCount: 12, spread: false), 4)
        XCTAssertEqual(PagedCanvas.step(from: 3, by: -1, pageCount: 12, spread: false), 2)
    }

    /// In a spread a turn moves a whole unit, or half the music would slide
    /// sideways under the reader.
    func testATurnInASpreadMovesTwo() {
        XCTAssertEqual(PagedCanvas.step(from: 2, by: 1, pageCount: 12, spread: true), 4)
        XCTAssertEqual(PagedCanvas.step(from: 3, by: 1, pageCount: 12, spread: true), 4)
        XCTAssertEqual(PagedCanvas.step(from: 4, by: -1, pageCount: 12, spread: true), 2)
    }

    func testTheEndsDoNotTurn() {
        XCTAssertNil(PagedCanvas.step(from: 11, by: 1, pageCount: 12, spread: false))
        XCTAssertNil(PagedCanvas.step(from: 0, by: -1, pageCount: 12, spread: false))
    }

    // MARK: - The strip jumps to the unit holding a page

    func testTappingAThumbLandsOnItsUnit() {
        XCTAssertEqual(PagedCanvas.index(forPage: 5, spread: true), 4,
                       "tapping the right half of a spread must not scroll its left half away")
        XCTAssertEqual(PagedCanvas.index(forPage: 5, spread: false), 5)
    }

    // MARK: - Zoom, and what it means for how many pages you can see

    /// "You can never see more than two pages" is not enforced anywhere: it is
    /// what fitting one unit to the canvas MEANS, and the floor is fit.
    func testYouCannotZoomOutPastFit() {
        XCTAssertEqual(PagedCanvas.clamp(zoom: 0.5), 1.0)
        XCTAssertEqual(PagedCanvas.clamp(zoom: 0.01), 1.0)
        XCTAssertEqual(PagedCanvas.minimumZoom, 1.0)
    }

    func testYouCanStillZoomAllTheWayIn() {
        XCTAssertEqual(PagedCanvas.clamp(zoom: 12), 12)
        XCTAssertEqual(PagedCanvas.clamp(zoom: 40), 12)
    }

    func testAtFitThereIsNothingToPan() {
        XCTAssertFalse(PagedCanvas.canPan(zoom: 1.0))
        XCTAssertTrue(PagedCanvas.canPan(zoom: 1.4))
    }

    // MARK: - Swipe to turn, and the edge

    /// At fit a drag has nothing to move, so it is free to mean a turn.
    func testASwipeTurnsWhenThereIsNothingToPan() {
        XCTAssertTrue(PagedCanvas.swipeMayTurn(zoom: 1.0, atLimitWhenItBegan: false))
    }

    /// Zoomed in and mid-page, a drag pans and must not turn -- otherwise the
    /// page flies away from someone reading a notehead.
    func testASwipeDoesNotTurnWhileThereIsStillPageToPan() {
        XCTAssertFalse(PagedCanvas.swipeMayTurn(zoom: 3, atLimitWhenItBegan: false))
    }

    /// Ali's build-with answer: STOP at the edge. Reaching the limit does not
    /// roll into a turn by itself -- but once you are already there, a further
    /// swipe is unambiguous.
    ///
    /// WHEN the limit is read is the whole of that distinction, and the call
    /// site used to read it at the END of the gesture: a single long pan from
    /// the middle of a zoomed page ends at the limit, so it turned. The
    /// parameter is named for the moment it must be sampled. Proven at the
    /// gesture level in `SwipeAtTheEdge`, which is where the sampling lives.
    func testAtTheEdgeASwipeMayTurn() {
        XCTAssertTrue(PagedCanvas.swipeMayTurn(zoom: 3, atLimitWhenItBegan: true))
    }

    // MARK: - What a turn does to the view

    /// A violinist reading at 180% stays at 180%.
    func testZoomSurvivesATurn() {
        XCTAssertEqual(PagedCanvas.afterTurn(zoom: 1.8).zoom, 1.8)
    }

    func testPanResetsToTheTopLeftOfTheNewPage() {
        XCTAssertEqual(PagedCanvas.afterTurn(zoom: 1.8).offset, .zero,
                       "turning a paper page does not leave you halfway down it")
    }

    func testAnImpossibleZoomIsStillClampedAfterATurn() {
        XCTAssertEqual(PagedCanvas.afterTurn(zoom: 0.2).zoom, 1.0)
    }

    // MARK: - Rapid turning

    /// Queueing animations means the reader keeps turning and the score keeps
    /// sliding after they stop.
    func testRapidTurnsCoalesceToTheLatest() {
        XCTAssertEqual(PagedCanvas.coalesce(pending: 4, latest: 7), 7)
        XCTAssertEqual(PagedCanvas.coalesce(pending: nil, latest: 2), 2)
    }

    // MARK: - Fitting the unit, which is what makes the floor mean anything

    /// A4-ish: taller than it is wide.
    private let portrait: CGFloat = 1.414

    func testATallPageOnAWideScreenIsHeightBound() {
        // 1200x800 landscape: the page runs out of height long before width
        let w = PagedCanvas.fittedPageWidth(viewport: CGSize(width: 1200, height: 800),
                                            pageAspect: portrait, pages: 1,
                                            gutter: 12, margin: 12)
        XCTAssertEqual(w * portrait, 800 - 24, accuracy: 1,
                       "the page should be exactly as tall as the viewport allows")
        XCTAssertLessThan(w, 1200 - 24, "and narrower than the width allows")
    }

    func testAWidePageOnATallScreenIsWidthBound() {
        let w = PagedCanvas.fittedPageWidth(viewport: CGSize(width: 400, height: 1200),
                                            pageAspect: portrait, pages: 1,
                                            gutter: 12, margin: 12)
        XCTAssertEqual(w, 400 - 24, accuracy: 1)
    }

    /// A spread has to fit BOTH pages and the gutter between them, so each page
    /// is a little under half the width -- not half.
    func testASpreadSplitsTheWidthAndPaysForTheGutter() {
        let one = PagedCanvas.fittedPageWidth(viewport: CGSize(width: 2000, height: 4000),
                                              pageAspect: portrait, pages: 1,
                                              gutter: 12, margin: 12)
        let two = PagedCanvas.fittedPageWidth(viewport: CGSize(width: 2000, height: 4000),
                                              pageAspect: portrait, pages: 2,
                                              gutter: 12, margin: 12)
        XCTAssertLessThan(two, one / 2 + 1)
        XCTAssertEqual(two * 2 + 12, one, accuracy: 1,
                       "two pages plus the gutter should use the same width as one")
    }

    /// Fitted means fitted: at zoom 1 the whole unit is inside the viewport,
    /// which is the entire reason the zoom floor can be 1.
    func testTheFittedUnitIsInsideTheViewportInBothDimensions() {
        for viewport in [CGSize(width: 1200, height: 800),
                         CGSize(width: 820, height: 1180),
                         CGSize(width: 500, height: 500)] {
            for pages in [1, 2] {
                let w = PagedCanvas.fittedPageWidth(viewport: viewport, pageAspect: portrait,
                                                    pages: pages, gutter: 12, margin: 12)
                let used = w * CGFloat(pages) + 12 * CGFloat(pages - 1)
                XCTAssertLessThanOrEqual(used, viewport.width - 23,
                                         "too wide at \(viewport) x\(pages)")
                XCTAssertLessThanOrEqual(w * portrait, viewport.height - 23,
                                         "too tall at \(viewport) x\(pages)")
            }
        }
    }

    /// L21 was reported as a landscape two-page spread clipped at the top, so
    /// the canvases the app actually runs on are named here rather than left
    /// to three round numbers. 1376x832 is the measured landscape canvas of an
    /// iPad Pro 13" with the top bar and the thumbnail strip on screen -- the
    /// exact frame the report was taken from.
    /// What the canvas reserves for the floating pill, as ScorePagesView passes
    /// it to ZoomableScroll (52 + 20 + 12).
    private let chrome: CGFloat = 84

    /// The literal above is only safe while it IS what the view passes. The
    /// view itself cannot be compiled into this bundle, so its arithmetic is
    /// asserted here instead.
    func testTheChromeThisSuiteMeasuresIsTheChromeTheViewReserves() {
        XCTAssertEqual(Theme.Metric.scoreBottomChrome
                       + Theme.Metric.s20 + Theme.Metric.s12, chrome,
                       "ScorePagesView.bottomChrome changed; this suite still "
                       + "measures against \(chrome)")
    }

    func testTheRealDeviceCanvasesFitASpread() {
        let canvases: [(String, CGSize)] = [
            ("iPad Pro 13 landscape", CGSize(width: 1376, height: 832)),
            ("iPad Pro 13 portrait", CGSize(width: 1032, height: 1176)),
            ("iPad Air 11 landscape", CGSize(width: 1180, height: 700)),
            ("iPad Air 11 portrait", CGSize(width: 820, height: 1060)),
            ("iPhone landscape", CGSize(width: 852, height: 300)),
        ]
        for (name, viewport) in canvases {
            for pages in [1, 2] {
                let w = PagedCanvas.fittedPageWidth(viewport: viewport, pageAspect: portrait,
                                                    pages: pages, gutter: 12, margin: 12,
                                                    bottomChrome: chrome)
                // the page is padded 12 top and bottom by the unit's own layout
                let tall = w * portrait + 24
                // L21: what is left after the pill, not the whole canvas. The
                // scroll view reserves the chrome as a bottom inset either way,
                // so a unit that fills the canvas is a unit taller than its own
                // scroll view -- and that is what scrolled the top away.
                XCTAssertLessThanOrEqual(tall, viewport.height - chrome + 0.5,
                                         "\(name) x\(pages): a \(tall)pt unit in a "
                                         + "\(viewport.height)pt canvas holding \(chrome)pt "
                                         + "of chrome is clipped")
                let wide = w * CGFloat(pages) + 12 * CGFloat(pages - 1) + 24
                XCTAssertLessThanOrEqual(wide, viewport.width + 0.5, "\(name) x\(pages)")
            }
        }
    }

    /// A landscape canvas is bound by its HEIGHT, and a spread must not be
    /// sized from the width alone -- that is what the report says went wrong.
    func testALandscapeSpreadIsBoundByHeightNotWidth() {
        let viewport = CGSize(width: 1376, height: 832)
        let w = PagedCanvas.fittedPageWidth(viewport: viewport, pageAspect: portrait,
                                            pages: 2, gutter: 12, margin: 12,
                                            bottomChrome: chrome)
        let byWidthAlone = (viewport.width - 24 - 12) / 2
        XCTAssertLessThan(w, byWidthAlone,
                          "the height did not bind: sizing from width alone gives "
                          + "\(byWidthAlone)pt pages, which are \(byWidthAlone * portrait)pt tall "
                          + "in a \(viewport.height)pt canvas")
        XCTAssertEqual(w * portrait + 24, viewport.height - chrome, accuracy: 0.5,
                       "a height-bound spread should use the clear height exactly")
    }

    /// L21, measured on an iPad Pro 11-inch in landscape with the spread on:
    /// the fit spent all 634pt of canvas height, `ZoomableScroll.centreIfNeeded`
    /// then added the pill's 84pt as a bottom inset, and the 634pt unit sat in
    /// 718pt of scrollable content. Any offset inside that 84pt scrolled the top
    /// of BOTH pages off the screen -- about one system, which is what the
    /// designer saw. It clipped only in landscape with the chat closed because
    /// that is the one case where the HEIGHT binds: everything narrower is
    /// width-bound and lands well inside the canvas.
    func testTheFittedUnitClearsTheFloatingChrome() {
        let viewport = CGSize(width: 1210, height: 634)
        let aspect: CGFloat = 1.2942
        let w = PagedCanvas.fittedPageWidth(viewport: viewport, pageAspect: aspect,
                                            pages: 2, gutter: 12, margin: 12,
                                            bottomChrome: chrome)
        let unit = w * aspect + 24
        XCTAssertLessThanOrEqual(unit, viewport.height - chrome + 0.5,
                                 "a \(unit)pt unit in \(viewport.height)pt of canvas "
                                 + "leaves \(viewport.height - unit)pt for \(chrome)pt "
                                 + "of chrome, so the content scrolls and the top clips")
        // and the scroll view it feeds is then exactly one viewport tall
        XCTAssertEqual(unit + chrome, viewport.height, accuracy: 0.5,
                       "the unit plus its chrome should be the viewport exactly")
    }

    /// No chrome, no reserve: the geometry itself is unchanged.
    func testWithoutChromeTheFitIsWhatItWas() {
        let viewport = CGSize(width: 1210, height: 634)
        XCTAssertEqual(PagedCanvas.fittedPageWidth(viewport: viewport, pageAspect: portrait,
                                                   pages: 2, gutter: 12, margin: 12,
                                                   bottomChrome: 0),
                       (viewport.height - 24) / portrait, accuracy: 0.01)
    }

    // MARK: keeping the reader's page across an op (#44)

    func testAPageThatStillExistsIsKept() {
        XCTAssertEqual(PagedCanvas.clampedIndex(3, pageCount: 9), 3)
        XCTAssertEqual(PagedCanvas.clampedIndex(0, pageCount: 1), 0)
    }

    /// An op can make a score shorter -- dropping a part, or engraving tighter.
    /// An index past the end renders as NO pages, which is exactly the blank
    /// canvas that keeping the page was meant to avoid.
    func testAPageThatIsGoneFallsBackToTheLast() {
        XCTAssertEqual(PagedCanvas.clampedIndex(8, pageCount: 3), 2)
        XCTAssertEqual(PagedCanvas.clampedIndex(1, pageCount: 1), 0)
    }

    func testAScoreWithNoPagesAsksForTheFirst() {
        XCTAssertEqual(PagedCanvas.clampedIndex(4, pageCount: 0), 0)
        XCTAssertEqual(PagedCanvas.clampedIndex(-2, pageCount: 5), 0)
    }

    /// The clamp and the unit have to agree, or a kept page is still blank.
    func testAClampedIndexAlwaysRendersPages() {
        for pageCount in [1, 2, 3, 9] {
            for index in [0, 1, 5, 40] {
                for spread in [true, false] {
                    let clamped = PagedCanvas.clampedIndex(index, pageCount: pageCount)
                    XCTAssertFalse(PagedCanvas.unit(at: clamped, pageCount: pageCount,
                                                    spread: spread).isEmpty,
                                   "index \(index) of \(pageCount) clamped to "
                                   + "\(clamped) still renders nothing")
                }
            }
        }
    }

    func testAnUnmeasuredViewportAsksForNothing() {
        XCTAssertEqual(PagedCanvas.fittedPageWidth(viewport: .zero, pageAspect: portrait,
                                                   pages: 1, gutter: 12, margin: 12), 0)
        XCTAssertEqual(PagedCanvas.fittedPageWidth(viewport: CGSize(width: 100, height: 100),
                                                   pageAspect: 0, pages: 1,
                                                   gutter: 12, margin: 12), 0)
    }

    /// Fitted means FILLS, not merely fits.
    ///
    /// The tests above only ever asserted the unit was inside the viewport, so
    /// a width that came out 6% short passed them and failed on screen. One of
    /// the two dimensions must be used up exactly -- that is the difference
    /// between fitting and being lost in the middle.
    func testTheFittedUnitFillsWhicheverDimensionBinds() {
        for viewport in [CGSize(width: 1200, height: 800),
                         CGSize(width: 820, height: 1180),
                         CGSize(width: 500, height: 500)] {
            for pages in [1, 2] {
                let w = PagedCanvas.fittedPageWidth(viewport: viewport, pageAspect: portrait,
                                                    pages: pages, gutter: 12, margin: 12)
                let usedWidth = w * CGFloat(pages) + 12 * CGFloat(pages - 1) + 24
                let usedHeight = w * portrait + 24
                let fillsWidth = abs(usedWidth - viewport.width) < 1
                let fillsHeight = abs(usedHeight - viewport.height) < 1
                XCTAssertTrue(fillsWidth || fillsHeight,
                              "at \(viewport) x\(pages) the unit fills neither "
                              + "dimension: \(usedWidth)x\(usedHeight)")
            }
        }
    }

    /// 0.23.3: a swipe made while only page 1 exists is carried out when the
    /// rest arrive, not thrown away.
    func testTurnsHeldBeforeThePagesExistLandWhenTheyArrive() {
        XCTAssertEqual(PagedCanvas.landing(afterHeldTurns: 1, from: 0,
                                           pageCount: 6, spread: false), 1)
        XCTAssertEqual(PagedCanvas.landing(afterHeldTurns: 3, from: 0,
                                           pageCount: 6, spread: false), 3)
        // a spread turns a whole unit at a time
        XCTAssertEqual(PagedCanvas.landing(afterHeldTurns: 2, from: 0,
                                           pageCount: 9, spread: true), 4)
        // more turns than pages stop at the last page
        XCTAssertEqual(PagedCanvas.landing(afterHeldTurns: 10, from: 0,
                                           pageCount: 3, spread: false), 2)
        // a turn forward then back again lands where it started
        XCTAssertEqual(PagedCanvas.landing(afterHeldTurns: 0, from: 0,
                                           pageCount: 6, spread: false), 0)
        // a one-page score has nowhere to go
        XCTAssertEqual(PagedCanvas.landing(afterHeldTurns: 2, from: 0,
                                           pageCount: 1, spread: false), 0)
    }
}
