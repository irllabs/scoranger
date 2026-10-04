import XCTest

/// On a phone, a shared set list's row keeps its Play button on screen, and
/// Sync is in the row's actions (0.18.1). 0.18.0 put a Sync button beside
/// share on every device, and a phone's row had no room for a fourth control.
/// Runs in the gate's phone lane.
final class PhoneSharedRow: XCTestCase {
    private var app: XCUIApplication!

    func testASharedRowFitsAndSyncIsInItsActions() {
        app = XCUIApplication()
        app.launchArguments = ["-resetLibrary", "-resetViewPreferences",
                               "-seedTestLibrary", "-seedSharedSetlist"]
        app.launch()
        _ = app.descendants(matching: .any)["library-search"].waitForExistence(timeout: 240)
        let segment = app.buttons.matching(NSPredicate(format: "label == %@", "Set lists")).firstMatch
        XCTAssertTrue(segment.waitForExistence(timeout: 20))
        segment.tap()
        let share = app.descendants(matching: .any)["row-share-tuesday-at-the-ship"]
        XCTAssertTrue(share.waitForExistence(timeout: 240), "no shared row")

        let screen = app.windows.firstMatch.frame
        let play = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Play"))
            .allElementsBoundByIndex.first { abs($0.frame.midY - share.frame.midY) < 30 }
        XCTAssertNotNil(play, "no Play button on the shared row")
        if let play {
            // Its centre, not its whole 44pt tap area: on a 402pt iPhone 17
            // Pro every set list row's Play runs 1pt past the edge (measured,
            // shared or not), which is flush, not cut off. The fault this
            // guards is the 0.18.0 one: the button pushed half off the edge.
            XCTAssertTrue(play.frame.midX < screen.maxX - 12 && play.isHittable,
                          "Play is off the screen: \(play.frame) in \(screen)")
        }
        XCTAssertFalse(app.descendants(matching: .any)["row-sync-tuesday-at-the-ship"].exists,
                       "a phone row has no room for the Sync button")

        app.descendants(matching: .any)["row-menu-tuesday-at-the-ship"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["row-sync-action-tuesday-at-the-ship"]
            .waitForExistence(timeout: 10), "Sync is not in the row's actions")
    }
}
