import CoreGraphics

/// Where a row dragged by its ☰ lands, and where the other rows stand while it
/// is held.
///
/// Pure, so the rule is tested without a screen: `ReorderableRows` measures
/// each row, hands this the row it picked up and how far the finger has moved,
/// and draws what comes back.
///
/// THE RULE: a neighbour steps aside once the held row's leading edge crosses
/// that neighbour's middle -- its bottom edge going down, its top edge going
/// up. With rows of one height that is half a row of travel per place, the
/// same feel as UIKit's reorder control. Judging by the held row's CENTRE
/// against each neighbour's centre needs a full row of travel before anything
/// moves, which reads as a list that is not listening.
///
/// Neighbours are judged where they stood when the drag began, not where they
/// have stepped aside to. Judging against a row that is itself moving makes
/// the list flicker back and forth while the finger rests near a boundary.
struct RowReorder: Equatable {
    /// Each row's height in list order, the rule under it included.
    let heights: [CGFloat]
    /// The row picked up.
    let from: Int
    /// Each row's top, measured from the top of the first.
    private let tops: [CGFloat]

    /// How far the finger moves before a press on the ☰ becomes a drag. Below
    /// this it is a tap, and the ☰ opens the row's actions as it always has.
    static let pickUpDistance: CGFloat = 8

    /// Nil when `from` is not a row, or when any row has not been measured
    /// yet: a zero height would put every neighbour's middle at the top of the
    /// list and the first movement would carry the row to the end.
    init?(heights: [CGFloat], from: Int) {
        guard heights.indices.contains(from), heights.allSatisfy({ $0 > 0 }) else { return nil }
        self.heights = heights
        self.from = from
        var tops: [CGFloat] = []
        var y: CGFloat = 0
        for h in heights {
            tops.append(y)
            y += h
        }
        self.tops = tops
    }

    /// The travel that keeps the held row inside the list: up to the first
    /// slot, down to the last.
    func clamped(_ translation: CGFloat) -> CGFloat {
        min(max(translation, slotOffset(0)), slotOffset(heights.count - 1))
    }

    /// The index the held row lands at when the finger has moved `translation`
    /// points down (negative is up).
    func landing(translation: CGFloat) -> Int {
        let t = clamped(translation)
        let top = tops[from] + t
        let bottom = top + heights[from]
        var landing = from
        for j in (from + 1)..<heights.count where bottom > middle(j) { landing = j }
        for j in (0..<from).reversed() where top < middle(j) { landing = j }
        return landing
    }

    /// How far row `index` stands aside while the held row is over `landing`:
    /// up by the held row's height for each row it has passed going down, down
    /// by it for each row passed going up. The held row itself follows the
    /// finger, so this is 0 for it.
    func displacement(ofRow index: Int, landing: Int) -> CGFloat {
        if landing > from, index > from, index <= landing { return -heights[from] }
        if landing < from, index >= landing, index < from { return heights[from] }
        return 0
    }

    /// The translation that puts the held row exactly in slot `landing`.
    func slotOffset(_ landing: Int) -> CGFloat {
        if landing > from { return heights[(from + 1)...landing].reduce(0, +) }
        if landing < from { return -heights[landing..<from].reduce(0, +) }
        return 0
    }

    /// The list with the item at `from` moved to `to`, everything else in the
    /// order it had.
    static func moving<T>(_ items: [T], from: Int, to: Int) -> [T] {
        guard items.indices.contains(from), items.indices.contains(to), from != to else {
            return items
        }
        var out = items
        let item = out.remove(at: from)
        out.insert(item, at: to)
        return out
    }

    private func middle(_ index: Int) -> CGFloat { tops[index] + heights[index] / 2 }
}

/// A row's swipe to the left, which reveals the red trash button at its
/// right-hand edge (`ReorderableRows`).
///
/// The rules that make a swipe coexist with the page's vertical scrolling and
/// with the ☰ drag, kept pure so they are tested rather than tuned by eye.
enum RowSwipe {
    /// The revealed button's width: two hit targets. One is the minimum a
    /// finger can hit; at that width a red strip reads as a sliver the row
    /// tore on rather than a button that was offered.
    static let revealWidth: CGFloat = 88

    /// How far the finger moves before the swipe decides which way it is
    /// going. Under this nothing slides.
    static let decisionDistance: CGFloat = 10

    /// How much more sideways than up-and-down a movement has to be to count
    /// as a swipe. A finger scrolling the page drifts sideways too; at parity
    /// the page would twitch rows open while being scrolled.
    static let horizontalDominance: CGFloat = 1.5

    /// Past the button's width the row still follows the finger, at this
    /// fraction, so the edge is felt rather than hit.
    static let overdragResistance: CGFloat = 0.3

    enum Axis: Equatable { case horizontal, vertical }

    /// Which way a movement of (dx, dy) from the touch is going, or nil while
    /// it is too short to say. Decided once per touch: a swipe that has
    /// started does not turn into a scroll halfway, or the other way round.
    static func axis(dx: CGFloat, dy: CGFloat) -> Axis? {
        guard max(abs(dx), abs(dy)) >= decisionDistance else { return nil }
        return abs(dx) > abs(dy) * horizontalDominance ? .horizontal : .vertical
    }

    /// Whether a pan that is just starting is a swipe: by the movement when it
    /// is long enough to say (`axis`), by the finger's speed when it is not --
    /// UIKit decides to begin a pan after a few points, and a fast swipe can
    /// get there before `decisionDistance`.
    static func isSideways(translation: CGSize, velocity: CGSize) -> Bool {
        if let axis = axis(dx: translation.width, dy: translation.height) {
            return axis == .horizontal
        }
        return abs(velocity.width) > abs(velocity.height) * horizontalDominance
    }

    /// How far ahead of the lift the row is judged, in seconds at the finger's
    /// speed: a flick carries it this much further.
    static let flickLookahead: CGFloat = 0.1

    /// The sideways travel the row is judged at when the finger lifts.
    static func projected(dx: CGFloat, velocity: CGFloat) -> CGFloat {
        dx + velocity * flickLookahead
    }

    /// Where the row sits while the finger is down: `start` is 0 for a closed
    /// row and `-revealWidth` for an open one, `dx` the finger's sideways
    /// travel. A closed row does not slide right; an open one slides back to
    /// closed and no further.
    static func offset(start: CGFloat, dx: CGFloat) -> CGFloat {
        let raw = start + dx
        if raw > 0 { return 0 }
        if raw < -revealWidth { return -revealWidth + (raw + revealWidth) * overdragResistance }
        return raw
    }

    /// Whether the row rests open when the finger lifts. `predicted` is the
    /// row's offset at the projected travel (`projected`), so a short flick
    /// opens it and a flick back closes it.
    static func restsOpen(predicted: CGFloat) -> Bool {
        predicted < -revealWidth / 2
    }
}
