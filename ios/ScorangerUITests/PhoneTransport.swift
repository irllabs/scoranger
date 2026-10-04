import XCTest

/// On a phone, Stop stays on screen while the music plays (0.18.1).
///
/// The tray's line grew a running clock and a scrubber while playing, and on
/// a 6.5" iPhone that was wider than the screen: centred, it pushed play/stop
/// off the left edge, so playback could be started and not stopped. Found
/// photographing the App Store screenshots. Runs in the gate's phone lane.
final class PhoneTransport: XCTestCase {
    private var app: XCUIApplication!

    func testStopIsOnScreenWhilePlaying() {
        app = XCUIApplication()
        app.launchArguments = ["-resetLibrary", "-resetViewPreferences", "-seedTestLibrary"]
        app.launch()
        let row = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "row-")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 240), "the seeded library never arrived")
        row.tap()
        let choice = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "arrangement-choice-")).firstMatch
        if choice.waitForExistence(timeout: 10) { choice.tap() }
        XCTAssertTrue(app.buttons["score-title"].waitForExistence(timeout: 240))

        let play = app.buttons["transport-play"]
        XCTAssertTrue(play.waitForExistence(timeout: 60), "no transport")
        expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: play)
        waitForExpectations(timeout: 120)
        play.tap()
        expectation(for: NSPredicate(format: "label == %@", "Stop"), evaluatedWith: play)
        waitForExpectations(timeout: 20)
        sleep(2)

        let screen = app.windows.firstMatch.frame
        XCTAssertTrue(screen.contains(play.frame),
                      "Stop is off the screen while playing: \(play.frame) in \(screen)")
        XCTAssertTrue(play.isHittable, "Stop cannot be tapped while playing")
        play.tap()
        expectation(for: NSPredicate(format: "label == %@", "Play"), evaluatedWith: play)
        waitForExpectations(timeout: 20)
    }
}
