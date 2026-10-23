import CoreGraphics
import Foundation

/// The canvas shows exactly one page, or one spread, and nothing else exists
/// on screen (NAV_MODAL_FREE_0.4.2 §6 / NAV_REVISION §6).
///
/// This replaces a tall scroll holding every page. The consequences are worth
/// stating, because they are what make the rest simpler:
///
/// - "You can never see more than two pages" is not a rule that has to be
///   enforced anywhere: it is what fitting ONE unit to the canvas means. The
///   zoom floor is fit, so zooming out cannot reveal a neighbour.
/// - A turn changes an INDEX, not a scroll offset. `PageTurn.destination` and
///   its boundary arithmetic are gone with the stack they were computed over.
/// - The lasso is always inside one page's coordinate space, so the
///   visible-rect → page mapping loses a whole class of edge case.
enum PagedCanvas {
    /// Fit is 1.0 by definition: the whole unit inside the viewport. Below it
    /// there is nothing to see but ground, so it is the floor.
    static let minimumZoom: CGFloat = 1.0
    static let maximumZoom: CGFloat = 12.0

    /// The pages making up the unit at `index`.
    ///
    /// With the spread on, units start on EVEN indices, so page 0 sits alone on
    /// the left of a spread the way a title page does in a real score.
    static func unit(at index: Int, pageCount: Int, spread: Bool) -> [Int] {
        guard pageCount > 0, index >= 0, index < pageCount else { return [] }
        guard spread else { return [index] }
        let first = index - (index % 2)
        return [first, first + 1].filter { $0 < pageCount }
    }

    /// Where a step lands, or nil at the ends. Stepping is ±1, or ±2 in a
    /// spread, so a turn always moves by a whole unit.
    static func step(from index: Int, by direction: Int,
                     pageCount: Int, spread: Bool) -> Int? {
        guard pageCount > 0 else { return nil }
        let stride = spread ? 2 : 1
        let current = spread ? index - (index % 2) : index
        let next = current + direction * stride
        guard next >= 0, next < pageCount else { return nil }
        return next
    }

    /// Where turns the reader made before the pages existed land, once they
    /// do: `turns` net steps from `index`, each a whole unit, stopping at the
    /// ends. While a score's first page is on screen alone, a swipe to the
    /// next page has nowhere to go and used to be thrown away -- the reader
    /// swiped, nothing happened, and they had to swipe again once the rest
    /// arrived (0.23.3). The turns are held instead and carried out here.
    static func landing(afterHeldTurns turns: Int, from index: Int,
                        pageCount: Int, spread: Bool) -> Int {
        var landed = clampedIndex(index, pageCount: pageCount)
        let direction = turns > 0 ? 1 : -1
        for _ in 0..<abs(turns) {
            guard let next = step(from: landed, by: direction,
                                  pageCount: pageCount, spread: spread) else { break }
            landed = next
        }
        return landed
    }

    /// The index a thumbnail tap should land on: the unit HOLDING that page,
    /// not the page itself, so tapping the right half of a spread does not
    /// scroll the left half off.
    static func index(forPage page: Int, spread: Bool) -> Int {
        guard spread else { return page }
        return page - (page % 2)
    }

    /// Zoom, clamped. This single clamp is what "never more than two pages"
    /// means in code.
    static func clamp(zoom: CGFloat) -> CGFloat {
        min(max(zoom, minimumZoom), maximumZoom)
    }

    /// Is there anywhere to pan? Only past fit; at fit the unit exactly fills
    /// the canvas, so a drag has nothing to move and is free to mean a turn.
    static func canPan(zoom: CGFloat) -> Bool { zoom > minimumZoom }

    /// May a swipe turn the page?
    ///
    /// Only when there was no horizontal slack WHEN THE GESTURE BEGAN -- at
    /// fit, or already hard against the unit's edge. Ali's build-with
    /// recommendation was STOP at the edge, so a drag that reaches it does not
    /// roll into a turn; the turn is a second, deliberate gesture, and the tap
    /// zones are always there.
    ///
    /// The parameter is named for when it is read because reading it at the
    /// END is the whole bug: a single long pan from the middle of a zoomed
    /// page ENDS at the limit, so it turned -- which is precisely the rolling
    /// this rule exists to forbid. It went unseen because the recogniser that
    /// reports a swipe never fired at all until 0.6.14; the first thing that
    /// happened when it was repaired was a zoomed page panning itself seven
    /// pages forward.
    static func swipeMayTurn(zoom: CGFloat, atLimitWhenItBegan: Bool) -> Bool {
        !canPan(zoom: zoom) || atLimitWhenItBegan
    }

    /// What a turn does to zoom and pan.
    ///
    /// Zoom PERSISTS -- a violinist reading at 180% stays at 180% -- and pan
    /// resets to the top-left of the new unit, which is what turning a paper
    /// page does.
    ///
    /// That persistence is also why zoom cannot separate a turn from a
    /// selection: a reader who turned three pages ago at 180% is still at 180%
    /// and has long stopped thinking about it, so "turns at fit, selects when
    /// zoomed" would be the same tap in the same place meaning two things for a
    /// reason nobody is tracking. §12 separates them by REGION instead.
    static func afterTurn(zoom: CGFloat) -> (zoom: CGFloat, offset: CGPoint) {
        (clamp(zoom: zoom), .zero)
    }

    /// How wide one page should be drawn so the whole unit FITS.
    ///
    /// This is the number that makes the zoom floor mean something: fit is 1.0
    /// by definition, so if the unit is fitted here, "you can never see more
    /// than two pages" needs no enforcement anywhere else.
    ///
    /// Both dimensions have to be inside the viewport, so it is the smaller of
    /// what the width allows and what the height allows. A tall page on a
    /// landscape iPad is height-bound, which is exactly the case §6.4 warns
    /// makes the notation small -- the answer to that is zooming, which is now
    /// unbounded upwards rather than a fight with the floor.
    /// `bottomChrome` is the room the canvas has already promised to the
    /// floating pill (`ZoomableScroll.bottomChrome`). It is NOT height the fit
    /// may spend: the scroll view adds it as a bottom inset whatever the fit
    /// decides, so a unit sized to the whole canvas is a unit taller than the
    /// scroll view holding it -- scrollable by exactly the chrome, and any
    /// offset in that range takes the top of the page off the screen (L21).
    /// Measured on an 11-inch in landscape: a 634pt unit in 718pt of content.
    static func fittedPageWidth(viewport: CGSize, pageAspect: CGFloat,
                                pages: Int, gutter: CGFloat,
                                margin: CGFloat,
                                bottomChrome: CGFloat = 0) -> CGFloat {
        guard viewport.width > 0, viewport.height > 0, pageAspect > 0, pages > 0 else {
            return 0
        }
        let across = max(viewport.width - margin * 2 - gutter * CGFloat(pages - 1), 1)
        let byWidth = across / CGFloat(pages)
        let clear = max(viewport.height - margin * 2 - max(bottomChrome, 0), 1)
        let byHeight = clear / pageAspect
        return max(min(byWidth, byHeight), 1)
    }

    /// Keep a remembered page inside a score that may have got shorter.
    ///
    /// The reader's page is kept across an op now (#44), and an op can remove
    /// pages -- dropping a part, or simply engraving tighter. `unit(at:)`
    /// answers an out-of-range index with NO pages, so an unclamped index is a
    /// blank canvas: the very thing keeping the page was meant to avoid.
    static func clampedIndex(_ index: Int, pageCount: Int) -> Int {
        guard pageCount > 0 else { return 0 }
        return min(max(index, 0), pageCount - 1)
    }

    /// Coalesce rapid turns to the latest index rather than queueing
    /// animations (§6.4 risk 3).
    static func coalesce(pending: Int?, latest: Int) -> Int {
        _ = pending
        return latest
    }
}
