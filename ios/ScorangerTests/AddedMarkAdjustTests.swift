import XCTest

/// The adjust row, on a mark that is not a chord symbol.
///
/// 0.8.2 gave the row the other four kinds `adjust-element` reaches. What
/// differs between them is one thing and one thing only: a chord symbol steps
/// a ladder of POINTS, because the part-wide default beside it is a point
/// value, and every other mark steps MULTIPLES OF THE ENGRAVED DEFAULT --
/// which is the decided answer, and the one the row has to say rather than
/// show a point value nobody asked for.
final class AddedMarkSizeTests: XCTestCase {

    // MARK: - What the row says

    func testAChordSymbolStillReadsInPoints() {
        XCTAssertEqual(ChordAdjustSession.SizeMetric.points.readout(14), "14 pt")
        XCTAssertNil(ChordAdjustSession.SizeMetric.points.caption)
    }

    /// No point value anywhere on a relative mark's row: a point value is true
    /// of this engraving only, and the reader asked for "bigger than the ones
    /// around it".
    func testEveryOtherMarkReadsAsAMultiple() {
        let metric = ChordAdjustSession.SizeMetric.relative
        XCTAssertEqual(metric.readout(100), "1x")
        XCTAssertEqual(metric.readout(140), "1.4x")
        XCTAssertEqual(metric.readout(50), "0.5x")
        XCTAssertEqual(metric.readout(200), "2x")
        for rung in metric.ladder {
            XCTAssertFalse(metric.readout(rung).contains("pt"),
                           "rung \(rung) showed a point value")
        }
    }

    /// And says so in words, because "1.4x" alone does not name what it is a
    /// multiple OF.
    func testTheRelativeRowCarriesACaption() {
        let caption = try? XCTUnwrap(ChordAdjustSession.SizeMetric.relative.caption)
        XCTAssertEqual(caption, "Size is a multiple of the engraved default.")
    }

    func testItIsReadAloudInTheSameTerms() {
        XCTAssertEqual(ChordAdjustSession.SizeMetric.relative.spoken(140),
                       "1.4 times the engraved default")
        XCTAssertEqual(ChordAdjustSession.SizeMetric.points.spoken(14), "14 points")
    }

    // MARK: - Stepping the relative ladder

    private func dynamic(size: Int = 100) -> ChordAdjustSession {
        ChordAdjustSession(size: size, metric: .relative)
    }

    func testTheRelativeLadderStepsInCleanMultiples() {
        var s = dynamic()
        s.resize(.bigger)
        XCTAssertEqual(s.pending.size, 120)
        s.resize(.bigger)
        XCTAssertEqual(s.pending.size, 140)
        s.resize(.smaller); s.resize(.smaller)
        XCTAssertEqual(s.pending.size, 100, "the ladder walks back to 1x exactly")
    }

    func testTheLadderHasEnds() {
        var s = dynamic()
        for _ in 0..<20 { s.resize(.bigger) }
        XCTAssertEqual(s.pending.size, 200)
        XCTAssertFalse(s.canResize(.bigger))
        for _ in 0..<20 { s.resize(.smaller) }
        XCTAssertEqual(s.pending.size, 50)
        XCTAssertFalse(s.canResize(.smaller))
    }

    /// A size set by chat, or by another program, is not on the ladder. It
    /// steps to the nearest rung in the asked-for direction rather than being
    /// snapped on arrival, which would change a value nobody touched.
    func testAnOffLadderSizeStepsRatherThanSnapping() {
        var s = dynamic(size: 150)
        XCTAssertEqual(s.pending.size, 150, "arriving must change nothing")
        s.resize(.bigger)
        XCTAssertEqual(s.pending.size, 160)
    }

    // MARK: - Position is the same behaviour on every kind

    func testNudgingIsTheSameOnADynamic() {
        var s = dynamic()
        s.nudge(.up); s.nudge(.right)
        XCTAssertEqual(s.pending.dy, ChordAdjustSession.stepTenths)
        XCTAssertEqual(s.pending.dx, ChordAdjustSession.stepTenths)
    }

    func testTheClampIsTheSameOnADynamic() {
        var s = dynamic()
        for _ in 0..<40 { s.nudge(.up) }
        XCTAssertEqual(s.pending.dy, ChordAdjustSession.maxVerticalTenths)
        XCTAssertFalse(s.canNudge(.up))
    }

    // MARK: - The way back to the default

    /// The backlog names this as a requirement: any per-element override needs
    /// a way back, or scores accumulate nudges nobody can undo.
    func testResetGoesBackToOneTimesTheDefaultAndNoOffset() {
        var s = ChordAdjustSession(size: 160, committedDX: 10, committedDY: -15,
                                   metric: .relative)
        s.reset()
        let commit = s.commit()
        XCTAssertEqual(commit?.reset, true)
        XCTAssertNil(commit?.size, "a reset names no size: the engine clears all three")
    }

    /// An untouched mark has nothing to put back, and an empty commit would
    /// still cost a version.
    func testResettingAnUntouchedMarkWritesNothing() {
        var s = dynamic()
        s.reset()
        XCTAssertNil(s.commit())
    }

    // MARK: - What reaches the engine

    /// `adjust-element` refuses a scale and a size at once, so the commit has
    /// to say which one it is carrying.
    func testARelativeCommitIsSentAsAScale() {
        var s = dynamic()
        s.resize(.bigger)
        let commit = try? XCTUnwrap(s.commit())
        XCTAssertEqual(commit?.isRelative, true)
        XCTAssertEqual(commit?.size, 120)
    }

    func testAChordSymbolCommitIsStillSentAsASize() {
        var s = ChordAdjustSession(size: 12)
        s.resize(.bigger)
        let commit = try? XCTUnwrap(s.commit())
        XCTAssertEqual(commit?.isRelative, false)
        XCTAssertEqual(commit?.size, 14)
    }

    func testThePendingLineNeverShowsPointsForARelativeMark() {
        var s = dynamic()
        s.nudge(.up)
        s.resize(.bigger)
        let line = s.pendingDescription ?? ""
        XCTAssertTrue(line.contains("1.2x"), line)
        XCTAssertFalse(line.contains("pt"), line)
    }
}

/// The table that crosses the app's kinds with the engine's names.
final class AddedMarkTableTests: XCTestCase {

    /// The engine spells two of them differently from MEI. Every place that
    /// crossed the two used to spell it out again.
    func testEveryAdjustableKindHasAnEngineName() {
        XCTAssertEqual(AddedMark.engineKind(.harm), "harm")
        XCTAssertEqual(AddedMark.engineKind(.dynam), "dynamic")
        XCTAssertEqual(AddedMark.engineKind(.text), "text")
        XCTAssertEqual(AddedMark.engineKind(.fermata), "fermata")
        XCTAssertEqual(AddedMark.engineKind(.articulation), "articulation")
        XCTAssertEqual(AddedMark.engineKind(.verse), "lyric")
        for kind in AddedMark.kinds {
            XCTAssertNotNil(AddedMark.engineKind(kind), "\(kind)")
        }
        // A WORD's size is in its verse name, read off the page by LyricLooks;
        // every other kind's is in the MusicXML ChordAdjustments reads (0.21.0)
        for kind in AddedMark.kinds where kind != .verse {
            XCTAssertNotNil(AddedMark.adjustmentKind(kind), "\(kind)")
        }
        XCTAssertNil(AddedMark.adjustmentKind(.verse))
    }

    /// A note, a slur, a clef: not things `adjust-element` can address.
    func testNothingElseHasOne() {
        for kind in ScoreElementKind.allCases where !AddedMark.kinds.contains(kind) {
            XCTAssertNil(AddedMark.engineKind(kind), "\(kind)")
        }
    }

    /// Which destinations can be refused: a mark that hangs off a note can
    /// only land where a note starts.
    func testTheNoteAttachedKindsAreTheTwoThatHangOffNotes() {
        XCTAssertTrue(AddedMark.isNoteAttached(.fermata))
        XCTAssertTrue(AddedMark.isNoteAttached(.articulation))
        XCTAssertFalse(AddedMark.isNoteAttached(.harm))
        XCTAssertFalse(AddedMark.isNoteAttached(.dynam))
        XCTAssertFalse(AddedMark.isNoteAttached(.text))
    }

    func testOnlyTheChordSymbolStepsPoints() {
        XCTAssertFalse(AddedMark.sizeMetric(.harm).isRelative)
        for kind in AddedMark.kinds where kind != .harm {
            XCTAssertTrue(AddedMark.sizeMetric(kind).isRelative, "\(kind)")
        }
    }
}

/// Which selections the chip offers the row to, now that it is five kinds.
final class AdjustableMarkSelectionTests: XCTestCase {

    private func address(_ kind: ScoreElementKind, measure: Int = 1) -> ScoreAddress {
        ScoreAddress(staff: 1, measure: measure, layer: 1, kind: kind, ordinal: 0)
    }

    func testEveryAddedMarkIsAdjustable() {
        for kind in AddedMark.kinds {
            XCTAssertTrue(ScoreSelection(addresses: [address(kind)]).isAdjustable,
                          "\(kind)")
        }
    }

    /// Still not a mixed selection, and still not a note.
    func testAMixedSelectionOfTwoMarksIsNot() {
        let s = ScoreSelection(addresses: [address(.dynam), address(.fermata)])
        XCTAssertFalse(s.isAdjustable,
                       "two kinds mean two size units in one row")
    }

    func testASlurIsNot() {
        XCTAssertFalse(ScoreSelection(addresses: [address(.slur)]).isAdjustable)
    }
}
