import CoreGraphics
import Foundation

/// Keeping the sounding bar on screen while the reader plays along.
///
/// The practice case (CONTINUOUS_VIEW.md): the music scrolls, the player reads,
/// and the strip says where in the score the sound has got to. So this is
/// deliberately RELUCTANT. A view that recentres on every bar takes the page
/// away from a reader who has just panned somewhere to look at it, and a strip
/// that slides continuously under the eye is harder to read than one that
/// holds still. It moves only when the sounding bar has actually left the
/// comfortable part of the viewport, and then it moves far enough that it will
/// not need to move again for a while.
///
/// Pure geometry over the strip's own surface coordinates, so it is tested
/// without a scroll view, a score or a sound.
enum PlaybackFollow {

    /// How far in from the left the sounding bar is placed when a move is
    /// needed: a third, leaving two thirds of the viewport as music the player
    /// has not reached yet. Reading ahead is the whole point of a scrolling
    /// part.
    static let lead: CGFloat = 1.0 / 3.0

    /// The band at each edge inside which a bar counts as "about to leave".
    /// Without it the strip re-scrolls when the bar is half off the edge,
    /// which is exactly when it is hardest to read.
    static let guardBand: CGFloat = 0.08

    /// Where the strip should scroll to, or nil to leave it where it is.
    ///
    /// - Parameters:
    ///   - bar: the sounding bar's frame in SURFACE points (the strip as laid
    ///     out on screen), which is the space `ZoomableScroll.scrollTarget`
    ///     takes.
    ///   - visible: the viewport in the same space.
    ///   - surfaceWidth: the whole strip, so the end of the score cannot be
    ///     scrolled past.
    static func target(bar: CGRect, visible: CGRect, surfaceWidth: CGFloat) -> CGFloat? {
        guard visible.width > 0, surfaceWidth > 0 else { return nil }
        let inset = visible.width * guardBand
        let comfortable = bar.minX >= visible.minX + inset
            && bar.maxX <= visible.maxX - inset
        if comfortable { return nil }
        return clamp(bar.minX - visible.width * lead,
                     surfaceWidth: surfaceWidth, viewportWidth: visible.width)
    }

    /// The same question at a seek, where the answer is never "leave it": the
    /// reader asked to be taken somewhere.
    static func seek(bar: CGRect, viewportWidth: CGFloat, surfaceWidth: CGFloat) -> CGFloat {
        clamp(bar.minX - viewportWidth * lead,
              surfaceWidth: surfaceWidth, viewportWidth: viewportWidth)
    }

    private static func clamp(_ x: CGFloat, surfaceWidth: CGFloat,
                              viewportWidth: CGFloat) -> CGFloat {
        min(max(x, 0), max(surfaceWidth - viewportWidth, 0))
    }

    /// Where a bar sits on the strip, in surface points.
    ///
    /// The strip is ONE engraved page, so every bar's frame is already in the
    /// geometry index in SVG user coordinates; the surface is that page scaled
    /// to fit the viewport's height. One multiplication, and it is here rather
    /// than at the call site so the test can hold it still.
    static func surfaceFrame(pageFrame: CGRect, scale: CGFloat) -> CGRect {
        CGRect(x: pageFrame.minX * scale, y: pageFrame.minY * scale,
               width: pageFrame.width * scale, height: pageFrame.height * scale)
    }

    /// Following in PAGED mode, where there is nothing to scroll: the unit
    /// turns when the sounding bar is on another page.
    ///
    /// Returns nil when the bar is already on screen, so a player reading a
    /// page is not interrupted by a turn they did not need.
    static func turn(toPage page: Int, showing visible: [Int],
                     spread: Bool) -> Int? {
        guard !visible.contains(page) else { return nil }
        return PagedCanvas.index(forPage: page, spread: spread)
    }
}

/// Who decides which page is shown while the music plays.
///
/// Following is on during playback and turns the page at 85% of its width, so
/// the next page arrives before the music does. A MANUAL page turn hands
/// control to the reader and does not take it back: the music keeps playing,
/// the page stays where they put it, and following does NOT resume on its own.
///
/// The rule it replaces resumed automatically once the playhead came back into
/// view, and that makes one gesture mean two different things depending on
/// where the music happens to be. A reader paging ahead to see what is coming
/// would be snatched back the moment the music arrived -- not because they
/// asked, but because the playhead wandered in. An explicit tap is a reader
/// saying "take me back", and that is the only moment it is right to move the
/// page under someone.
struct PageFollow: Equatable {

    private(set) var isFollowing = true

    /// The reader turned a page themselves. Nothing here stops the music --
    /// this type cannot -- and following does not come back by itself.
    mutating func readerTurnedPage() { isFollowing = false }

    /// "Take me back." The only thing that restores following.
    mutating func syncTapped() { isFollowing = true }

    /// A different performance: another score, another version. Not a
    /// resumption -- there is no page the reader chose to be on any more.
    mutating func loadedSomethingElse() { isFollowing = true }

    /// Whether the Sync control is on screen.
    ///
    /// Gated on `isFollowing`, and that gate is not decoration. The literal
    /// rule -- "show it whenever the visible page is not the playhead's" --
    /// INVERTS under auto-follow: the 85% turn is pre-emptive, so for a moment
    /// the next page is showing while the playhead is still on the last one,
    /// and a chip would blink on every single page turn. While following is on
    /// the app is doing the paging and there is nothing to sync.
    ///
    /// - `visiblePages` carries BOTH pages of a spread, so a playhead on the
    ///   left leaf of the visible spread shows nothing.
    /// - Absent when nothing is playing, so stopping while paged away does not
    ///   leave it stranded.
    /// - Absent in performance mode, which exists to remove exactly this.
    /// - `playheadPage` nil means no geometry -- every remote-engine render --
    ///   and nothing is offered rather than a jump to a guess.
    static func showsSync(isPlaying: Bool, isFollowing: Bool,
                          playheadPage: Int?, visiblePages: [Int],
                          isPerformanceMode: Bool) -> Bool {
        guard isPlaying, !isFollowing, !isPerformanceMode,
              let playheadPage else { return false }
        return !visiblePages.contains(playheadPage)
    }

    /// The same question on the continuous strip, where there are no pages and
    /// "off screen" is horizontal.
    ///
    /// One rule, two geometries, and the same state behind both: the reader
    /// scrolled, the music kept playing, and the line has since run out of
    /// view. The gate on `isFollowing` matters here for the same reason it does
    /// in paged mode -- while the app is doing the scrolling there is nothing
    /// to sync.
    ///
    /// - Parameters:
    ///   - playheadX: the line in SURFACE points, or nil where there is no
    ///     geometry to place it -- every remote-engine render.
    ///   - visible: the viewport in the same points.
    static func showsSync(isPlaying: Bool, isFollowing: Bool,
                          playheadX: CGFloat?, visible: CGRect,
                          isPerformanceMode: Bool) -> Bool {
        guard isPlaying, !isFollowing, !isPerformanceMode,
              let playheadX, visible.width > 0 else { return false }
        return playheadX < visible.minX || playheadX > visible.maxX
    }

    /// What the chip says. The bar, because a reader navigates by bar and
    /// "Back to playback" tells them nothing about where they are going.
    static func syncLabel(bar: Int?) -> String {
        bar.map { "Back to \(BarName.phrase($0))" } ?? "Back to playback"
    }
}
