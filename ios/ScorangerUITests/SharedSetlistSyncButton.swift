import XCTest

/// A shared set list row carries a Sync button beside its share button, and
/// no other row does (0.18.0). Ali, of Echo: "there should be a manual sync
/// button so that Echo can pull it if he knows there should be in there."
///
/// No Firebase here: the seeded row is bound to a share the engine records
/// and nobody serves, which is the state a joined row is in when its reader
/// is signed out. Tapped then, the button has to SAY why it cannot sync
/// rather than do nothing. The sync itself was proven on the Firebase
/// emulators across two simulators; BACKLOG.md records that run.
final class SharedSetlistSyncButton: XCTestCase {
    private var app: XCUIApplication!

    private func snap(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testOnlyASharedRowHasSyncAndItExplainsItselfSignedOut() {
        app = XCUIApplication()
        app.launchArguments = ["-resetLibrary", "-resetViewPreferences",
                               "-seedTestLibrary", "-seedSharedSetlist"]
        app.launch()
        _ = app.descendants(matching: .any)["library-search"].waitForExistence(timeout: 240)
        let segment = app.buttons.matching(NSPredicate(format: "label == %@", "Set lists")).firstMatch
        XCTAssertTrue(segment.waitForExistence(timeout: 20))
        segment.tap()

        let sync = app.descendants(matching: .any)["row-sync-tuesday-at-the-ship"]
        XCTAssertTrue(sync.waitForExistence(timeout: 240), "no Sync on the shared row")
        XCTAssertTrue(app.descendants(matching: .any)["row-share-tuesday-at-the-ship"].exists,
                      "Sync sits beside the share button, which is still there")
        let unshared = app.descendants(matching: .any)["row-share-test-setlist"]
        XCTAssertTrue(unshared.waitForExistence(timeout: 20), "the unshared seeded row is missing")
        XCTAssertFalse(app.descendants(matching: .any)["row-sync-test-setlist"].exists,
                       "a set list nobody shares has nothing to sync")
        XCTAssertEqual(sync.value as? String, "not synced")
        snap("01-shared-row-with-sync")

        sync.tap()
        expectation(for: NSPredicate(format: "value == %@", "trouble"), evaluatedWith: sync)
        waitForExpectations(timeout: 10)
        XCTAssertTrue(sync.label.contains("Sign in"),
                      "the reason is on the button: \(sync.label)")
        snap("02-sync-signed-out")
    }
}
