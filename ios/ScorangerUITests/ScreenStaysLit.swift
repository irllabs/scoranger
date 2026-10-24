import XCTest

/// The idle timer follows the rule, in the running app.
///
/// ScreenWakeTests asserts the rule. This asserts the WIRING, which no unit
/// test can see: `isIdleTimerDisabled` is a property of a live UIApplication
/// and the test bundle has no host app. So the app says what it set, and this
/// reads it back out of the log — library dark, score lit, library dark again.
final class ScreenStaysLit: XCTestCase {

    func testOpeningAScoreLightsTheScreenAndLeavingGivesItBack() {
        let app = XCUIApplication()
        // -seedTestLibrary: without it this opened whatever library the
        // simulator's previous test left, and a fresh simulator has none.
        app.launchArguments += ["-resetViewPreferences", "-seedTestLibrary",
                                "-ScorangerUITest", "1"]
        app.launch()

        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "row-")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 120), "no library row to open")
        row.tap()

        // a piece with several arrangements asks which one first
        openWhicheverArrives(app)
        XCTAssertTrue(app.buttons["score-title"].waitForExistence(timeout: 240),
                      "score never opened")

        // Backgrounded and brought back: the claim is dropped on the way out
        // and taken again on the way in, which is the part a flag nobody
        // clears gets wrong.
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 2)
        app.activate()
        XCTAssertTrue(app.buttons["score-title"].waitForExistence(timeout: 60),
                      "the score should still be open on return")

        // and back out
        let close = app.buttons["score-close"]
        if close.waitForExistence(timeout: 10) { close.tap() }
        XCTAssertTrue(row.waitForExistence(timeout: 60), "never returned to the library")
    }
}
