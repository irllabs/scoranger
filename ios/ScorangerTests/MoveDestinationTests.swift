import XCTest

/// Sending a mark to another bar: the tapped bar, the offset stepper inside
/// it, and the engine's refusal turned back into the choices it names.
///
/// The score has no drag, so there is no drag here. The destination is the pair
/// `ops.move_element` takes -- a bar and an offset in quarter notes from its
/// barline -- and nothing in between converts anything.
final class MoveDestinationTests: XCTestCase {

    private func destination(_ kind: ScoreElementKind = .dynam,
                             _ intent: MoveDestination.Intent = .move)
        -> MoveDestination {
        MoveDestination(intent: intent, kind: kind,
                        source: ScoreAddress(staff: 1, measure: 4, layer: 1,
                                             kind: kind, ordinal: 0))
    }

    // MARK: - Before a bar is tapped

    func testNothingCanBeSentUntilABarIsTapped() {
        let d = destination()
        XCTAssertFalse(d.isReady)
        XCTAssertNil(d.summary)
        XCTAssertEqual(d.prompt,
                       "Move the dynamic: tap the bar it should go to")
    }

    func testDuplicateSaysDuplicate() {
        let d = destination(.fermata, .duplicate)
        XCTAssertEqual(d.prompt,
                       "Duplicate the fermata: tap the bar it should go to")
        XCTAssertEqual(d.confirmTitle, "Duplicate it here")
    }

    // MARK: - The tapped bar

    func testTappingABarAimsAtItsDownbeat() {
        var d = destination()
        d.aim(atBar: 12, barLength: 4)
        XCTAssertTrue(d.isReady)
        XCTAssertEqual(d.offset, 0)
        XCTAssertEqual(d.summary, "bar 12 \u{00B7} downbeat")
    }

    /// A different bar has different onsets and its own length, so nothing
    /// learned about the last one may survive the tap.
    func testTappingAnotherBarForgetsTheLastOne() {
        var d = destination(.fermata)
        d.aim(atBar: 12, barLength: 4)
        d.refused("No note starts at offset 1.5 of measure 12 in 'Violin I'. "
                  + "Fermatas hang off a note, so the destination has to be "
                  + "one; that bar starts notes at [0.0, 1.0, 2.0, 3.0]")
        XCTAssertFalse(d.onsets.isEmpty)
        d.aim(atBar: 13, barLength: 3)
        XCTAssertTrue(d.onsets.isEmpty)
        XCTAssertNil(d.refusal)
        XCTAssertEqual(d.barLength, 3)
    }

    // MARK: - The stepper

    func testTheStepIsAnEighthNote() {
        XCTAssertEqual(MoveDestination.step, 0.5, accuracy: 0.0001)
    }

    func testSteppingWalksTheBar() {
        var d = destination()
        d.aim(atBar: 12, barLength: 4)
        d.step(by: MoveDestination.step)
        XCTAssertEqual(d.offset, 0.5, accuracy: 0.0001)
        XCTAssertEqual(d.summary, "bar 12 \u{00B7} \u{00BD} \u{2669} in")
        d.step(by: MoveDestination.step)
        XCTAssertEqual(d.summary, "bar 12 \u{00B7} 1 \u{2669} in")
        d.step(by: MoveDestination.step)
        XCTAssertEqual(d.summary, "bar 12 \u{00B7} 1\u{00BD} \u{2669} in")
    }

    func testItCannotStepBeforeTheBarline() {
        var d = destination()
        d.aim(atBar: 12, barLength: 4)
        XCTAssertFalse(d.canStep(by: -MoveDestination.step))
        d.step(by: -MoveDestination.step)
        XCTAssertEqual(d.offset, 0)
    }

    /// The last reachable offset is inside the bar, never on the next
    /// barline -- which is a different bar, and what the engine refuses.
    func testItCannotStepPastTheEndOfAKnownBar() {
        var d = destination()
        d.aim(atBar: 12, barLength: 4)
        for _ in 0..<20 { d.step(by: MoveDestination.step) }
        XCTAssertEqual(d.offset, 3.5, accuracy: 0.0001)
        XCTAssertFalse(d.canStep(by: MoveDestination.step))
    }

    /// A score that is not playable has no bar map, so nothing in the app
    /// knows how long a bar is. The stepper still steps; the engine is the
    /// authority either way, and its refusal teaches the length.
    func testAnUnknownBarLengthDoesNotStopTheStepper() {
        var d = destination()
        d.aim(atBar: 12, barLength: nil)
        for _ in 0..<20 { d.step(by: MoveDestination.step) }
        XCTAssertEqual(d.offset, 10, accuracy: 0.0001)
        XCTAssertTrue(d.canStep(by: MoveDestination.step))
    }

    // MARK: - Reading the engine's refusal

    private let noNote =
        "No note starts at offset 1.5 of measure 12 in 'Violin I'. Fermatas "
        + "hang off a note, so the destination has to be one; that bar starts "
        + "notes at [0.0, 1.0, 2.0, 3.0]"

    func testTheOnsetsAreReadOutOfTheRefusal() {
        XCTAssertEqual(MoveDestination.onsets(inRefusal: noNote),
                       [0.0, 1.0, 2.0, 3.0])
    }

    func testAnEmptyBarNamesAnEmptyList() {
        XCTAssertEqual(MoveDestination.onsets(
            inRefusal: "... that bar starts notes at []"), [])
    }

    /// Matched on the engine's own phrase. A refusal that happens to contain
    /// some other bracketed list must not become a row of wrong choices.
    func testAnyOtherBracketedListIsNotMistakenForOnsets() {
        XCTAssertNil(MoveDestination.onsets(
            inRefusal: "Cannot move 'slur'. Can move: ['dynamic', 'harm']"))
    }

    func testTheBarLengthIsReadOutOfTheOtherRefusal() {
        XCTAssertEqual(MoveDestination.barLength(
            inRefusal: "offset 5.0 is not inside measure 12, which is 4.0 "
                     + "quarter notes long"), 4.0)
    }

    /// The whole point: the engine lists the answers, so the chip offers them.
    func testARefusedLandingBecomesTheChoicesTheBarDoesHave() {
        var d = destination(.fermata)
        d.aim(atBar: 12, barLength: 4)
        d.step(by: MoveDestination.step)
        d.step(by: MoveDestination.step)
        d.step(by: MoveDestination.step)
        d.refused(noNote)
        XCTAssertEqual(d.onsets, [0.0, 1.0, 2.0, 3.0])
        let note = try? XCTUnwrap(d.refusalNote)
        XCTAssertEqual(note, "A fermata hangs off a note, and nothing starts "
                       + "at 1\u{00BD} \u{2669} of bar 12. Here is what that "
                       + "bar does start:")
        d.snap(to: 2.0)
        XCTAssertEqual(d.offset, 2.0, accuracy: 0.0001)
        XCTAssertNil(d.refusal, "picking one of them clears the refusal")
    }

    /// An offset past the end of the bar learns the length from the refusal,
    /// so the stepper is clamped from then on.
    func testAnOverlongOffsetLearnsTheBarLength() {
        var d = destination()
        d.aim(atBar: 12, barLength: nil)
        for _ in 0..<12 { d.step(by: MoveDestination.step) }
        d.refused("offset 6.0 is not inside measure 12, which is 4.0 quarter "
                  + "notes long")
        XCTAssertEqual(d.barLength, 4.0)
        XCTAssertEqual(d.refusalNote, "Bar 12 is only 4 \u{2669} long.")
    }

    /// Stepping again is a new aim, so the old refusal stops being shown --
    /// but the onsets stay, because they are facts about the bar.
    func testSteppingClearsTheRefusalAndKeepsTheFacts() {
        var d = destination(.fermata)
        d.aim(atBar: 12, barLength: 4)
        d.refused(noNote)
        d.step(by: MoveDestination.step)
        XCTAssertNil(d.refusalNote)
        XCTAssertEqual(d.onsets, [0.0, 1.0, 2.0, 3.0])
    }

    // MARK: - How an offset is written

    func testQuartersReadTheWayAPlayerWritesThem() {
        XCTAssertEqual(MoveDestination.quarters(0), "0 \u{2669}")
        XCTAssertEqual(MoveDestination.quarters(0.5), "\u{00BD} \u{2669}")
        XCTAssertEqual(MoveDestination.quarters(2), "2 \u{2669}")
        XCTAssertEqual(MoveDestination.quarters(2.5), "2\u{00BD} \u{2669}")
    }
}
