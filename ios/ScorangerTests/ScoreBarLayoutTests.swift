import CoreGraphics
import XCTest

/// #60: the way out of the score may never be squeezed off the bar.
final class ScoreBarLayoutTests: XCTestCase {
    /// The widths that actually matter, bar-width (not screen) in points.
    /// The narrowest bar the app has to seat: an iPhone SE.
    private let iPhoneSE: CGFloat = 375
    private let iPhonePortrait: CGFloat = 390
    private let iPhoneLandscape: CGFloat = 844
    private let iPadPortrait: CGFloat = 834
    private let iPadLandscape: CGFloat = 1210

    /// The bug, stated as a test: whatever else goes, ✕ and the actions fit.
    func testEveryRealWidthSeatsTheWayOutAndTheActions() {
        for width in [iPhoneSE, iPhonePortrait, iPhoneLandscape,
                      iPadPortrait, iPadLandscape] {
            let fit = ScoreBarLayout.fit(barWidth: width)
            XCTAssertTrue(ScoreBarLayout.fits(fit, in: width),
                          "the bar overflows at \(width)pt: \(fit) — this is how ✕ "
                          + "got pushed off the phone")
        }
    }

    /// A phone drops the extras but keeps the score leaveable and usable.
    func testAPhoneKeepsTheEssentialsAndDropsTheExtras() {
        let fit = ScoreBarLayout.fit(barWidth: iPhonePortrait)
        XCTAssertFalse(fit.showsVersions, "the version count is what pushed ✕ off")
        XCTAssertEqual(fit.layoutCells, 2, "a spread across 390pt is two thumbnails")
        XCTAssertFalse(fit.showsTransportToggle,
                       "the toggle yields on a phone -- Options still carries it")
        XCTAssertTrue(ScoreBarLayout.fits(fit, in: iPhonePortrait))
    }

    /// An iPad seats the transport toggle, which is the point of putting it on
    /// the bar: the switch that was two screens down is now one tap away.
    func testAnIPadSeatsTheTransportToggle() {
        XCTAssertTrue(ScoreBarLayout.fit(barWidth: iPadLandscape).showsTransportToggle)
        XCTAssertTrue(ScoreBarLayout.fit(barWidth: iPadPortrait).showsTransportToggle)
    }

    /// It yields AFTER the version count and BEFORE a layout cell: the layout
    /// control is the only route to continuous, and the toggle is not the only
    /// route to anything.
    func testTheTransportToggleYieldsBeforeALayoutCell() {
        var seenTransportDrop = false
        for width in stride(from: CGFloat(1400), through: 300, by: -5) {
            let fit = ScoreBarLayout.fit(barWidth: width)
            if !fit.showsTransportToggle { seenTransportDrop = true }
            if fit.layoutCells < 3 {
                XCTAssertTrue(seenTransportDrop,
                              "a layout cell went before the transport toggle at "
                              + "\(width)pt")
            }
        }
        XCTAssertTrue(seenTransportDrop)
    }

    /// Everything, Print included (0.17.0).
    private var wholeBar: ScoreBarLayout.Fit {
        var fit = ScoreBarLayout.Fit(showsVersions: true, showsAddToSetlist: true,
                                     layoutCells: 3)
        fit.showsPrint = true
        return fit
    }

    func testAnIPadShowsTheWholeBar() {
        XCTAssertEqual(ScoreBarLayout.fit(barWidth: iPadLandscape), wholeBar)
    }

    /// The stated order: the version count yields before the switches, and the
    /// switches before the spread cell.
    ///
    /// It used to begin with the mode chip, which was item 8 and went first.
    /// With the chip gone (0.6.10) the ladder starts one rung lower and the
    /// same invariant is asserted over what is left.
    func testThingsYieldInTheStatedOrder() {
        var seenVersionsDrop = false, seenSwitchDrop = false, seenCellDrop = false
        var width = ScoreBarLayout.essentials + ScoreBarLayout.threeCells
            + ScoreBarLayout.versionsWidth + ScoreBarLayout.switchesWidth
            + ScoreBarLayout.titleMinimum + ScoreBarLayout.numeralWidth
        while width > 200 {
            let fit = ScoreBarLayout.fit(barWidth: width)
            if !fit.showsVersions { seenVersionsDrop = true }
            if !fit.showsTransportToggle {
                seenSwitchDrop = true
                XCTAssertTrue(seenVersionsDrop,
                              "a switch went before the version count did")
            }
            if fit.layoutCells < 3 {
                seenCellDrop = true
                XCTAssertTrue(seenSwitchDrop,
                              "a layout cell went before the switches did")
            }
            width -= 10
        }
        XCTAssertTrue(seenVersionsDrop && seenSwitchDrop && seenCellDrop,
                      "the sweep should have exercised every step")
    }

    /// #62: with the version count already yielded, the title block is the
    /// only route to the version dropdown — so on a phone the title's
    /// COMPANIONS go rather than the title itself.
    func testAPhoneKeepsTheTitleAndDropsWhatSitsBesideIt() {
        for width in [iPhoneSE, iPhonePortrait] {
            let fit = ScoreBarLayout.fit(barWidth: width)
            XCTAssertFalse(fit.showsNumeral, "the #N badge should yield at \(width)")
            XCTAssertFalse(fit.showsSubtitle, "the subtitle should yield at \(width)")
            XCTAssertTrue(fit.titleExpands,
                          "the title must take the slack, or the spacers do and "
                          + "it collapses to an ellipsis")
            XCTAssertTrue(ScoreBarLayout.fits(fit, in: width))
        }
    }

    /// And an iPad keeps them: it has the room, and the title stays centred.
    func testAnIPadKeepsTheNumeralAndSubtitle() {
        let fit = ScoreBarLayout.fit(barWidth: iPadLandscape)
        XCTAssertTrue(fit.showsNumeral)
        XCTAssertTrue(fit.showsSubtitle)
        XCTAssertFalse(fit.titleExpands, "the spacers still centre it on an iPad")
    }

    /// Narrower and narrower must never start putting things BACK.
    func testNothingReappearsAsTheBarNarrows() {
        var previous = ScoreBarLayout.fit(barWidth: 1400)
        for width in stride(from: CGFloat(1400), through: 300, by: -5) {
            let fit = ScoreBarLayout.fit(barWidth: width)
            XCTAssertFalse(fit.showsVersions && !previous.showsVersions,
                           "the version count came back at \(width)pt")
            XCTAssertLessThanOrEqual(fit.layoutCells, previous.layoutCells,
                                     "a layout cell came back at \(width)pt")
            XCTAssertFalse(fit.showsNumeral && !previous.showsNumeral,
                           "the numeral came back at \(width)pt")
            XCTAssertFalse(fit.showsSubtitle && !previous.showsSubtitle,
                           "the subtitle came back at \(width)pt")
            XCTAssertFalse(fit.showsTransportToggle && !previous.showsTransportToggle,
                           "the transport toggle came back at \(width)pt")
            previous = fit
        }
    }

    /// Before the bar has been measured, show everything: a stripped bar that
    /// fills in on the second frame reads as a glitch.
    func testAnUnmeasuredBarShowsEverything() {
        XCTAssertEqual(ScoreBarLayout.fit(barWidth: 0), wholeBar)
    }

    // MARK: - The two switches (0.6.8)

    /// They yield as ONE step. A bar showing Performance mode and not Show
    /// transport, or the other way round, reads as arbitrary -- and Options
    /// carries whichever the bar has not got, so a half-yield would leave one
    /// switch in both places.
    func testTheTwoSwitchesAreNeverSplit() {
        for width in stride(from: CGFloat(1400), through: 260, by: -1) {
            let fit = ScoreBarLayout.fit(barWidth: width)
            XCTAssertEqual(fit.showsTransportToggle, fit.showsPerformanceToggle,
                           "the switches came apart at \(width)pt: \(fit)")
        }
    }

    /// An iPad seats both, which is the point of the move: the two switches
    /// that were two screens from the music are one tap away.
    func testAnIPadSeatsBothSwitches() {
        for width in [iPadPortrait, iPadLandscape] {
            let fit = ScoreBarLayout.fit(barWidth: width)
            XCTAssertTrue(fit.showsPerformanceToggle, "no Performance mode at \(width)")
            XCTAssertTrue(fit.showsTransportToggle, "no Show transport at \(width)")
            XCTAssertTrue(ScoreBarLayout.fits(fit, in: width),
                          "the bar overflows at \(width) with both switches on it")
        }
    }

    /// Nothing comes back as the bar narrows, the performance toggle included.
    func testThePerformanceToggleNeverReappears() {
        var previous = ScoreBarLayout.fit(barWidth: 1400)
        for width in stride(from: CGFloat(1400), through: 300, by: -5) {
            let fit = ScoreBarLayout.fit(barWidth: width)
            XCTAssertFalse(fit.showsPerformanceToggle && !previous.showsPerformanceToggle,
                           "the performance toggle came back at \(width)pt")
            previous = fit
        }
    }

    // MARK: - The transcription chip (0.6.8)

    /// It is drawn only while OMR is running. A chip that is always there says
    /// nothing.
    func testTheChipIsAbsentUnlessOMRIsRunning() {
        for width in [iPhoneSE, iPhonePortrait, iPadPortrait, iPadLandscape] {
            XCTAssertFalse(ScoreBarLayout.fit(barWidth: width).showsOMRProgress,
                           "a chip at \(width) with nothing transcribing")
        }
    }

    /// An iPad seats it, and seating it does not push anything off the bar.
    func testAnIPadSeatsTheChipWithoutOverflowing() {
        for width in [iPadPortrait, iPadLandscape] {
            let fit = ScoreBarLayout.fit(barWidth: width, omrBusy: true)
            XCTAssertTrue(fit.showsOMRProgress, "no transcription chip at \(width)")
            XCTAssertTrue(ScoreBarLayout.fits(fit, in: width),
                          "the bar overflows at \(width) with the chip on it: \(fit)")
        }
    }

    /// The chip outranks both switches: while a transcription runs it is the
    /// only sign in the score view that anything is happening, and a switch is
    /// a shortcut to something reachable elsewhere.
    func testTheChipIsSeatedBeforeTheSwitchesAre() {
        // A width that seats the switches with nothing running.
        let width = ScoreBarLayout.essentials + ScoreBarLayout.threeCells
            + ScoreBarLayout.versionsWidth + ScoreBarLayout.switchesWidth
            + ScoreBarLayout.titleMinimum
        XCTAssertTrue(ScoreBarLayout.fit(barWidth: width).showsTransportToggle,
                      "the fixture is wrong: this width should seat the switches")
        let busy = ScoreBarLayout.fit(barWidth: width, omrBusy: true)
        XCTAssertTrue(busy.showsOMRProgress, "the chip yielded to a switch")
        XCTAssertFalse(busy.showsTransportToggle,
                       "the switches should have made room for the chip")
    }

    /// And it yields itself rather than pushing ✕ off the bar. #60 is the rule
    /// nothing on this bar is exempt from, the newest thing on it least of all.
    func testANarrowBarYieldsTheChipRatherThanTheWayOut() {
        for width in [iPhoneSE, iPhonePortrait] {
            let fit = ScoreBarLayout.fit(barWidth: width, omrBusy: true)
            XCTAssertFalse(fit.showsOMRProgress,
                           "a phone cannot seat the chip at \(width): "
                           + "ContentView draws it over the canvas instead")
            XCTAssertTrue(ScoreBarLayout.fits(fit, in: width),
                          "the bar overflows at \(width) while transcribing")
        }
    }

    /// Whatever the width, transcribing or not, the bar fits. This is the whole
    /// of #60 as one sweep, and it is a sweep rather than five widths because
    /// five widths missed a 40pt band where the thresholds and `fits` disagreed
    /// about the numeral for two releases.
    ///
    /// From 375, the narrowest bar the app has to seat: below that the last
    /// fallback has nothing left to give up and cannot fit anything at all.
    func testNoWidthOverflowsWhetherOrNotSomethingIsTranscribing() {
        for busy in [false, true] {
            for width in stride(from: iPhoneSE, through: 1400, by: 1) {
                let fit = ScoreBarLayout.fit(barWidth: width, omrBusy: busy)
                XCTAssertTrue(ScoreBarLayout.fits(fit, in: width),
                              "the bar overflows at \(width)pt (omrBusy: \(busy)): \(fit)")
            }
        }
    }

    // MARK: - The mode chip is gone (0.6.10)

    /// Ali asked for the "Pencil: select" chip off the bar.
    ///
    /// Asserted as WIDTH rather than as a flag, because the flag is what the
    /// change removes and a test written against it could not outlive it. This
    /// says the same thing from outside: the widest bar the layout produces
    /// must fit in a width that reserves nothing for a chip.
    func testTheWidestBarReservesNoRoomForAModeChip() {
        let widest = ScoreBarLayout.fit(barWidth: 2000)
        // `editWidth` is counted separately since 0.6.14: ⌖ joined the bar's
        // fixed actions and the pencil moved out of `essentials` into the
        // yield order. The sum is the same bar it always was.
        let withoutAChip = ScoreBarLayout.essentials + ScoreBarLayout.editWidth
            + ScoreBarLayout.titleMinimum
            + ScoreBarLayout.numeralWidth + ScoreBarLayout.threeCells
            + ScoreBarLayout.versionsWidth + ScoreBarLayout.switchesWidth
            + ScoreBarLayout.addToSetlistWidth + ScoreBarLayout.printWidth
            + ScoreBarLayout.originNameWidth
        XCTAssertTrue(ScoreBarLayout.fits(widest, in: withoutAChip),
                      "the bar still reserves width for something it no longer draws")
    }

    /// And the version count yields SECOND, not first.
    ///
    /// When the chip went in 0.6.10 the count became the first thing a
    /// narrowing bar gave up. 0.6.11 seated the add-to-set-list + below it, so
    /// the count is one rung up again -- and the assertion that matters is
    /// unchanged in spirit: nothing ABOVE the count in the order may go before
    /// it does.
    func testTheVersionCountYieldsSecondAndNothingAboveItGoesFirst() throws {
        let widest = ScoreBarLayout.fit(barWidth: 2000)
        XCTAssertTrue(widest.showsVersions)

        var seen: [ScoreBarLayout.Fit] = []
        var width = 2000.0
        while width > ScoreBarLayout.floor {
            let fit = ScoreBarLayout.fit(barWidth: width)
            if seen.last != fit { seen.append(fit) }
            if !fit.showsVersions { break }
            width -= 1
        }
        // widest, then the + gone, then the count gone: three distinct fits.
        // Everything, then without the origin's name beside the ‹ [C6], then
        // without the +, then without Print (0.17.0; More carries it), then
        // without the count: five fits. The name is a courtesy about where
        // the reader was; the count is a shortcut to versions. All of them go
        // before anything the reader cannot reach elsewhere.
        XCTAssertEqual(seen.count, 5, "the count did not yield fourth: \(seen)")
        let dropped = try XCTUnwrap(seen.last)
        XCTAssertFalse(dropped.showsVersions)
        XCTAssertFalse(dropped.showsAddToSetlist, "the + should already be gone")
        XCTAssertFalse(dropped.showsOriginName, "the origin's name should already be gone")
        XCTAssertEqual(dropped.layoutCells, widest.layoutCells,
                       "a layout cell went before the version count did")
        XCTAssertEqual(dropped.showsTransportToggle, widest.showsTransportToggle,
                       "a switch went before the version count did")
    }


    // MARK: - Add to set list (0.6.11 #1)

    /// The + that puts this arrangement in a set list. On a wide bar it is
    /// there; it is the FIRST thing a narrowing bar gives up.
    func testAWideBarSeatsTheAddToSetlistButton() {
        XCTAssertTrue(ScoreBarLayout.fit(barWidth: iPadLandscape).showsAddToSetlist)
    }

    /// It yields before the version count, which was the first to go until
    /// this was added.
    ///
    /// The reasoning, since a yield order is a claim about what matters least:
    /// every op in this app makes a version, so the version count is a
    /// shortcut to something a reader reaches constantly; putting an
    /// arrangement in a set list is organising, done occasionally, and the
    /// library's own set list picker still does it. Dropping the + drops a
    /// shortcut, never the feature -- the same test §7 has to pass.
    func testTheAddToSetlistButtonIsTheFirstThingToGo() throws {
        let widest = ScoreBarLayout.fit(barWidth: 2000)
        XCTAssertTrue(widest.showsAddToSetlist)

        var firstChange: ScoreBarLayout.Fit?
        var width = 2000.0
        while width > ScoreBarLayout.floor {
            let fit = ScoreBarLayout.fit(barWidth: width)
            if fit != widest { firstChange = fit; break }
            width -= 1
        }
        let changed = try XCTUnwrap(firstChange, "the bar never yielded anything")
        // 0.8 [C6]: the ‹ carries the origin's NAME, and that name is the
        // first thing to go -- a courtesy about where the reader was, ahead
        // of every shortcut. The + goes second, and the version count
        // survives both.
        XCTAssertFalse(changed.showsOriginName, "something went before the origin's name did")
        XCTAssertTrue(changed.showsAddToSetlist, "the + went before the origin's name did")
        XCTAssertTrue(changed.showsVersions, "the version count went before the name did")

        var secondChange: ScoreBarLayout.Fit?
        while width > ScoreBarLayout.floor {
            let fit = ScoreBarLayout.fit(barWidth: width)
            if fit != changed { secondChange = fit; break }
            width -= 1
        }
        let next = try XCTUnwrap(secondChange, "the bar yielded only the name")
        XCTAssertFalse(next.showsAddToSetlist, "something went before the + did")
        XCTAssertTrue(next.showsVersions, "the version count went before the + did")
    }

    /// A phone does not seat it, and that is allowed precisely because the
    /// library still offers the same operation from the other direction.
    func testAPhoneDropsIt() {
        XCTAssertFalse(ScoreBarLayout.fit(barWidth: iPhonePortrait).showsAddToSetlist)
    }

    /// It never comes back as the bar narrows.
    func testTheAddToSetlistButtonNeverReappears() {
        var previous = ScoreBarLayout.fit(barWidth: 1400)
        for width in stride(from: CGFloat(1400), through: 300, by: -5) {
            let fit = ScoreBarLayout.fit(barWidth: width)
            XCTAssertFalse(fit.showsAddToSetlist && !previous.showsAddToSetlist,
                           "the + came back at \(width)pt")
            previous = fit
        }
    }


}

/// One switch, one place, at every width (0.6.8).
///
/// Performance mode and Show transport are top-bar controls now, and
/// `ScoreOptionsScreen` renders each one only where `Fit` says the bar could
/// not seat it. Both views read ONE `Fit` from ONE measurement, which is what
/// this pins: a width where a switch is in both places is a control that will
/// drift, and a width where it is in neither is a feature that is gone.
final class SwitchesHaveExactlyOneHomeTests: XCTestCase {

    func testEveryWidthPutsEachSwitchInExactlyOnePlace() {
        for busy in [false, true] {
            for width in stride(from: CGFloat(320), through: 1400, by: 1) {
                let fit = ScoreBarLayout.fit(barWidth: width, omrBusy: busy)
                // The two properties the two views actually read.
                XCTAssertNotEqual(fit.showsPerformanceToggle,
                                  fit.optionsCarriesPerformanceToggle,
                                  "Performance mode is in both places or neither "
                                  + "at \(width)pt")
                XCTAssertNotEqual(fit.showsTransportToggle,
                                  fit.optionsCarriesTransportToggle,
                                  "Show transport is in both places or neither "
                                  + "at \(width)pt")
            }
        }
    }

    /// An unmeasured bar shows everything, so Options must show nothing --
    /// otherwise the first frame of every score has two of each switch.
    func testAnUnmeasuredBarLeavesOptionsWithNeitherSwitch() {
        let fit = ScoreBarLayout.fit(barWidth: 0, omrBusy: true)
        XCTAssertTrue(fit.showsPerformanceToggle)
        XCTAssertTrue(fit.showsTransportToggle)
    }
}

/// Versions must stay reachable when the bar sheds its version count.
///
/// `ScoreBarLayout` has always said that dropping the count "drops a shortcut,
/// never a feature", because the title block opened the same dropdown. 0.6.3's
/// split of that band into two columns -- title opens arrangements, count opens
/// versions -- ended the guarantee without noticing, and a phone at reading
/// width was left with NO route to versions: the count yields below 390pt, and
/// the Versions section in Options leads only to a row that lives inside the
/// version column itself.
final class VersionsStayReachableTests: XCTestCase {

    /// The width at which the count goes is the width at which the title must
    /// take over. If this ever fails, a phone has lost version switching.
    func testAPhoneThatLosesTheCountKeepsTheTitleAsItsRoute() {
        let phone = ScoreBarLayout.fit(barWidth: 390)

        XCTAssertFalse(phone.showsVersions,
                       "the fixture is wrong: this width should shed the count")
        // The rule the title block implements: when the count has gone, the
        // title opens versions rather than arrangements.
        let opens: TitleBandLayout.Mode = phone.showsVersions ? .arrangements : .versions
        XCTAssertEqual(opens, .versions, "a phone has no route to versions")
    }

    /// On a bar wide enough to show both, they stay separate -- which is what
    /// 0.6.3 #8 asked for and must not be undone by the narrow-bar rule.
    func testAWideBarKeepsTheTwoColumnsApart() {
        let wide = ScoreBarLayout.fit(barWidth: 1180)

        XCTAssertTrue(wide.showsVersions)
        let opens: TitleBandLayout.Mode = wide.showsVersions ? .arrangements : .versions
        XCTAssertEqual(opens, .arrangements,
                       "the title should still open arrangements where the count exists")
    }
}

/// The ⌖ that arms Select, and the pencil it displaced (0.6.14).
///
/// A control was added to this bar and NOT put in its arithmetic, which is
/// exactly the shape of #60: the bar seated four actions while `essentials`
/// counted three, and a 393pt phone was 20pt over. These are the tests that
/// would have caught it.
final class ScoreBarSelectArmTests: XCTestCase {

    /// Every real width, against the bar's own measurement of itself.
    private static let widths: [(String, CGFloat)] = [
        ("iPhone SE portrait", 375),
        ("iPhone 15 portrait", 393),
        ("iPhone 17 Pro portrait", 402),
        ("iPhone landscape", 734),
        ("iPad split narrow", 507),
        ("iPad 11 portrait", 834),
        ("iPad 13 landscape", 1376),
    ]

    func testWhatTheBarSeatsAlwaysFitsOnIt() {
        for (name, width) in Self.widths {
            for busy in [false, true] {
                let fit = ScoreBarLayout.fit(barWidth: width, omrBusy: busy)
                XCTAssertTrue(ScoreBarLayout.fits(fit, in: width),
                              "\(name) at \(width)pt seats a bar it cannot draw "
                              + "(omr=\(busy)): \(fit)")
            }
        }
    }

    /// ⌖ is not in the yield order at all. On a phone it is the only route to
    /// a lasso -- there is no Pencil -- so dropping it would drop a feature,
    /// and this bar only ever drops shortcuts.
    func testSelectIsOnTheBarAtEveryWidth() {
        for width in stride(from: 320.0, through: 1400.0, by: 1) {
            XCTAssertTrue(ScoreBarLayout.fit(barWidth: width).showsSelectArm,
                          "no way to select at \(width)pt")
        }
    }

    /// The pencil yields on a phone, and the Options screen picks markup up at
    /// exactly those widths. In one place or the other, never neither.
    func testMarkupIsReachableAtEveryWidth() {
        for width in stride(from: 320.0, through: 1400.0, by: 1) {
            let fit = ScoreBarLayout.fit(barWidth: width)
            XCTAssertNotEqual(fit.showsEdit, fit.optionsCarriesEdit,
                              "markup is in both places, or neither, at \(width)pt")
        }
    }

    /// And it does yield: a phone gets ⌖ instead of the pencil, which is the
    /// trade §3 E-A asked for.
    func testAPhoneKeepsSelectAndGivesUpThePencil() {
        let phone = ScoreBarLayout.fit(barWidth: 393)
        XCTAssertTrue(phone.showsSelectArm)
        XCTAssertFalse(phone.showsEdit, "the pencil is still on a 393pt bar")
        let pad = ScoreBarLayout.fit(barWidth: 1376)
        XCTAssertTrue(pad.showsEdit, "an iPad gave up the pencil it has room for")
        XCTAssertTrue(pad.showsSelectArm)
    }

    /// The floor did not move: ⌖ took the pencil's place rather than being
    /// added beside it, so #60's four points of slack on a 375pt iPhone are
    /// still there.
    func testTheFloorStillFitsTheNarrowestPhone() {
        XCTAssertLessThanOrEqual(ScoreBarLayout.floor, 375,
                                 "the bar's floor is wider than an iPhone SE")
    }
}

// MARK: - The phone's second row (0.8.2, Ph4)

/// The three controls the bar handed to a row of its own, and what the phone
/// gets back for it.
///
/// These are new assertions, not rewritten ones: `compact` defaults to false,
/// so every fit above still describes the same bar it did before.
extension ScoreBarLayoutTests {
    private var phoneWidths: [CGFloat] { [375, 390, 393, 402, 430] }

    /// The layout cells, Perform and the + come off the bar.
    func testTheSecondRowTakesTheThreeControlsOffThePhonesBar() {
        for width in phoneWidths {
            let fit = ScoreBarLayout.fit(barWidth: width, compact: true)
            XCTAssertTrue(fit.secondRow, "no second row at \(width)")
            XCTAssertEqual(fit.layoutCells, 0,
                           "the bar still holds layout cells at \(width)")
            XCTAssertFalse(fit.showsPerformanceToggle,
                           "Perform is on the bar AND the second row at \(width)")
            XCTAssertFalse(fit.showsAddToSetlist,
                           "the + is on the bar AND the second row at \(width)")
        }
    }

    /// What the phone gets for it: the PENCIL, which every step of the yield
    /// order used to take off a narrow bar.
    func testThePhoneKeepsThePencilOnceTheCellsHaveARowOfTheirOwn() {
        for width in phoneWidths {
            let fit = ScoreBarLayout.fit(barWidth: width, compact: true)
            XCTAssertTrue(fit.showsEdit,
                          "the pencil still yields at \(width) with the row in place")
            XCTAssertTrue(fit.showsSelectArm, "⌖ must never yield")
            XCTAssertTrue(ScoreBarLayout.fits(fit, in: width),
                          "the phone's bar overflows at \(width): \(fit)")
        }
    }

    /// A switch belongs in exactly one place. The second row carrying Perform
    /// must take it OFF the Options screen, which reads the same `Fit`.
    func testOptionsDoesNotCarryPerformWhenTheSecondRowDoes() {
        for width in phoneWidths {
            let fit = ScoreBarLayout.fit(barWidth: width, compact: true)
            XCTAssertFalse(fit.optionsCarriesPerformanceToggle,
                           "Perform is in two places at \(width)")
            XCTAssertFalse(fit.optionsCarriesEdit,
                           "the pencil is in two places at \(width)")
        }
    }

    /// And the bar still fits at every phone width, transcribing or not.
    func testNoCompactWidthOverflows() {
        for busy in [false, true] {
            for width in stride(from: CGFloat(320), through: 500, by: 1) {
                let fit = ScoreBarLayout.fit(barWidth: width, omrBusy: busy, compact: true)
                XCTAssertTrue(ScoreBarLayout.fits(fit, in: width),
                              "the phone's bar overflows at \(width)pt "
                              + "(omrBusy: \(busy)): \(fit)")
            }
        }
    }

    /// The origin's name is still the first courtesy to go [C6]: 151pt for it
    /// is what no phone has, second row or not.
    func testThePhoneStillYieldsTheOriginsName() {
        for width in phoneWidths {
            XCTAssertFalse(ScoreBarLayout.fit(barWidth: width, compact: true).showsOriginName,
                           "a phone seated the origin's name at \(width)")
        }
    }

    /// Print yields after the + and before the version count, and More carries
    /// it at every width the bar does not (0.17.0).
    func testPrintIsOnTheBarOrInMoreAtEveryWidth() {
        XCTAssertTrue(ScoreBarLayout.fit(barWidth: iPadLandscape).showsPrint)
        var width = 2000.0
        while width > ScoreBarLayout.floor {
            let fit = ScoreBarLayout.fit(barWidth: width)
            XCTAssertNotEqual(fit.showsPrint, fit.optionsCarriesPrint,
                              "print must be on the bar or in More at \(width)pt")
            if fit.showsAddToSetlist { XCTAssertTrue(fit.showsPrint, "print went before the + at \(width)pt") }
            if !fit.showsVersions { XCTAssertFalse(fit.showsPrint, "the count went before print at \(width)pt") }
            width -= 1
        }
        let phone = ScoreBarLayout.fit(barWidth: 390, compact: true)
        XCTAssertTrue(phone.optionsCarriesPrint, "a phone prints from More")
    }

    func testPrintIsNeverOfferedOnTheStrip() {
        XCTAssertTrue(ScorePrinting.available(in: .page))
        XCTAssertTrue(ScorePrinting.available(in: .spread))
        XCTAssertFalse(ScorePrinting.available(in: .continuous),
                       "the strip is one endless system: nothing a printer can take")
    }
}
