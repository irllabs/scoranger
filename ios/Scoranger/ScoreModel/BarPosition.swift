import CoreGraphics
import Foundation

/// Which bar the reader is looking at.
///
/// The `bar 21` readout the navigation system asked for (§4). It was costed as
/// "depends on the vector-score session" when the canvas was a scrolling stack
/// of every page; 0.4.2 made it cheap. The paged canvas shows one page, or one
/// spread, and pans only inside that unit — so the question reduces to "which
/// bars on THIS page does the visible rect overlap", and every measure's frame
/// is already indexed in page coordinates by `ScoreModelBuilder`.
///
/// Pure geometry, so it is tested without an app, a screen or an engine.
enum BarPosition {

    /// One bar's number and where it sits, in page (SVG user) coordinates.
    struct Bar: Equatable {
        let number: Int
        let frame: CGRect
    }

    /// The earliest bar the reader can see, or nil when none is visible.
    ///
    /// The LOWEST number rather than the leftmost frame: on a page with several
    /// systems the leftmost bar of the lower system sits further left than the
    /// rightmost bar of the upper one, and "where am I" means the earliest
    /// music on screen, not the westernmost ink.
    ///
    /// `intersects` is used rather than a containment test because a bar half
    /// on screen is still a bar the reader can see — but touching edge-to-edge
    /// is not overlapping, so stopping exactly on a barline does not claim the
    /// bar beyond it.
    static func first(in visible: CGRect, bars: [Bar]) -> Int? {
        bars.lazy
            .filter { $0.frame.intersects(visible) }
            .map(\.number)
            .min()
    }

    /// The same question for a spread, where the unit is two pages side by side
    /// and each has its own coordinate space and its own visible rect.
    static func first(inPages pages: [(visible: CGRect, bars: [Bar])]) -> Int? {
        pages.compactMap { first(in: $0.visible, bars: $0.bars) }.min()
    }

    /// What the top bar shows. Nil where nothing is known — the remote-engine
    /// path builds no geometry, and a wrong bar number is worse than none.
    static func label(for bar: Int?) -> String? {
        bar.map(BarName.text)
    }

    /// Whether the canvas puts a bar number in the corner at all.
    ///
    /// Marked "remove from this view" on a screenshot of a score being READ.
    /// It is right: a reader looking at the music is looking at bar numbers
    /// already -- they are engraved on the page, above the systems, where the
    /// publisher put them -- and a chip in the corner repeating one of them is
    /// a second answer to a question the page has already answered.
    ///
    /// It is NOT removed, because there is one state where the page cannot
    /// answer it: while the music is playing, the bar that is SOUNDING is a
    /// moving fact no engraving carries, and a player who has scrolled away
    /// from the cursor has nothing else to tell them where they have drifted
    /// to. So the chip is playback's, and it appears with the play head.
    ///
    /// The page counter beside it is a different thing and is not touched:
    /// "3 of 12" is about the DOCUMENT, is true whether anything is playing or
    /// not, and nothing on the page says it.
    static func counter(bar: Int?, isPlaying: Bool) -> Int? {
        isPlaying ? bar : nil
    }
}

extension BarPosition {
    /// Where a page of the current unit sits in scroll-content coordinates.
    ///
    /// Computed rather than measured. A GeometryReader inside the scroll view
    /// never reported: SwiftUI does not re-lay-out a hosted hierarchy as UIKit
    /// scrolls it, and the reader's `onAppear` did not fire at all. The layout
    /// is deterministic anyway -- `pageUnit` is an HStack of equal-width pages
    /// with one gutter between them and a gutter above -- so it is arithmetic,
    /// and arithmetic can be tested without a screen.
    static func pageFrame(position: Int, width: CGFloat, aspect: CGFloat,
                          gutter: CGFloat) -> CGRect {
        CGRect(x: CGFloat(position) * (width + gutter),
               y: gutter,
               width: width,
               height: width * aspect)
    }

    /// Where one numbered bar sits on a page, in page (SVG user) coordinates.
    ///
    /// The FIRST match, because in continuous mode the whole score is one page
    /// and a bar number is unique on it. (A repeated bar is played twice but
    /// engraved once; the repetition lives in the playback timeline, not on
    /// the page.) Nil where the geometry has no such bar, which is every
    /// remote-engine render: that path builds no geometry at all, and the
    /// caller must then follow nothing rather than follow a guess.
    static func frame(ofBar number: Int, among bars: [Bar]) -> CGRect? {
        bars.first { $0.number == number }?.frame
    }

    /// The bars of one page, read out of the geometry the engraver built.
    ///
    /// A `<measure>` element's frame spans the whole bar, which is exactly the
    /// rect wanted here — see `ScoreModelBuilder`'s note that it never uses the
    /// measure element for hit-testing a NOTE for the opposite reason.
    static func bars(onPage page: ScorePage) -> [Bar] {
        // Computed once, when the page is made (`ScorePage.barFrames`).
        page.barFrames
    }

    /// Cut each bar's right edge back to where the next bar begins.
    ///
    /// Verovio nests a spanner -- a slur, a tie, a hairpin -- inside the
    /// measure where it STARTS, and `SVGGeometryParser` gives every group the
    /// union of everything drawn inside it. That is the right rule for a note,
    /// which should bound its notehead, stem, dots and accidental together, and
    /// the wrong one for a bar: a cello slur running from measure 1 into
    /// measure 4 makes measure 1's rectangle four bars wide.
    ///
    /// It went unnoticed for as long as the frame was only used to answer
    /// "which bars can the reader see", where being too wide changes almost
    /// nothing. The playhead interpolates ACROSS the rectangle, so a bar four
    /// bars wide put the cursor two bars late -- caught in a screenshot, with
    /// the transport correctly reading bar 1 and the line standing in bar 3.
    ///
    /// The left edge is sound: nothing is drawn left of the barline a spanner
    /// starts at. So the right edge comes from the next bar instead, and only
    /// from a bar on the SAME system -- the first bar of the system below sits
    /// far to the left, and clipping against it would leave a negative width.
    ///
    /// Proven against the real engraver in `engine/scripts/check_bar_frames.py`,
    /// which engraves the scanned quartet with Verovio and asserts that the
    /// span for measure N holds measure N's notes and none of its neighbour's.
    /// On that page nine bars overlap unclipped, the worst by 2.1 bars.
    static func clippedToNeighbours(_ bars: [Bar]) -> [Bar] {
        bars.map { bar in
            let nextEdge = bars.lazy
                .filter { other in
                    other.frame.minX > bar.frame.minX + 0.5
                        // same system: their vertical extents overlap
                        && other.frame.minY < bar.frame.maxY
                        && other.frame.maxY > bar.frame.minY
                }
                .map(\.frame.minX)
                .min()
            guard let nextEdge, nextEdge < bar.frame.maxX else { return bar }
            return Bar(number: bar.number,
                       frame: CGRect(x: bar.frame.minX, y: bar.frame.minY,
                                     width: nextEdge - bar.frame.minX,
                                     height: bar.frame.height))
        }
    }

    /// The bars of a page, grouped into the systems they sit on.
    ///
    /// There is no system in `ScoreGeometry` to read: Verovio draws them but
    /// the model keeps measures, notes and the addressable groups. So this
    /// infers them, by the SAME rule `clippedToNeighbours` above already
    /// depends on -- two bars are on one system when their vertical extents
    /// overlap -- rather than inventing a second rule that could disagree
    /// with the one the playhead relies on.
    ///
    /// Overlap and not equality, because a system's bars are not aligned: a
    /// bar carrying a high note, a slur or a chord diagram is taller than its
    /// neighbours, and a stricter test would split one system into three
    /// every time the music did something.
    ///
    /// Why it exists: a page COUNT cannot tell a collapsed layout from a
    /// short piece. Ali's #4 screenshot reads "p. 1 / 1", and on a folk tune
    /// one page may be perfectly correct -- what is wrong is that the music
    /// is on one line. This counts the lines.
    ///
    /// Returned in reading order, top to bottom, each system's bars left to
    /// right: the count is the point, but an order makes a failure legible.
    static func systems(of bars: [Bar]) -> [[Bar]] {
        var systems: [[Bar]] = []
        for bar in bars.sorted(by: { $0.frame.minY < $1.frame.minY }) {
            if let index = systems.firstIndex(where: { system in
                system.contains { other in
                    other.frame.minY < bar.frame.maxY
                        && other.frame.maxY > bar.frame.minY
                }
            }) {
                systems[index].append(bar)
            } else {
                systems.append([bar])
            }
        }
        return systems
            .map { $0.sorted { $0.frame.minX < $1.frame.minX } }
            .sorted { ($0.first?.frame.minY ?? 0) < ($1.first?.frame.minY ?? 0) }
    }
}
