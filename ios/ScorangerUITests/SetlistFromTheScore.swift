import XCTest

/// Filing an arrangement into a set list without leaving the score (§16).
///
/// Ali: he can only do it from the library, not while looking at the music.
/// The membership screen has existed since 0.6.11, opened by a "+" on the score
/// bar — but the "+" is the FIRST control the bar gives up as it narrows, so on
/// a phone it is never there at all. The reasoning at the time was written
/// down: "the library's set list picker still offers the same operation, so
/// this costs a shortcut rather than a feature." True about the operation,
/// wrong about the reader.
///
/// The ruling is that ⋯ PUSHES the pieces list's own screen — not a popover
/// (the app has none), not a band, not a second checklist. So these tests are
/// mostly about sameness: the same identifiers, the same wording, the same way
/// out, whichever entrance was used.
///
/// At phone width the bar offers nothing at all, so ⋯ is the only route there
/// is; on an iPad the "+" is also on the bar. The row is asserted at whatever
/// width the test happens to run, because the ruling puts it at every width.
final class SetlistFromTheScore: XCTestCase {

    private func openScore(_ app: XCUIApplication) {
        // -seedTestLibrary: this ran on whatever library the simulator's
        // previous test left, and on a fresh simulator there was no row to open.
        app.launchArguments += ["-resetViewPreferences", "-seedTestLibrary",
                                "-ScorangerUITest", "1"]
        app.launch()
        let row = Self.libraryRow(app)
        XCTAssertTrue(row.waitForExistence(timeout: 120), "no library row to open")
        row.tap()
        openWhicheverArrives(app)
        XCTAssertTrue(app.buttons["score-title"].waitForExistence(timeout: 240),
                      "score never opened")
    }

    private func openOptions(_ app: XCUIApplication) {
        app.buttons["score-more"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["more-details"]
                        .waitForExistence(timeout: 20),
                      "the options screen never opened")
    }

    private func setlistsRow(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["more-setlists"]
    }

    /// A library row, and not a library row's ☰ -- "row-menu-<slug>" begins
    /// with "row-" too, and firstMatch picked it on the piece screen, where it
    /// is behind the row and not hittable.
    private static func libraryRow(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@ AND NOT "
                                  + "(identifier BEGINSWITH %@)", "row-", "row-menu-"))
            .firstMatch
    }

    // 1 — the row itself, 2 — where it goes, 3 — the ruling's catch.
    //
    // One launch for the three: each goes ⋯ → Set lists from the same score,
    // and the order is chosen so none reads state an earlier one changed. The
    // fourth (both entrances) stays its own test: it compares the checklist's
    // label across two entrances, and a toggle or a new set list still
    // landing through the engine would make that comparison race.
    func testTheRowLeadsToThePiecesListsOwnScreenAndEmptyHasAnExit() {
        let app = XCUIApplication()
        openScore(app)

        // The row is there at EVERY width -- that is the ruling, and it is why
        // this asserts nothing about the bar. An earlier version asserted the
        // bar had no "+", which is true on a phone, false on the iPad the gate
        // runs on, and contradicts §16 either way: a menu whose contents move
        // with the width is the thing being fixed.
        openOptions(app)
        let row = setlistsRow(app)
        XCTAssertTrue(row.waitForExistence(timeout: 20),
                      "the ⋯ screen offers no way into the set lists")
        XCTAssertTrue(row.label.contains("Set lists"),
                      "the destination is named \"Set lists\" on the pieces list "
                      + "too, and one screen has one name — got \(row.label)")
        XCTAssertFalse(row.label.lowercased().contains("add to"),
                       "the screen adds AND removes, so it is not an \"add\" action")
        XCTAssertFalse(row.label.contains("…"),
                       "an ellipsis promises a dialog; this pushes a screen")
        // It states where the arrangement sits, the way every row there does.
        // The value is read off the COMPOSED label -- SwiftUI builds a Button's
        // accessibility label from its children, so the row reads
        // "Set lists, none" or "Set lists, Test setlist" and there is no
        // separate `value` to look at.
        XCTAssertNotEqual(row.label.trimmingCharacters(in: .whitespaces), "Set lists",
                          "the row should state its membership too, got \(row.label)")

        // 2 — where it goes
        row.tap()

        // the pieces list's own identifiers, because it is the same screen
        let chooser = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "chooser-")).firstMatch
        XCTAssertTrue(chooser.waitForExistence(timeout: 20),
                      "the membership checklist never appeared")
        XCTAssertTrue(app.descendants(matching: .any)["setlists-new"].exists,
                      "the screen should offer a new set list, as it does from the library")

        // toggling is what this screen is for, and it stays put while you do it
        chooser.tap()
        XCTAssertTrue(chooser.waitForExistence(timeout: 10),
                      "the checklist should stay open for a second tick")

        // and back returns to ⋯, not to the library
        // 0.8: the set lists are a panel state opened from More; ‹ in the
        // panel's header goes back to More.
        app.descendants(matching: .any)["panel-back"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["more-details"]
                        .waitForExistence(timeout: 20),
                      "back from the set lists should land on More")

        // 3 — the ruling's catch. In again from More, so this starts where a
        // fresh entrance would: the toggle above has been made, and nothing
        // here reads which set lists the arrangement is in.
        setlistsRow(app).tap()

        let make = app.descendants(matching: .any)["setlists-new"]
        XCTAssertTrue(make.waitForExistence(timeout: 20),
                      "a reader with no set lists must have something to press")

        // The dead end this replaced: a note saying set lists are made in the
        // library, on a screen reached FROM the score, with no library in front
        // of it to go back to.
        let deadEnd = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] %@", "No set lists yet")).firstMatch
        XCTAssertFalse(deadEnd.exists,
                       "this screen must never send a reader to the library to continue")

        // and the exit works: naming one files this arrangement into it
        make.tap()
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "no name to type into")
        field.tap()
        field.typeText("From the score")
        app.buttons["Save"].firstMatch.tap()

        let made = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "From the score")).firstMatch
        XCTAssertTrue(made.waitForExistence(timeout: 30),
                      "the set list it made should be on the list it made it from")
    }

    // 4 — one behaviour, two entrances
    func testBothEntrancesLandOnTheSameScreen() {
        let app = XCUIApplication()
        openScore(app)
        openOptions(app)
        setlistsRow(app).tap()
        let fromScore = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "chooser-")).firstMatch
        XCTAssertTrue(fromScore.waitForExistence(timeout: 20))
        let scoreSideLabel = fromScore.label
        let scoreSideIdentifier = fromScore.identifier

        // out to the library and in the other way: a piece's arrangement row.
        // Two screens deep -- set lists sits on top of options, and options
        // covers the score, so the bar's ✕ is not reachable until both are off.
        // Located by LABEL, not by identifier. An accessibilityIdentifier put
        // on a whole Screen lands on its first element and replaces what was
        // there, so the options screen's back button reports `score-options`
        // and the piece screen's reports `screen-piece-<slug>` -- the label is
        // the part that survives both.
        func back(to where_: String) -> XCUIElement {
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "label == %@", "Back to \(where_)"))
                .firstMatch
        }
        // 0.8: ‹ in the panel goes back to More; Done closes the panel.
        _ = back
        app.descendants(matching: .any)["panel-back"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["more-details"]
                        .waitForExistence(timeout: 20),
                      "back from set lists should land on More")
        app.descendants(matching: .any)["panel-done"].firstMatch.tap()
        XCTAssertTrue(app.buttons["score-close"].waitForExistence(timeout: 20),
                      "Done should leave the score showing")
        app.buttons["score-close"].tap()

        // Closing the score lands back on the PIECE screen -- that is how we
        // came in -- and the library's own way to the same place is behind an
        // arrangement's ☰ there.
        let menu = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "row-menu-")).firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 60),
                      "no arrangement to manage on the piece screen")
        // The page is laying itself out beside its panel at rest (P1); tap
        // where the ☰ is once it has settled, by coordinate if need be.
        settle(menu, still: 0.6)
        if menu.isHittable { menu.tap() }
        else { menu.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        // The row's Arrangement action opens the arrangement beside the row.
        let manage = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "arrangement-manage-")).firstMatch
        XCTAssertTrue(manage.waitForExistence(timeout: 20), "the row's ☰ offers no Arrangement")
        manage.tap()
        let arrangementSetlists = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@",
                                  "arrangement-setlists-")).firstMatch
        XCTAssertTrue(arrangementSetlists.waitForExistence(timeout: 30),
                      "the library path to the set lists is not where it was")
        arrangementSetlists.tap()
        let fromLibrary = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "chooser-")).firstMatch
        XCTAssertTrue(fromLibrary.waitForExistence(timeout: 20),
                      "the library entrance should reach the same checklist")
        XCTAssertEqual(fromLibrary.identifier, scoreSideIdentifier,
                       "both entrances should list the same set lists, identically")
        XCTAssertEqual(fromLibrary.label, scoreSideLabel,
                       "and word them identically")
    }
}
