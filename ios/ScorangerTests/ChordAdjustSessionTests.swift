import Foundation
import XCTest

/// Nudging and resizing a selected chord symbol
/// (docs/size-and-position-spec.md, "Interaction — no drag, no modal").
///
/// Taps accumulate as a PENDING adjustment and commit once, on leaving the
/// element. Each tap being its own op would write forty versions for one
/// nudge; that is the whole reason this model exists rather than a direct call.
final class ChordAdjustSessionTests: XCTestCase {

    // MARK: - The step

    /// 0.5 staff space = 5 MusicXML tenths = 1 MEI half-space. Chosen so
    /// nothing in the chain rounds.
    func testOneNudgeIsHalfAStaffSpace() {
        XCTAssertEqual(ChordAdjustSession.stepTenths, 5)
        XCTAssertEqual(ChordAdjustSession.staffSpaces(fromTenths: 5), 0.5, accuracy: 0.0001)
    }

    func testNudgingUpRaisesTheOffset() {
        var s = ChordAdjustSession(size: 12)
        s.nudge(.up)
        XCTAssertEqual(s.pending.dy, 5)
        XCTAssertEqual(s.pending.dx, 0)
    }

    /// MusicXML `relative-y` measures UP, so down is negative. Getting this
    /// backwards sends every symbol the wrong way.
    func testNudgingDownLowersTheOffset() {
        var s = ChordAdjustSession(size: 12)
        s.nudge(.down)
        XCTAssertEqual(s.pending.dy, -5)
    }

    func testNudgesAccumulate() {
        var s = ChordAdjustSession(size: 12)
        s.nudge(.up); s.nudge(.up); s.nudge(.right)
        XCTAssertEqual(s.pending.dy, 10)
        XCTAssertEqual(s.pending.dx, 5)
    }

    func testOppositeNudgesCancel() {
        var s = ChordAdjustSession(size: 12)
        s.nudge(.up); s.nudge(.down)
        XCTAssertEqual(s.pending.dy, 0)
        XCTAssertFalse(s.hasPendingChange, "back where it started is not a change")
    }

    // MARK: - Clamps, so a symbol cannot wander into the system above

    func testVerticalIsClampedToFourStaffSpaces() {
        var s = ChordAdjustSession(size: 12)
        for _ in 0..<40 { s.nudge(.up) }
        XCTAssertEqual(s.pending.dy, 40, "±4 staff spaces is ±40 tenths")
        XCTAssertFalse(s.canNudge(.up), "the button must disable at the limit")
        XCTAssertTrue(s.canNudge(.down))
    }

    func testHorizontalIsClampedToTwoStaffSpaces() {
        var s = ChordAdjustSession(size: 12)
        for _ in 0..<40 { s.nudge(.left) }
        XCTAssertEqual(s.pending.dx, -20)
        XCTAssertFalse(s.canNudge(.left))
        XCTAssertTrue(s.canNudge(.right))
    }

    /// The clamp is on the TOTAL, not on the pending part, or a symbol already
    /// nudged to the limit could be pushed past it in a second session.
    func testTheClampCountsWhatIsAlreadyInTheNotation() {
        var s = ChordAdjustSession(size: 12, committedDX: 0, committedDY: 38)
        s.nudge(.up)
        XCTAssertEqual(s.total.dy, 40)
        XCTAssertFalse(s.canNudge(.up))
    }

    // MARK: - The size ladder

    func testTheLadderIsCleanValues() {
        XCTAssertEqual(ChordAdjustSession.sizeLadder, [8, 9, 10, 11, 12, 14, 16, 18, 20, 24])
    }

    /// 12 is the untouched size, so the ladder always has a home to return to.
    func testTwelveIsTheDefault() {
        XCTAssertTrue(ChordAdjustSession.sizeLadder.contains(12))
    }

    func testBiggerMovesOneRung() {
        var s = ChordAdjustSession(size: 12)
        s.resize(.bigger)
        XCTAssertEqual(s.pending.size, 14)
        s.resize(.bigger)
        XCTAssertEqual(s.pending.size, 16)
    }

    func testSmallerMovesOneRung() {
        var s = ChordAdjustSession(size: 12)
        s.resize(.smaller)
        XCTAssertEqual(s.pending.size, 11)
    }

    func testTheLadderStopsAtItsEnds() {
        var s = ChordAdjustSession(size: 24)
        XCTAssertFalse(s.canResize(.bigger))
        s.resize(.bigger)
        XCTAssertEqual(s.pending.size, 24, "the top rung must not overshoot")

        var small = ChordAdjustSession(size: 8)
        XCTAssertFalse(small.canResize(.smaller))
        small.resize(.smaller)
        XCTAssertEqual(small.pending.size, 8)
    }

    /// A size not on the ladder — set by chat, or by another program — steps to
    /// the nearest rung rather than being snapped silently on arrival.
    func testAnOffLadderSizeStepsToTheNearestRung() {
        var s = ChordAdjustSession(size: 13)
        s.resize(.bigger)
        XCTAssertEqual(s.pending.size, 14)

        var down = ChordAdjustSession(size: 13)
        down.resize(.smaller)
        XCTAssertEqual(down.pending.size, 12)
    }

    // MARK: - Pending, revert, reset

    func testAFreshSessionHasNothingPending() {
        XCTAssertFalse(ChordAdjustSession(size: 12).hasPendingChange)
    }

    func testRevertDiscardsEverythingUncommitted() {
        var s = ChordAdjustSession(size: 12)
        s.nudge(.up); s.resize(.bigger)
        XCTAssertTrue(s.hasPendingChange)
        s.revert()
        XCTAssertFalse(s.hasPendingChange)
        XCTAssertEqual(s.pending.size, 12)
        XCTAssertEqual(s.pending.dy, 0)
    }

    /// Reset is not Revert: it is a real change, back to the inherited size and
    /// no offset, and it has to commit.
    func testResetIsAChangeThatCommits() {
        var s = ChordAdjustSession(size: 18, committedDX: 10, committedDY: -20)
        s.reset()
        XCTAssertTrue(s.hasPendingChange)
        XCTAssertTrue(s.pending.isReset)
    }

    func testResettingSomethingAlreadyDefaultChangesNothing() {
        var s = ChordAdjustSession(size: 12, committedDX: 0, committedDY: 0)
        s.reset()
        XCTAssertFalse(s.hasPendingChange, "nothing to put back")
    }

    // MARK: - What the chip says

    func testThePendingLineNamesTheMoveAndTheSize() {
        var s = ChordAdjustSession(size: 12)
        s.nudge(.up)
        XCTAssertEqual(s.pendingDescription, "0.5 sp up · 12 pt")
    }

    func testAMoveDownSaysDown() {
        var s = ChordAdjustSession(size: 12)
        s.nudge(.down); s.nudge(.down)
        XCTAssertEqual(s.pendingDescription, "1 sp down · 12 pt")
    }

    func testBothAxesAreNamed() {
        var s = ChordAdjustSession(size: 12)
        s.nudge(.up); s.nudge(.right)
        XCTAssertEqual(s.pendingDescription, "0.5 sp up · 0.5 sp right · 12 pt")
    }

    func testASizeOnlyChangeSaysOnlyTheSize() {
        var s = ChordAdjustSession(size: 12)
        s.resize(.bigger)
        XCTAssertEqual(s.pendingDescription, "14 pt")
    }

    func testNothingPendingHasNoDescription() {
        XCTAssertNil(ChordAdjustSession(size: 12).pendingDescription)
    }

    func testResetSaysSo() {
        var s = ChordAdjustSession(size: 18, committedDX: 0, committedDY: 10)
        s.reset()
        XCTAssertEqual(s.pendingDescription, "reset")
    }

    // MARK: - What the engine is asked for

    /// Absolute values, because that is what the notation stores and what
    /// another program reads. The UI is relative; the file is not.
    func testTheCommitCarriesAbsoluteValues() {
        var s = ChordAdjustSession(size: 12, committedDX: 5, committedDY: 0)
        s.nudge(.up); s.resize(.bigger)
        let commit = s.commit()
        XCTAssertEqual(commit?.size, 14)
        XCTAssertEqual(commit?.offsetX, 5, "an untouched axis keeps what it had")
        XCTAssertEqual(commit?.offsetY, 5)
        XCTAssertFalse(commit?.reset ?? true)
    }

    func testNothingPendingCommitsNothing() {
        var s = ChordAdjustSession(size: 12)
        XCTAssertNil(s.commit(), "an empty commit would still cost a version")
    }

    func testAResetCommitsAsAReset() {
        var s = ChordAdjustSession(size: 18, committedDX: 4, committedDY: 4)
        s.reset()
        let commit = s.commit()
        XCTAssertTrue(commit?.reset ?? false)
    }
}

/// The flag the spec raised: nudge → commit → re-render → nudge again. If the
/// selection is lost on the commit, the second nudge has nothing to act on and
/// adjusting an element becomes a one-shot.
final class AdjustKeepsTheSelectionTests: XCTestCase {

    /// An adjustment is an op like any other: a NEW version of the SAME score.
    /// Addresses are durable (staff/measure/layer/kind#ordinal), so they are
    /// looked up again in the new engraving rather than thrown away.
    func testTheSelectionSurvivesAnAdjustment() {
        XCTAssertTrue(ScoreSelection.survivesReRender(from: "quartet/v004",
                                                      to: "quartet/v005",
                                                      userPickedVersion: false),
                      "a nudge would be a one-shot: the commit re-renders and "
                      + "the next nudge would have nothing selected")
    }

    /// Several nudges in a row, each committing its own version, keep the same
    /// element selected the whole way.
    func testASequenceOfAdjustmentsKeepsIt() {
        var key = "quartet/v004"
        for next in ["quartet/v005", "quartet/v006", "quartet/v007"] {
            XCTAssertTrue(ScoreSelection.survivesReRender(from: key, to: next,
                                                          userPickedVersion: false),
                          "lost the selection going \(key) -> \(next)")
            key = next
        }
    }

    /// But not across arrangements: that is a different subject.
    func testItDoesNotFollowToAnotherArrangement() {
        XCTAssertFalse(ScoreSelection.survivesReRender(from: "quartet/v004",
                                                       to: "accordion/v001",
                                                       userPickedVersion: false))
    }

    /// And not when the reader deliberately went to an older version — they are
    /// looking at different bars now, whatever the addresses say.
    func testItDoesNotSurviveDeliberatelyChangingVersion() {
        XCTAssertFalse(ScoreSelection.survivesReRender(from: "quartet/v004",
                                                       to: "quartet/v002",
                                                       userPickedVersion: true))
    }
}

/// When the chip offers its position-and-size row.
final class AdjustableSelectionTests: XCTestCase {

    private func address(_ kind: ScoreElementKind, measure: Int = 1) -> ScoreAddress {
        ScoreAddress(staff: 1, measure: measure, layer: 1, kind: kind, ordinal: 0)
    }

    func testAChordSymbolIsAdjustable() {
        XCTAssertTrue(ScoreSelection(addresses: [address(.harm)]).isAdjustable)
    }

    func testSeveralChordSymbolsAre() {
        let s = ScoreSelection(addresses: [address(.harm, measure: 1),
                                           address(.harm, measure: 2)])
        XCTAssertTrue(s.isAdjustable)
    }

    func testANoteIsNot() {
        XCTAssertFalse(ScoreSelection(addresses: [address(.note)]).isAdjustable)
    }

    /// A mixed selection gets no row. Offering a control that silently skips
    /// half of what is selected is worse than offering none.
    func testAMixedSelectionIsNot() {
        let s = ScoreSelection(addresses: [address(.harm), address(.note)])
        XCTAssertFalse(s.isAdjustable)
    }

    func testAnEmptySelectionIsNot() {
        XCTAssertFalse(ScoreSelection(addresses: []).isAdjustable)
    }

    /// Once its op is written the session has nothing pending, and says what
    /// the notation now carries -- or the next selection change writes it
    /// again (0.21.0).
    func testACommittedSessionHasNothingLeftToWrite() {
        var s = ChordAdjustSession(size: 100, committedDX: 10, committedDY: 0,
                                   metric: .relative)
        s.resize(.bigger)
        s.nudge(.up)
        let commit = s.commit()
        XCTAssertNotNil(commit)
        var after = s.afterCommit()
        XCTAssertFalse(after.hasPendingChange)
        XCTAssertNil(after.commit(), "nothing is written twice")
        XCTAssertEqual(after.pending.size, commit?.size)
        XCTAssertEqual(after.total.dx, commit?.offsetX)
        XCTAssertEqual(after.total.dy, commit?.offsetY)
        s.reset()
        XCTAssertEqual(s.afterCommit().pending.size, ChordAdjustSession.SizeMetric.relative.defaultValue)
    }
}

