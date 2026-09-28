import XCTest

/// The mixer is wholly on screen, and it follows the finger.
///
/// Ali, 0.6.10: the mixer panel "renders cut off / clipped at the screen edge",
/// and dragging it "doesn't move live -- it only jumps to the final position
/// on release".
///
/// Both are asserted here rather than in `MixerLayoutTests` because neither is
/// visible in the geometry alone. `MixerLayout.origin` and `.clamp` are pure
/// and already tested; they answer what the panel is ASKED to do. What Ali is
/// describing is what SwiftUI then does with it, on a real screen with real
/// safe areas -- and a pure test of the arithmetic passes either way. The
/// arithmetic was in fact the first place looked, and it was innocent: the
/// picker floors the panel at 300pt and six strips make 397, so a panel only
/// exceeds its canvas below about 300pt of width and no device is that narrow.
///
/// So this measures the panel's own frame against the screen's.
final class MixerVisibility: XCTestCase {

    private func snap(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func engravedPage(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "canvas-"))
            .firstMatch
    }

    /// Open a score that can actually play -- the seeded library's first row is
    /// a scan, and a scan has no transport and so no mixer.
    private func openPlayableScore(_ app: XCUIApplication) -> Bool {
        let wanted = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS[c] %@",
                                  "row-", "Sous le ciel")).firstMatch
        guard wanted.waitForExistence(timeout: 90) else { return false }
        wanted.tap()
        if app.buttons["score-title"].waitForExistence(timeout: 5) == false {
            let choice = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@",
                                      "arrangement-choice-")).firstMatch
            if choice.waitForExistence(timeout: 30) { settle(choice); choice.tap() }
        }
        return app.buttons["score-title"].waitForExistence(timeout: 240)
    }

    /// The open mixer, or nil with the reason photographed.
    private func openMixer(_ app: XCUIApplication) -> XCUIElement? {
        guard openPlayableScore(app) else { snap("no-score"); return nil }
        _ = engravedPage(app).waitForExistence(timeout: 180)
        settle(engravedPage(app), still: 0.6)
        if app.otherElements["transport"].exists == false,
           app.buttons["score-transport-toggle"].exists {
            app.buttons["score-transport-toggle"].tap()
            _ = app.otherElements["transport"].waitForExistence(timeout: 20)
        }
        guard app.buttons["transport-mixer"].waitForExistence(timeout: 120) else {
            snap("no-mixer-button"); return nil
        }
        app.buttons["transport-mixer"].tap()
        let panel = app.otherElements["mixer"].firstMatch
        guard panel.waitForExistence(timeout: 30) else { snap("no-mixer"); return nil }
        settle(panel)
        return panel
    }

    /// Every edge of the parked panel is inside the screen.
    ///
    /// Reported as all four gaps at once rather than one assertion per edge:
    /// "the mixer is 41pt off the right" is a fix, and "an assertion failed" is
    /// a bug report someone has to reproduce.
    func testTheParkedMixerIsWhollyOnScreen() {
        let app = XCUIApplication()
        app.launchArguments = ["-seedTestLibrary"]
        app.launch()
        guard let panel = openMixer(app) else { return XCTFail("no mixer to measure") }
        snap("mixer-as-parked")

        let screen = app.windows.firstMatch.frame
        let box = panel.frame
        print("MIXER frame \(box) in screen \(screen)")
        let over = (left: screen.minX - box.minX, top: screen.minY - box.minY,
                    right: box.maxX - screen.maxX, bottom: box.maxY - screen.maxY)
        XCTAssertLessThanOrEqual(over.left, 0.5, "off the left by \(over.left)pt")
        XCTAssertLessThanOrEqual(over.top, 0.5, "off the top by \(over.top)pt")
        XCTAssertLessThanOrEqual(over.right, 0.5, "off the right by \(over.right)pt")
        XCTAssertLessThanOrEqual(over.bottom, 0.5, "off the bottom by \(over.bottom)pt")
    }

    /// And with the sound picker open, which is the panel at its largest.
    func testTheMixerIsWhollyOnScreenWithThePickerOpen() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-seedTestLibrary"]
        app.launch()
        guard let panel = openMixer(app) else { return XCTFail("no mixer to measure") }
        let sound = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "strip-sound-"))
            .firstMatch
        guard sound.waitForExistence(timeout: 20) else {
            throw XCTSkip("no sound row to open the picker with")
        }
        sound.tap()
        _ = app.descendants(matching: .any)["mixer-picker"].waitForExistence(timeout: 20)
        settle(panel)
        snap("mixer-with-picker-open")

        let screen = app.windows.firstMatch.frame
        let box = panel.frame
        print("MIXER+PICKER frame \(box) in screen \(screen)")
        XCTAssertLessThanOrEqual(box.maxX - screen.maxX, 0.5,
                                 "off the right by \(box.maxX - screen.maxX)pt")
        XCTAssertLessThanOrEqual(box.maxY - screen.maxY, 0.5,
                                 "off the bottom by \(box.maxY - screen.maxY)pt")
        XCTAssertGreaterThanOrEqual(box.minX - screen.minX, -0.5,
                                    "off the left by \(screen.minX - box.minX)pt")
        XCTAssertGreaterThanOrEqual(box.minY - screen.minY, -0.5,
                                    "off the top by \(screen.minY - box.minY)pt")
    }

    /// The panel tracks the finger, rather than jumping when it lifts.
    ///
    /// Measured MID-GESTURE: the drag is held still partway with
    /// `press(forDuration:thenDragTo:)`'s slower cousin -- a manual sequence of
    /// press, move, sample, release -- because the whole claim is about what is
    /// on screen while the finger is still down. A test that only compared
    /// before and after would pass on exactly the behaviour Ali reported.
    func testTheMixerFollowsTheFingerWhileItIsStillDown() {
        let app = XCUIApplication()
        app.launchArguments = ["-seedTestLibrary"]
        app.launch()
        guard let panel = openMixer(app) else { return XCTFail("no mixer to drag") }
        let before = panel.frame
        snap("mixer-before-drag")

        // The HEADER, and no fallback to the panel body. The body having a
        // drag is exactly what the rebuild removed (MIXER_WINDOW §1.1): its
        // gesture competed with every mute, fader and chip and lost, which is
        // why the window felt dead. A test that fell back to the body would
        // now be asserting the opposite of the design.
        let header = app.descendants(matching: .any)["mixer-header"].firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 20),
                      "no mixer header to pick the window up by")
        // dx 0.06 is the leading 44pt, where the grab bar is drawn. By
        // coordinate because §1.1 makes `mixer-grab` accessibility-hidden.
        let start = header.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: 0.5))
        // Up and to the left, well inside the screen so no clamp is involved.
        let target = start.withOffset(CGVector(dx: -160, dy: -160))

        start.press(forDuration: 0.2, thenDragTo: target,
                    withVelocity: .slow, thenHoldForDuration: 1.2)
        // Sampled while the press is still held: XCTest keeps the touch down
        // for `thenHoldForDuration`, so this frame is mid-gesture.
        let during = app.otherElements["mixer"].firstMatch.frame
        snap("mixer-mid-drag")
        print("MIXER before \(before) during \(during)")

        let moved = hypot(during.minX - before.minX, during.minY - before.minY)
        XCTAssertGreaterThan(moved, 40,
                             "the panel had not moved while the finger was down "
                             + "(before \(before.origin), during \(during.origin)) "
                             + "-- it only jumps on release")
    }

    /// Dragged hard at an edge, the panel is still wholly on screen.
    ///
    /// This is the one the geometry predicted and the parked case did not
    /// show. `MixerLayout.clamp` deliberately borrows the ink bar's rule --
    /// keep `InkBarPlacement.mustRemainVisible` on screen and let the rest go
    /// -- so a shove to the right legitimately parks ~90% of the panel in the
    /// bezel. On the ink bar that is right: it has no way to move itself, so
    /// it must be pushable aside. The mixer is not in that situation. Its grip
    /// CYCLES CORNERS on a tap and it has a close button, so a reader who
    /// wants the music underneath has two ways to get it that do not involve
    /// leaving a control half in the bezel -- and the rule as written produces
    /// exactly the thing Ali reported.
    func testTheMixerCannotBeDraggedOffTheEdge() {
        let app = XCUIApplication()
        app.launchArguments = ["-seedTestLibrary"]
        app.launch()
        guard let panel = openMixer(app) else { return XCTFail("no mixer to drag") }
        let screen = app.windows.firstMatch.frame
        let grip = app.descendants(matching: .any)["mixer-grip"].firstMatch
        let handle: XCUIElement = grip.exists ? grip : panel

        // Shove it at the bottom-right corner, far past the edge.
        handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.2,
                   thenDragTo: app.windows.firstMatch.coordinate(
                       withNormalizedOffset: CGVector(dx: 1.6, dy: 1.6)),
                   withVelocity: .default, thenHoldForDuration: 0.3)
        settle(panel)
        snap("mixer-shoved-at-the-corner")

        let box = app.otherElements["mixer"].firstMatch.frame
        print("MIXER shoved to \(box) in screen \(screen)")
        XCTAssertLessThanOrEqual(box.maxX - screen.maxX, 0.5,
                                 "\(box.maxX - screen.maxX)pt of the mixer is off "
                                 + "the right edge")
        XCTAssertLessThanOrEqual(box.maxY - screen.maxY, 0.5,
                                 "\(box.maxY - screen.maxY)pt of the mixer is off "
                                 + "the bottom edge")
    }
}
