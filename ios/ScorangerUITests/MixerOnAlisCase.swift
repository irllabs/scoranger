import XCTest

/// Ali's exact case: iPad Pro 13-inch, NORMAL text size, both orientations.
///
/// Written for the mixer window, which measured 268x173 wholly inside a
/// 1032x1376 window in portrait and was clipped for him all the same. Two
/// things the earlier tests never varied, and this still does, on the tray:
///
///   - ORIENTATION. Landscape has a different width, a different height and
///     a different home-indicator inset; the tray's knob slot and scrubber
///     share a line whose length changed.
///   - WHAT COUNTS AS "ON SCREEN". `app.windows.firstMatch.frame` includes
///     the safe areas. A control under the home indicator is "inside the
///     window" and still unreachable, so hittability is asserted AFTER the
///     rotation, control by control.
///
/// The gate skips the two landscape tests with the evidence in gate.sh; they
/// run by hand on a quiet machine.
final class MixerOnAlisCase: XCTestCase {

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
        // NORMAL text. Named explicitly rather than left to the machine, so
        // this test cannot silently inherit a large size from a previous run.
        app.launchArguments = ["-resetViewPreferences", "-seedTestLibrary",
                               "-UIPreferredContentSizeCategoryName",
                               "UICTContentSizeCategoryL"]
        app.launch()
        return app
    }

    private func report(_ orientation: String, _ app: XCUIApplication) {
        let window = app.windows.firstMatch.frame
        let box = app.otherElements["transport"].firstMatch.frame
        print("[\(orientation)] tray \(box) window \(window) "
              + "right slack \(window.maxX - box.maxX)pt, bottom slack \(window.maxY - box.maxY)pt")
    }

    /// The controls a reader reaches for, each one hittable where it stands.
    private func assertControlsReachable(_ label: String, _ app: XCUIApplication) {
        for id in ["transport-play", "strip-mute-0", "strip-fader-0", "strip-sound-0",
                   "transport-tempo", "transport-bar"] {
            let control = app.descendants(matching: .any)[id]
            XCTAssertTrue(control.exists, "\(label): \(id) is gone")
            XCTAssertTrue(control.isHittable, "\(label): \(id) is not hittable")
        }
    }

    // MARK: - Is it cut off at normal text?

    // Portrait at normal text is MixerFitsAnyTextSize's "large" pass: the same
    // size, the tray inside the window, and the same controls hittable.

    /// The orientation no mixer test had ever run in.
    func testTheMixerFitsInLandscapeAtNormalText() {
        let app = launched()
        guard let tray = openTray(app, step: &step) else { return XCTFail(step) }
        rotate(app, to: .landscapeLeft)
        settle(tray, still: 0.8)
        snap("alis-case-landscape")
        report("landscape", app)
        assertInside(app.otherElements["transport"].firstMatch.frame,
                     app.windows.firstMatch.frame, "landscape")
        assertControlsReachable("landscape", app)
    }

    /// Rotating with the sound picker open, which is the largest thing the
    /// tray puts up.
    func testTheMixerFitsInLandscapeWithThePickerOpen() {
        let app = launched()
        guard let tray = openTray(app, step: &step) else { return XCTFail(step) }
        let sound = app.descendants(matching: .any)["strip-sound-0"]
        if sound.waitForExistence(timeout: 20) { sound.tap() }
        let picker = app.descendants(matching: .any)["mixer-picker"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 20), "the picker did not open")
        rotate(app, to: .landscapeLeft)
        settle(tray, still: 0.8)
        snap("alis-case-landscape-picker")
        report("landscape+picker", app)
        let window = app.windows.firstMatch.frame
        if picker.exists { assertInside(picker.frame, window, "landscape+picker") }
        assertInside(app.otherElements["transport"].firstMatch.frame, window, "landscape+picker")
    }

    // MARK: - Does a finger turn the knob, and only the knob?

    /// §7.8: a vertical drag on the dial is the level. A drag anywhere else
    /// on the tray is nothing -- the tray has no drag -- so the readout is
    /// dragged too and the tray is checked for not having moved. Measured on
    /// the window this replaced: grip 169.7pt, caption 120.1pt, fader 0.0pt.
    func testTheKnobTurnsAndTheTrayDoesNot() {
        let app = launched()
        guard let tray = openTray(app, step: &step) else { return XCTFail(step) }
        let knob = app.descendants(matching: .any)["strip-fader-0"].firstMatch
        let readout = app.staticTexts["transport-bar"].firstMatch

        func drag(_ element: XCUIElement, dx: CGFloat, dy: CGFloat) -> Double {
            let before = tray.frame
            let from = element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            from.press(forDuration: 0.25,
                       thenDragTo: from.withOffset(CGVector(dx: dx, dy: dy)),
                       withVelocity: .slow, thenHoldForDuration: 0.5)
            let after = app.otherElements["transport"].firstMatch.frame
            return hypot(after.minX - before.minX, after.minY - before.minY)
        }

        let levelBefore = knob.value as? String ?? ""
        let byKnob = drag(knob, dx: 0, dy: -60)
        let levelAfter = knob.value as? String ?? ""
        print("knob moved the tray \(byKnob)pt, level \(levelBefore) -> \(levelAfter)")
        XCTAssertLessThan(byKnob, 2, "dragging a knob moved the tray \(byKnob)pt")
        XCTAssertNotEqual(levelAfter, levelBefore, "dragging the knob did not change its level")

        let byReadout = drag(readout, dx: -120, dy: -120)
        print("the readout moved the tray \(byReadout)pt")
        XCTAssertLessThan(byReadout, 2, "dragging the readout moved the tray \(byReadout)pt")
        snap("grab-points")

        // Shoved past the screen's corner, it is still where it was and still
        // wholly on screen. The window this replaced borrowed the ink bar's
        // clamp and could park most of itself in the bezel (was
        // TrayVisibility.testTheTrayCannotBeDraggedAway).
        let window = app.windows.firstMatch
        let before = tray.frame
        readout.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.2,
                   thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 1.6, dy: 1.6)),
                   withVelocity: .default, thenHoldForDuration: 0.3)
        settle(tray)
        let after = app.otherElements["transport"].firstMatch.frame
        XCTAssertEqual(after.origin, before.origin,
                       "the tray moved from \(before.origin) to \(after.origin): it has a drag")
        assertInside(after, window.frame, "tray after the shove")
    }
}
