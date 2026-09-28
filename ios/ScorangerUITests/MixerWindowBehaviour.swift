import XCTest

/// The mixer's three behavioural claims (MIXER_WINDOW §12 acceptance).
///
/// BEHAVIOURAL, and the reason is written into the history: the drag has died
/// twice, from two different causes, and both times the tests in this suite
/// were green. Once because the grab surface was a `Button`, so the gesture
/// never saw the touch; once because the panel was full-width and ANCHORED, so
/// there was nothing to drag and nowhere to drag it. A structural test -- the
/// panel has a drag gesture, the layout returns a window -- passed through
/// both. So these pick the thing up and check that it moved.
final class MixerWindowBehaviour: XCTestCase {

    private var step = "the fixture never opened"

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }

    private func snap(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Wait for the seeded library to STOP GROWING rather than spending a
    /// wall-clock budget across an engine call -- gate.sh's own hazard note.
    private func waitForTheLibraryToSettle(_ app: XCUIApplication,
                                           timeout: TimeInterval = 300) {
        let rows = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "row-"))
        let deadline = Date().addingTimeInterval(timeout)
        var last = -1
        var stableSince = Date()
        while Date() < deadline {
            let now = rows.count
            if now != last { last = now; stableSince = Date() }
            else if now > 0, Date().timeIntervalSince(stableSince) > 2.5 { return }
            Thread.sleep(forTimeInterval: 0.5)
        }
    }

    /// `nil` arrangement opens whichever the library offers first (the
    /// quartet); a slug opens that one.
    private func openMixer(_ app: XCUIApplication,
                           arrangement: String? = nil) -> XCUIElement? {
        _ = app.descendants(matching: .any)["library-search"].waitForExistence(timeout: 90)
        let rows = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "row-"))
        if rows.count == 0 { waitForTheLibraryToSettle(app) }
        let row = app.descendants(matching: .any)["row-sous-le-ciel-de-paris"]
        guard row.waitForExistence(timeout: 120) else {
            step = "the piece row never appeared"; return nil
        }
        row.tap()
        let choice = arrangement.map { app.descendants(matching: .any)["arrangement-choice-\($0)"] }
            ?? app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@",
                                      "arrangement-choice-")).firstMatch
        if choice.waitForExistence(timeout: 60) { settle(choice); choice.tap() }
        guard app.buttons["score-title"].waitForExistence(timeout: 240) else {
            step = "the score never opened"; return nil
        }
        let page = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "canvas-")).firstMatch
        _ = page.waitForExistence(timeout: 180)
        settle(page, still: 0.6)
        if !app.otherElements["transport"].exists,
           app.buttons["score-transport-toggle"].exists {
            app.buttons["score-transport-toggle"].tap()
            _ = app.otherElements["transport"].waitForExistence(timeout: 20)
        }
        guard app.buttons["transport-mixer"].waitForExistence(timeout: 120) else {
            step = "there is no mixer button: playback is unavailable"; return nil
        }
        app.buttons["transport-mixer"].tap()
        let panel = app.otherElements["mixer"].firstMatch
        guard panel.waitForExistence(timeout: 30) else {
            step = "the mixer button did not open the panel"; return nil
        }
        settle(panel)
        return panel
    }

    /// 1. IT DRAGS, AT EVERY WIDTH.
    ///
    /// The grab is the LEADING 44x44 of the header and is deliberately not in
    /// the accessibility tree (§1.1: it duplicates Park, and VoiceOver cannot
    /// drag), so this takes hold of it by coordinate rather than by
    /// identifier -- which is also closer to what a thumb does.
    func testTheMixerDragsAtEveryWidth() {
        let app = XCUIApplication()
        app.launchArguments = ["-resetLibrary", "-seedTestLibrary"]
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        guard let panel = openMixer(app) else { return XCTFail(step) }

        // The orientation the app actually offers, and then the other one IF
        // it offers it.
        //
        // §12's acceptance asks for compact portrait, compact landscape and
        // regular. Two of those three are reachable: this app is
        // PORTRAIT-ONLY on iPhone
        // (`INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone`), so
        // "compact landscape" does not exist on a phone as it ships -- and
        // the gate runs this class on an iPad, which covers regular. Rather
        // than assert a state the app cannot enter, this tries the rotation
        // and says plainly when the device declined it.
        dragAndAssert(app, panel, "as launched")
        let before = app.windows.firstMatch.frame
        XCUIDevice.shared.orientation = .landscapeLeft
        let turned = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "NOT (frame.size.width == %f)",
                                   before.width),
            object: app.windows.firstMatch)
        if XCTWaiter().wait(for: [turned], timeout: 10) == .completed {
            settle(panel)
            dragAndAssert(app, panel, "rotated")
            XCUIDevice.shared.orientation = .portrait
            settle(panel)
        } else {
            // Not a failure: it is the app's own orientation policy, and the
            // finding belongs in a report rather than in a red test.
            print("[orientation] the device declined landscape -- window is "
                  + "still \(before.size). On iPhone that is the plist: the "
                  + "app is portrait-only, so §12's compact-landscape leg and "
                  + "§3 E-B's landscape score view are both unreachable.")
        }
    }

    private func dragAndAssert(_ app: XCUIApplication, _ panel: XCUIElement,
                               _ label: String) {
        let window = app.windows.firstMatch.frame
        let before = panel.frame
        XCTAssertGreaterThan(before.width, 0, "[\(label)] the panel has no frame")

        // The grab: 22pt in from the panel's leading edge, 22 down.
        let grab = panel.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 22, dy: 22))
        let target = grab.withOffset(CGVector(dx: -60, dy: -80))
        grab.press(forDuration: 0.1, thenDragTo: target)
        settle(panel, still: 0.6)
        let after = panel.frame
        snap("mixer-dragged-\(label)")

        XCTAssertNotEqual(after.origin, before.origin,
                          "[\(label)] the mixer did not move: it was dragged "
                          + "from \(before.origin) and is still there. That is "
                          + "the bug, twice over.")
        // Moved AND still inside: a panel that leaves the window has not been
        // dragged successfully, it has been lost.
        XCTAssertGreaterThanOrEqual(after.minX, -0.5, "[\(label)] off the left")
        XCTAssertGreaterThanOrEqual(after.minY, -0.5, "[\(label)] off the top")
        XCTAssertLessThanOrEqual(after.maxX, window.maxX + 0.5,
                                 "[\(label)] off the right")
        XCTAssertLessThanOrEqual(after.maxY, window.maxY + 0.5,
                                 "[\(label)] off the bottom")
    }

    /// 2. IT IS NO WIDER THAN ITS CHANNELS.
    ///
    /// The reported case: a two-staff score on a phone. It was full-width,
    /// which is why it was anchored, which is why it could not be dragged.
    func testTheMixerIsNoWiderThanItsChannels() {
        let app = XCUIApplication()
        app.launchArguments = ["-resetLibrary", "-seedTestLibrary"]
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        guard let panel = openMixer(app,
                arrangement: "under-paris-skies-accordion-solo") else {
            return XCTFail(step)
        }
        let window = app.windows.firstMatch.frame
        let two = panel.frame
        let strips = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@",
                                  "strip-mute-")).count
        print("[2ch] strips \(strips) panel \(two) window \(window)")
        snap("mixer-two-channels")
        XCTAssertEqual(strips, 2, "this fixture is meant to be two channels")
        XCTAssertLessThanOrEqual(two.width, 200,
                                 "a two-channel mixer is \(two.width)pt wide on "
                                 + "a \(window.width)pt screen -- it is sized to "
                                 + "the screen, not to its channels")
        // And it leaves room to be dragged into, which is the point of the
        // width: a panel that fills the width has nowhere to go.
        XCTAssertLessThan(two.width, window.width * 0.75,
                          "the panel takes most of the screen, so there is "
                          + "nowhere to move it")

        // FOUR channels is wider than two. Without this the test passes on a
        // panel hard-coded narrow, which would be a different bug.
        // FOUR channels is wider than two. Without this the test passes on a
        // panel hard-coded narrow, which would be a different bug.
        //
        // A fresh launch rather than navigating back: the score's ✕ does not
        // return to the library -- it pops to the piece -- and a helper that
        // guesses at the way back spent five minutes proving only that it had
        // guessed wrong. The seeded library survives the relaunch because
        // `-resetLibrary` is not passed the second time, so this costs a
        // launch and not a re-seed.
        app.terminate()
        let again = XCUIApplication()
        again.launchArguments = ["-seedTestLibrary"]
        again.launch()
        XCUIDevice.shared.orientation = .portrait
        guard let quartet = openMixer(again) else { return XCTFail(step) }
        let four = quartet.frame
        let quartetStrips = again.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@",
                                  "strip-mute-")).count
        print("[4ch] strips \(quartetStrips) panel \(four)")
        snap("mixer-four-channels")
        XCTAssertGreaterThan(quartetStrips, strips,
                             "this fixture is meant to have more channels than "
                             + "the accordion solo")
        XCTAssertGreaterThan(four.width, two.width,
                             "\(quartetStrips) channels (\(four.width)) is not "
                             + "wider than \(strips) (\(two.width)): the width "
                             + "is not following the channels at all")
        XCTAssertLessThanOrEqual(four.maxX, again.windows.firstMatch.frame.maxX + 0.5,
                                 "the wider panel now hangs off the screen")
    }

    /// THE LABEL AND THE CONTROLS UNDER IT NAME THE SAME PART.
    ///
    /// Ali: "I still hear the wrong instruments on the wrong staffs." The
    /// audio routing is measured per part offline
    /// (`PlaybackChannelIsolationTests`, `PlaybackInstrumentIsolationTests`),
    /// but those tests address parts by index and cannot see what the strip
    /// SAYS. If the strip captioned "Piano (Right Hand)" carried the knob for
    /// a different part, every offline assertion would still pass and the
    /// reader would still be turning down the wrong staff.
    ///
    /// So this reads the screen: for each strip, the mute, the knob and the
    /// sound chip all have to belong to the part the label names.
    func testEachStripsControlsBelongToThePartItNames() {
        let app = XCUIApplication()
        app.launchArguments = ["-resetLibrary", "-seedTestLibrary"]
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        guard openMixer(app) != nil else { return XCTFail(step) }

        let strips = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "strip-"))
        XCTAssertGreaterThan(strips.count, 0, "no strips in the mixer")

        var checked = 0
        for index in 0..<12 {
            let strip = app.descendants(matching: .any)["strip-\(index)"].firstMatch
            guard strip.exists else { continue }
            checked += 1
            // The strip's own accessibility label is the part's name.
            let name = strip.label
            XCTAssertFalse(name.isEmpty, "strip \(index) names no part")

            // Each control inside it says the same name. They are separate
            // elements with their own labels, built from their own `part`, so
            // agreeing here means they were all handed the same part.
            for (kind, identifier) in [("knob", "strip-fader-\(index)"),
                                       ("mute", "strip-mute-\(index)"),
                                       ("sound", "strip-sound-\(index)")] {
                let control = app.descendants(matching: .any)[identifier].firstMatch
                guard control.exists else { continue }
                XCTAssertTrue(control.label.contains(name),
                              "strip \(index) is captioned \"\(name)\" but its "
                              + "\(kind) says \"\(control.label)\" -- the "
                              + "control under the label belongs to another part")
            }
        }
        XCTAssertGreaterThan(checked, 1,
                             "only \(checked) strip(s) were checked, so this "
                             + "says nothing about strips being mixed up")
        snap("mixer-labels-and-controls")
    }

    /// 3. THE HEADER SEATS ITS CONTROLS.
    ///
    /// At the floor the header is EXACTLY its four 44pt controls, so all four
    /// have to be inside the panel -- the clip check, pointed at the four ids
    /// that matter. The grab is not among them because it is not in the
    /// accessibility tree; its presence is what test 1 proves, by using it.
    func testTheHeaderSeatsItsControls() {
        let app = XCUIApplication()
        app.launchArguments = ["-resetLibrary", "-seedTestLibrary"]
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        guard let panel = openMixer(app,
                arrangement: "under-paris-skies-accordion-solo") else {
            return XCTFail(step)
        }
        let box = panel.frame
        snap("mixer-header-at-floor")
        for id in ["mixer-collapse", "mixer-park", "mixer-close"] {
            let control = app.descendants(matching: .any)[id].firstMatch
            XCTAssertTrue(control.exists, "\(id) is missing from the header")
            XCTAssertTrue(control.isHittable, "\(id) cannot be tapped")
            let frame = control.frame
            XCTAssertGreaterThanOrEqual(frame.minX, box.minX - 0.5,
                                        "\(id) is left of the panel: \(frame)")
            XCTAssertLessThanOrEqual(frame.maxX, box.maxX + 0.5,
                                     "\(id) is right of the panel: \(frame) "
                                     + "in \(box)")
            XCTAssertLessThanOrEqual(frame.maxY, box.maxY + 0.5,
                                     "\(id) is below the panel")
        }
        // And at the floor there is no title: the words are what the floor
        // gave up to be 184 rather than 280 (§12).
        XCTAssertFalse(app.descendants(matching: .any)["mixer-title"].exists,
                       "the header is drawing its title at floor width, which "
                       + "is what made the floor 280 and the panel full-width")
        assertFitsOnScreen(["mixer-collapse", "mixer-park", "mixer-close"],
                           in: app, context: "mixer header at floor width")
    }
}
