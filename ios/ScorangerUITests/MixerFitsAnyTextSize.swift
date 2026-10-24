import XCTest

/// The tray at the text size the reader actually uses.
///
/// Ali, on his iPad, about the mixer window this tray replaced: its "text/UI
/// is cut off". The cause was a panel positioned by arithmetic that was not
/// what SwiftUI drew, because every type role scales with Dynamic Type
/// (`Theme.Role.font` -> `UIFontMetrics.scaledFont`) and the frames did not.
/// The tray has no arithmetic of that kind -- it is a line in the layout, and
/// it grows with its content -- but the claim is the same one and this is
/// where it is checked: at every size the tray is wholly on screen, and the
/// controls a reader needs are still ON it and hittable.
///
/// The size is set with `-UIPreferredContentSizeCategoryName` on the launch
/// rather than `simctl ui content_size`, so it belongs to the test rather
/// than to the machine and the gate carries it.
final class MixerFitsAnyTextSize: XCTestCase {

    /// The default, one step up (which many readers set), and the
    /// accessibility size that made the old failure obvious.
    private static let sizes = [
        ("large", "UICTContentSizeCategoryL"),
        ("extra-extra-large", "UICTContentSizeCategoryXXL"),
        ("accessibility-extra-large", "UICTContentSizeCategoryAccessibilityXL"),
    ]

    private func snap(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Hittability rather than pixels, because that is the failure: a
    /// control off the tray is one a finger cannot reach.
    func testTheTrayFitsAndKeepsItsControlsAtEveryTextSize() {
        for (label, category) in Self.sizes {
            let app = XCUIApplication()
            app.launchArguments = ["-resetViewPreferences", "-seedTestLibrary",
                                   "-UIPreferredContentSizeCategoryName", category]
            app.launch()
            defer { app.terminate() }

            var step = ""
            guard let tray = openTray(app, step: &step) else {
                snap("no-tray-at-\(label)", app)
                XCTFail("[\(label)] \(step)")
                continue
            }
            snap("tray-at-\(label)", app)

            let screen = app.windows.firstMatch.frame
            let box = tray.frame
            print("[\(label)] tray \(box) in screen \(screen)")
            assertInside(box, screen, label)

            // The controls a reader needs: play, one knob's mute and sound,
            // the tempo knob and the all-on/off glyph.
            for id in ["transport-play", "strip-mute-0", "strip-fader-0",
                       "strip-sound-0", "transport-tempo", "transport-bar"] {
                let control = app.descendants(matching: .any)[id].firstMatch
                XCTAssertTrue(control.exists && control.isHittable,
                              "[\(label)] \(id) is not reachable")
            }
            let voices = app.buttons.matching(
                NSPredicate(format: "identifier BEGINSWITH %@", "voices-all-")).firstMatch
            XCTAssertTrue(voices.exists && voices.isHittable,
                          "[\(label)] the all-on/off glyph is not reachable")

            // The readouts, which collapsed to "0…" on the window -- a clock
            // that says nothing is not a clock. The bar at rest; the clock
            // once the music runs.
            let bar = app.staticTexts["transport-bar"]
            XCTAssertTrue(bar.exists, "[\(label)] no bar readout")
            XCTAssertFalse(bar.label.contains("…"), "[\(label)] the bar readout is truncated: \(bar.label)")

            let play = app.buttons["transport-play"]
            let usable = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "isEnabled == true"), object: play)
            _ = XCTWaiter().wait(for: [usable], timeout: 120)
            play.tap()
            let clock = app.descendants(matching: .any)["mixer-elapsed"].firstMatch
            if clock.waitForExistence(timeout: 30) {
                XCTAssertFalse(clock.label.contains("…"),
                               "[\(label)] the clock is truncated: \(clock.label)")
                snap("tray-playing-at-\(label)", app)
                // And still wholly on screen with the scrubber out.
                assertInside(app.otherElements["transport"].firstMatch.frame,
                             screen, "\(label) playing")
            } else {
                XCTFail("[\(label)] playback never started, so the clock was never seen")
            }
            play.tap()
        }
    }
}
