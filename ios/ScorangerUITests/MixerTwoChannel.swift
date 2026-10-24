import XCTest

/// The tray on a TWO-channel score.
///
/// Ali's clipped screenshot (IMG_0192) was a real-device two-strip mixer
/// window cut off at the bottom-right, on a stock 13-inch Pro at normal text,
/// while every mixer test used the seeded quartet -- FOUR strips -- and
/// passed. The window is gone; the lesson is kept. Fewer channels is a
/// different layout, not a smaller one: the knob slot is narrower and the
/// scrubber and readouts take the room, so this measures the tray on the
/// accordion solo, both orientations, and with the sound picker open.
final class MixerTwoChannel: XCTestCase {

    /// Which step of the open failed, so a failure names it.
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

    private func launched() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-resetViewPreferences", "-seedTestLibrary",
                               "-UIPreferredContentSizeCategoryName",
                               "UICTContentSizeCategoryL"]
        app.launch()
        return app
    }

    /// The accordion solo: two staves, both called "Accordion". The same
    /// shape as Ali's Whiskey score (Voice + Acoustic Guitar).
    private func openTwoChannelScore(_ app: XCUIApplication) -> XCUIElement? {
        openTray(app, arrangement: "under-paris-skies-accordion-solo", step: &step)
    }

    private func check(_ label: String, _ app: XCUIApplication) {
        let window = app.windows.firstMatch.frame
        let box = app.otherElements["transport"].firstMatch.frame
        print("[\(label)] knobs \(knobCount(app)) tray \(box) window \(window)")
        XCTAssertEqual(knobCount(app), 2, "[\(label)] this fixture is meant to be two channels")
        assertInside(box, window, label)
        // The controls that go first when a line overflows: the glyph at the
        // far right and the tempo knob before it.
        for id in ["transport-tempo", "transport-play"] {
            let control = app.descendants(matching: .any)[id].firstMatch
            XCTAssertTrue(control.exists && control.isHittable,
                          "[\(label)] \(id) is not reachable")
        }
        let voices = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "voices-all-")).firstMatch
        XCTAssertTrue(voices.exists && voices.isHittable,
                      "[\(label)] the all-on/off glyph is not reachable")
    }

    func testTwoChannelTrayFitsInPortrait() {
        let app = launched()
        guard openTwoChannelScore(app) != nil else { return XCTFail(step) }
        snap("two-channel-portrait")
        check("2ch portrait", app)
    }

    func testTwoChannelTrayFitsInLandscape() {
        let app = launched()
        guard let tray = openTwoChannelScore(app) else { return XCTFail(step) }
        rotate(app, to: .landscapeLeft)
        settle(tray, still: 0.8)
        snap("two-channel-landscape")
        check("2ch landscape", app)
    }

    /// With the sound picker open, which is what Ali's screenshots carry. It
    /// is a popover from the knob's label now, and the claim is that the
    /// popover is wholly on screen in both orientations.
    func testTwoChannelTrayWithThePickerOpen() {
        let app = launched()
        guard let tray = openTwoChannelScore(app) else { return XCTFail(step) }
        let sound = app.descendants(matching: .any)["strip-sound-0"]
        guard sound.waitForExistence(timeout: 20) else {
            return XCTFail("no sound label to open the picker")
        }
        sound.tap()
        let picker = app.descendants(matching: .any)["mixer-picker"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 20), "the picker did not open")
        settle(picker, still: 0.5)
        snap("two-channel-picker-portrait")
        // Frames only while the popover is up: the tray under a popover is
        // not hittable, and should not be.
        assertInside(picker.frame, app.windows.firstMatch.frame, "2ch picker portrait")
        assertInside(app.otherElements["transport"].firstMatch.frame,
                     app.windows.firstMatch.frame, "2ch tray under the picker, portrait")

        rotate(app, to: .landscapeLeft)
        settle(tray, still: 0.8)
        snap("two-channel-picker-landscape")
        // A popover may be dismissed by the rotation; if it is still up it
        // has to fit, and the tray under it has to fit either way.
        if picker.exists {
            assertInside(picker.frame, app.windows.firstMatch.frame, "2ch picker landscape")
            assertInside(app.otherElements["transport"].firstMatch.frame,
                         app.windows.firstMatch.frame, "2ch tray under the picker, landscape")
            app.descendants(matching: .any)["mixer-picker-close"].firstMatch.tap()
        }
        check("2ch picker landscape, closed", app)
    }
}
