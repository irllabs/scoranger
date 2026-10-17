import Foundation

/// One element's worth of nudging and resizing, held until it is committed.
///
/// The spec's rule (docs/size-and-position-spec.md, "Committing"): each tap
/// must NOT be an op. Taps accumulate here and commit once, when the reader
/// leaves the element — deselects it, selects another, leaves the score, or
/// stops for three seconds. Committing per tap would write a version per tap,
/// and the notation is versioned, so a single nudge would cost forty of them.
///
/// Preview is free: `ChordAdjustments` already applies size and offset in the
/// app, so pending values draw locally and only the commit reaches the engine.
///
/// ## Five kinds, one session
///
/// It was written for chord symbols and 0.8.2 gave it the other four marks
/// `adjust-element` reaches. The only thing that differs between them is how
/// SIZE is counted: a chord symbol steps a ladder of point values, because the
/// part-wide default beside it is a point value; everything else steps a
/// ladder of multiples of the engraved default, which is the decided answer
/// and the one the row says out loud. `SizeMetric` is that difference, and it
/// is the whole of it -- the step, the clamps, the pending model and the
/// commit are one behaviour for all five.
struct ChordAdjustSession: Equatable {

    /// How one kind of mark's size is counted, and how it is said.
    struct SizeMetric: Equatable {
        /// The rungs, in the unit below.
        let ladder: [Int]
        /// The rung an untouched mark sits at, and the one `reset` returns to.
        let defaultValue: Int
        /// True when a rung is a PERCENTAGE of the engraved default rather
        /// than a point size. It decides what `Commit.size` means, so the
        /// caller sends `scale` rather than `size`.
        let isRelative: Bool

        /// Points, for chord symbols. Clean values rather than a multiplier: a
        /// multiplier writes 13.5 pt and then 15.19 pt into the notation and
        /// makes "put it back" impossible to hit exactly.
        static let points = SizeMetric(ladder: [8, 9, 10, 11, 12, 14, 16, 18, 20, 24],
                                       defaultValue: 12, isRelative: false)

        /// Multiples of the engraved default, for every other mark. Clean
        /// again, for the same reason -- these are tenths, so the ladder can
        /// be walked back to 1x exactly.
        static let relative = SizeMetric(
            ladder: [50, 60, 70, 80, 90, 100, 120, 140, 160, 180, 200],
            defaultValue: 100, isRelative: true)

        /// What the row shows: `14 pt`, or `1.4x` -- never a point value for a
        /// mark whose size is a proportion, because the number would be true
        /// of this engraving only.
        func readout(_ value: Int) -> String {
            guard isRelative else { return "\(value) pt" }
            let times = Double(value) / 100
            return times == times.rounded() ? "\(Int(times))x" : "\(times)x"
        }

        /// The same, read aloud.
        func spoken(_ value: Int) -> String {
            isRelative ? "\(readout(value).dropLast()) times the engraved default"
                       : "\(value) points"
        }

        /// The one line the row carries under it, or nil where the number
        /// speaks for itself.
        var caption: String? {
            isRelative ? "Size is a multiple of the engraved default." : nil
        }
    }

    enum Direction { case up, down, left, right }
    enum SizeStep { case bigger, smaller }

    /// Half a staff space, in MusicXML tenths. Five is exact in every unit
    /// this chain uses: 0.5 staff space, 5 tenths, 1 MEI half-space. Nothing
    /// rounds, which is why it is not 4 or 6.
    static let stepTenths: Int = 5

    /// Clamps, in tenths. A symbol that could travel further would wander into
    /// the system above and read as belonging to it.
    static let maxVerticalTenths: Int = 40    // ±4 staff spaces
    static let maxHorizontalTenths: Int = 20  // ±2 staff spaces

    /// The chord symbol's ladder, which the part-wide default walks too.
    static let sizeLadder: [Int] = SizeMetric.points.ladder

    /// How this mark's size is counted. Chord symbols step points; every
    /// other mark steps multiples of the engraved default.
    let metric: SizeMetric

    /// What is already in the notation.
    private let committedSize: Int
    private let committedDX: Int
    private let committedDY: Int

    /// What the reader has asked for but not yet spent a version on.
    private(set) var pending: Pending

    struct Pending: Equatable {
        var size: Int
        var dx: Int
        var dy: Int
        var isReset: Bool = false
    }

    /// The absolute values the engine will be given.
    struct Commit: Equatable {
        /// The rung, in the session's own unit. `isRelative` says which:
        /// points go to `adjust-element --size`, percentages to `--scale`.
        var size: Int?
        var offsetX: Int?
        var offsetY: Int?
        var reset: Bool
        var isRelative: Bool = false
    }

    init(size: Int, committedDX: Int = 0, committedDY: Int = 0,
         metric: SizeMetric = .points) {
        self.metric = metric
        self.committedSize = size
        self.committedDX = committedDX
        self.committedDY = committedDY
        self.pending = Pending(size: size, dx: 0, dy: 0)
    }

    /// Offset including what the notation already carries — what the clamp is
    /// measured against, so a symbol nudged to the limit yesterday cannot be
    /// pushed past it today.
    var total: (dx: Int, dy: Int) {
        (committedDX + pending.dx, committedDY + pending.dy)
    }

    var hasPendingChange: Bool {
        pending.isReset || pending.dx != 0 || pending.dy != 0 || pending.size != committedSize
    }

    // MARK: - Position

    /// False only when the symbol is ALREADY at the bound. A tap from just
    /// short of the limit still moves -- it clamps to the limit rather than
    /// being refused, or the last half-step before the edge is unreachable and
    /// the button lies about why it did nothing.
    func canNudge(_ direction: Direction) -> Bool {
        let (dx, dy) = total
        switch direction {
        case .up:    return dy < Self.maxVerticalTenths
        case .down:  return dy > -Self.maxVerticalTenths
        case .right: return dx < Self.maxHorizontalTenths
        case .left:  return dx > -Self.maxHorizontalTenths
        }
    }

    /// MusicXML `relative-y` measures UP, so down is negative.
    ///
    /// The clamp is on the TOTAL -- what the notation already carries plus what
    /// is pending -- so a symbol nudged to the edge in an earlier sitting
    /// cannot be pushed past it in this one.
    mutating func nudge(_ direction: Direction) {
        guard canNudge(direction) else { return }
        pending.isReset = false
        let (dx, dy) = total
        switch direction {
        case .up:
            pending.dy += min(Self.stepTenths, Self.maxVerticalTenths - dy)
        case .down:
            pending.dy -= min(Self.stepTenths, dy + Self.maxVerticalTenths)
        case .right:
            pending.dx += min(Self.stepTenths, Self.maxHorizontalTenths - dx)
        case .left:
            pending.dx -= min(Self.stepTenths, dx + Self.maxHorizontalTenths)
        }
    }

    // MARK: - Size

    func canResize(_ step: SizeStep) -> Bool {
        nextRung(from: pending.size, step: step) != nil
    }

    mutating func resize(_ step: SizeStep) {
        guard let next = nextRung(from: pending.size, step: step) else { return }
        pending.isReset = false
        pending.size = next
    }

    /// The next rung, or nil at the ends. A size that is not on the ladder --
    /// set by chat, or by another program -- steps to the nearest rung in the
    /// asked-for direction rather than being snapped on arrival, which would
    /// change a value the reader never touched.
    private func nextRung(from size: Int, step: SizeStep) -> Int? {
        switch step {
        case .bigger: return metric.ladder.first { $0 > size }
        case .smaller: return metric.ladder.last { $0 < size }
        }
    }

    // MARK: - Undoing

    /// Discard everything uncommitted. Not a change; nothing reaches the engine.
    mutating func revert() {
        pending = Pending(size: committedSize, dx: 0, dy: 0)
    }

    /// Back to the inherited size and no offset. This IS a change and commits,
    /// unless the element was already untouched.
    mutating func reset() {
        guard committedDX != 0 || committedDY != 0
                || committedSize != metric.defaultValue else {
            pending = Pending(size: committedSize, dx: 0, dy: 0)
            return
        }
        pending = Pending(size: metric.defaultValue,
                          dx: -committedDX, dy: -committedDY, isReset: true)
    }

    /// The size an untouched chord symbol engraves at, mirroring
    /// `ChordAdjustments.defaultChordPoints`.
    static let defaultSize = SizeMetric.points.defaultValue

    // MARK: - Committing

    /// The one op this session produces, or nil when there is nothing to write.
    /// An empty commit would still cost a version.
    mutating func commit() -> Commit? {
        guard hasPendingChange else { return nil }
        if pending.isReset {
            return Commit(size: nil, offsetX: nil, offsetY: nil, reset: true,
                          isRelative: metric.isRelative)
        }
        let (dx, dy) = total
        return Commit(size: pending.size,
                      offsetX: dx,
                      offsetY: dy,
                      reset: false,
                      isRelative: metric.isRelative)
    }

    /// The session as it stands once `commit()`'s op has been written: what
    /// was pending is now what the notation carries, and nothing is pending.
    ///
    /// `commit()` returns the op and changes nothing, and the session it came
    /// from went on reporting the change as pending -- so the next selection
    /// change, or Move..., wrote it AGAIN, and after a move the second write
    /// was addressed to the bar the mark had just left (0.21.0, found
    /// photographing a word: "No lyric #0 in measure 1").
    func afterCommit() -> ChordAdjustSession {
        if pending.isReset {
            return ChordAdjustSession(size: metric.defaultValue, metric: metric)
        }
        let (dx, dy) = total
        return ChordAdjustSession(size: pending.size, committedDX: dx, committedDY: dy,
                                  metric: metric)
    }

    // MARK: - What the chip says

    static func staffSpaces(fromTenths tenths: Int) -> Double {
        Double(tenths) / 10.0
    }

    /// `0.5 sp up · 14 pt`, or nil when nothing is pending.
    var pendingDescription: String? {
        guard hasPendingChange else { return nil }
        if pending.isReset { return "reset" }
        var parts: [String] = []
        if pending.dy != 0 {
            parts.append("\(Self.spaces(abs(pending.dy))) sp \(pending.dy > 0 ? "up" : "down")")
        }
        if pending.dx != 0 {
            parts.append("\(Self.spaces(abs(pending.dx))) sp \(pending.dx > 0 ? "right" : "left")")
        }
        parts.append(metric.readout(pending.size))
        return parts.joined(separator: " · ")
    }

    /// `0.5`, `1`, `1.5` — never `1.0`, which reads as a measurement nobody made.
    private static func spaces(_ tenths: Int) -> String {
        let value = staffSpaces(fromTenths: tenths)
        return value == value.rounded() ? String(Int(value)) : String(value)
    }
}
