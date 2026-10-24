import XCTest

/// The + on the score bar, and the checklist it opens.
///
/// Ali, 0.6.11 #1: a "+" in the score top bar that adds the current
/// ARRANGEMENT to set lists, opening a checklist of set lists with checkboxes
/// to select and unselect membership.
///
/// This is the inverse of the route the library already had. `SetlistPickerView`
/// files arrangements INTO one set list; this asks where THIS arrangement
/// belongs. `SetlistMembershipTests` covers the ordering and what a tap
/// resolves to; what only a running app can show is that the + is on the bar,
/// that it opens the band, that a tap reaches the engine, and that the change
/// is still there after the manifest refreshes.
final class AddToSetlist: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-resetViewPreferences", "-seedTestLibrary"]
        app.launch()
    }

    private func snap(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func engravedPage() -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "canvas-"))
            .firstMatch
    }

    /// Open a score. Any will do -- the + does not care what the notation is.
    private func openAScore() -> Bool {
        _ = app.descendants(matching: .any)["library-search"].waitForExistence(timeout: 90)
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS[c] %@",
                                  "row-", "Sous le ciel")).firstMatch
        guard row.waitForExistence(timeout: 120) else { return false }
        row.tap()
        openWhicheverArrives(app, timeout: 30)
        guard app.buttons["score-title"].waitForExistence(timeout: 240) else { return false }
        _ = engravedPage().waitForExistence(timeout: 180)
        settle(engravedPage(), still: 0.6)
        return true
    }

    /// The seed files its imports into a set list once every import has landed,
    /// so the checklist has something in it only after that -- hence the wait
    /// on a row rather than a fixed budget.
    private func aCheckbox() -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "setlist-check-"))
            .firstMatch
    }

    /// The + opens a checklist, a tap toggles membership and back, and then
    /// the version count switches the band to its own list. One launch: the
    /// second half starts with the checklist open, which is where the first
    /// half leaves it.
    func testThePlusOpensAChecklistOfSetlistsAndTogglesMembership() throws {
        guard openAScore() else { return XCTFail("no score opened") }

        let plus = app.buttons["score-add-setlist"]
        XCTAssertTrue(plus.waitForExistence(timeout: 30),
                      "the + is not on the score bar")
        snap("score-bar-with-the-plus")

        plus.tap()
        let box = aCheckbox()
        guard box.waitForExistence(timeout: 180) else {
            snap("no-setlists-in-the-checklist")
            return XCTFail("the checklist opened with no set list in it -- "
                           + "the seed had not filed one yet")
        }
        settle(box)
        snap("setlist-checklist-open")

        // The state BEFORE, read off the row's own accessibility value rather
        // than from the image: "in this set list" / "not in this set list".
        let before = box.value as? String ?? ""
        XCTAssertFalse(before.isEmpty, "the row does not say whether it is a member")
        let identifier = box.identifier

        box.tap()
        // The engine round-trips and the manifest refreshes, so wait on the
        // VALUE changing rather than on a wall-clock budget across that call.
        let flipped = app.descendants(matching: .any)[identifier]
        waitUntil("the membership to flip", timeout: 120) {
            (flipped.value as? String ?? before) != before
        }
        let after = flipped.value as? String ?? ""
        XCTAssertNotEqual(after, before,
                          "tapping the box changed nothing: still \(before)")
        snap("setlist-membership-toggled")

        // And the band STAYED OPEN, which is the point of a checklist: putting
        // one arrangement in three set lists must not mean reopening it twice.
        XCTAssertTrue(flipped.exists,
                      "the checklist closed on the first tap")

        // Back the other way, so the control is a toggle rather than a
        // one-way add -- and so the test leaves the library as it found it.
        flipped.tap()
        waitUntil("the membership to flip back", timeout: 120) {
            (flipped.value as? String ?? after) == before
        }
        XCTAssertEqual(flipped.value as? String, before,
                       "the box would not uncheck")

        // The + and the version count are different controls opening
        // different halves of the same band. Tapping one after the other must
        // SWITCH what the band shows rather than leaving the first one's list
        // on screen. The checklist is still open from above, which is where
        // this started when it was a test of its own.
        let versions = app.buttons["score-versions"]
        guard versions.exists else {
            throw XCTSkip("this width does not seat the version count")
        }
        versions.tap()
        let versionRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "menu-version-"))
            .firstMatch
        XCTAssertTrue(versionRow.waitForExistence(timeout: 30),
                      "the version list did not replace the checklist")
        XCTAssertFalse(aCheckbox().exists,
                       "the set list checklist is still on screen under the versions")
        snap("band-switched-from-setlists-to-versions")
    }
}
