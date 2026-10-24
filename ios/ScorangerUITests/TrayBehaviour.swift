import XCTest

/// The tray's behavioural claims (design/DESIGN_SYSTEM.md §7.7, §7.8).
///
/// These replace MIXER_WINDOW §12's three -- it drags, it is no wider than
/// its channels, its header seats its controls -- with the tray's own: a knob
/// turns and the tray stays put, the knob slot follows the parts, and every
/// control is seated at the floor. BEHAVIOURAL, for the reason written into
/// the window's history: a structural test passed through two dead drags.
final class TrayBehaviour: XCTestCase {

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

    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        return app
    }

    // 1. A knob turns and the tray does not move: that is
    // MixerOnAlisCase.testTheKnobTurnsAndTheTrayDoesNot, which also drags the
    // readout and shoves the tray at the screen's corner.

    /// 2. THE KNOB SLOT FOLLOWS THE PARTS.
    ///
    /// Two knobs on the accordion solo, four on the quartet, and the slot is
    /// wider for four -- without this the test passes on a slot hard-coded to
    /// some width, which would be a different bug. The tray itself is the
    /// same line either way and wholly on screen either way.
    func testTheKnobSlotFollowsTheParts() {
        let app = launch(["-resetLibrary", "-seedTestLibrary"])
        guard let tray = openTray(app, arrangement: "under-paris-skies-accordion-solo",
                                  step: &step) else { return XCTFail(step) }
        let window = app.windows.firstMatch.frame
        let twoKnobs = knobCount(app)
        let twoSlot = app.otherElements["tray-knobs"].firstMatch.frame
        print("[2ch] knobs \(twoKnobs) slot \(twoSlot) tray \(tray.frame) window \(window)")
        snap("tray-two-channels")
        XCTAssertEqual(twoKnobs, 2, "this fixture is meant to be two channels")
        assertInside(tray.frame, window, "2ch")

        // A fresh launch rather than navigating back: the seeded library
        // survives it because `-resetLibrary` is not passed the second time.
        app.terminate()
        let again = launch(["-seedTestLibrary"])
        guard let quartet = openTray(again, step: &step) else { return XCTFail(step) }
        let fourKnobs = knobCount(again)
        let fourSlot = again.otherElements["tray-knobs"].firstMatch.frame
        print("[4ch] knobs \(fourKnobs) slot \(fourSlot) tray \(quartet.frame)")
        snap("tray-four-channels")
        XCTAssertGreaterThan(fourKnobs, twoKnobs,
                             "this fixture is meant to have more channels than the accordion solo")
        XCTAssertGreaterThan(fourSlot.width, twoSlot.width,
                             "\(fourKnobs) knobs (\(fourSlot.width)) is not wider than "
                             + "\(twoKnobs) (\(twoSlot.width)): the slot is not following the parts")
        assertInside(quartet.frame, again.windows.firstMatch.frame, "4ch")
    }

    /// THE LABEL AND THE CONTROLS UNDER IT NAME THE SAME PART.
    ///
    /// Ali: "I still hear the wrong instruments on the wrong staffs." The
    /// audio routing is measured per part offline
    /// (`PlaybackChannelIsolationTests`, `PlaybackInstrumentIsolationTests`),
    /// but those tests address parts by index and cannot see what the knob
    /// SAYS. If the group captioned "Piano (Right Hand)" carried the knob for
    /// a different part, every offline assertion would still pass and the
    /// reader would still be turning down the wrong staff.
    ///
    /// So this reads the screen: for each group, the mute, the knob and the
    /// sound label all have to belong to the part the group names.
    func testEachStripsControlsBelongToThePartItNames() {
        let app = launch(["-resetLibrary", "-seedTestLibrary"])
        guard openTray(app, step: &step) != nil else { return XCTFail(step) }

        var checked = 0
        for index in 0..<12 {
            let strip = app.descendants(matching: .any)["strip-\(index)"].firstMatch
            guard strip.exists else { continue }
            checked += 1
            let name = strip.label
            XCTAssertFalse(name.isEmpty, "strip \(index) names no part")
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
        snap("tray-labels-and-controls")
    }

    /// 3. THE TRAY SEATS ITS CONTROLS.
    ///
    /// On the two-channel score, every control the line carries is inside
    /// the tray's own frame and hittable: nothing has been pushed out of the
    /// line to make room, which is how a one-line layout loses a control.
    func testTheTraySeatsItsControls() {
        let app = launch(["-resetLibrary", "-seedTestLibrary"])
        guard let tray = openTray(app, arrangement: "under-paris-skies-accordion-solo",
                                  step: &step) else { return XCTFail(step) }
        let box = tray.frame
        snap("tray-at-the-floor")
        var ids = ["transport-play", "transport-rewind", "transport-metronome",
                   "transport-loop", "strip-mute-0", "strip-sound-0", "strip-mute-1",
                   "transport-tempo", "transport-bar"]
        let voices = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "voices-all-")).firstMatch
        XCTAssertTrue(voices.exists, "the all-on/off glyph is missing from the tray")
        if voices.exists { ids.append(voices.identifier) }
        for id in ids {
            let control = app.descendants(matching: .any)[id].firstMatch
            XCTAssertTrue(control.exists, "\(id) is missing from the tray")
            XCTAssertTrue(control.isHittable, "\(id) cannot be tapped")
            let frame = control.frame
            XCTAssertGreaterThanOrEqual(frame.minX, box.minX - 0.5,
                                        "\(id) is left of the tray: \(frame)")
            XCTAssertLessThanOrEqual(frame.maxX, box.maxX + 0.5,
                                     "\(id) is right of the tray: \(frame) in \(box)")
            XCTAssertGreaterThanOrEqual(frame.minY, box.minY - 0.5, "\(id) is above the tray")
            XCTAssertLessThanOrEqual(frame.maxY, box.maxY + 0.5, "\(id) is below the tray")
        }
        assertFitsOnScreen(ids, in: app, context: "tray at the floor")
    }
}
