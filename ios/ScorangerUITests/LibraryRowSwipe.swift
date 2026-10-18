import XCTest

/// The library's rows swipe left for the red trash button, as a piece's
/// arrangements have since 0.22.0, and Delete has left their ☰ (0.23.0).
///
/// Ali, after build 215: "The swipe to delete and hamburger menu updates; I
/// want that shipped to TestFlight asap."
///
/// The trash deletes a lone arrangement at once, because the undo bar brings
/// it back. A piece holding arrangements, a set list and a book have no undo,
/// so their trash asks in the row's own slot first. Each test waits on an
/// engine delete, so the gate runs them in its serial phase (ENGINE_SERIAL).
final class LibraryRowSwipe: XCTestCase {
    private var app: XCUIApplication!

    private let piece = "Sous le ciel de Paris"
    private let pieceSlug = "sous-le-ciel-de-paris"
    private let solo = "under-paris-skies-accordion-solo"

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    private func launch(_ extra: [String] = []) {
        app = XCUIApplication()
        app.launchArguments = ["-resetLibrary", "-seedTestLibrary"] + extra
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["library-search"]
                        .waitForExistence(timeout: 90),
                      "the app never showed the library")
    }

    /// The ☰ no longer offers Delete; the swipe does, and on a piece holding
    /// arrangements it asks first. Keep leaves the piece; Delete takes it.
    func testAPieceAsksBeforeItsTrashDeletesIt() {
        launch()
        let row = pieceRow
        XCTAssertTrue(row.waitForExistence(timeout: 240), "the seed never started")
        XCTAssertTrue(waitFor(240) { row.label.contains("2 arrangements") },
                      "the seed stopped at: \(row.label)")
        let trash = app.buttons["row-delete-\(pieceSlug)"]

        // the ☰: its actions, and no Delete among them
        let menu = app.buttons["row-menu-\(pieceSlug)"]
        menu.tap()
        XCTAssertTrue(app.buttons["row-open-\(pieceSlug)"].waitForExistence(timeout: 10),
                      "a tap on the ☰ no longer opens the row's actions")
        XCTAssertFalse(trash.exists, "Delete is still among the ☰'s actions")
        shot("library-hamburger-without-delete")
        menu.tap()
        XCTAssertTrue(waitFor(5) { !self.app.buttons["row-open-\(self.pieceSlug)"].exists },
                      "the ☰ did not close")

        row.swipeLeft()
        XCTAssertTrue(trash.waitForExistence(timeout: 5), "a swipe left showed no trash button")
        XCTAssertTrue(trash.isHittable, "the trash button is there and cannot be tapped")
        XCTAssertEqual(trash.label, "Delete \(piece)")
        XCTAssertGreaterThanOrEqual(trash.frame.width, 44, "the trash button is a sliver")
        shot("library-swipe-revealed")

        trash.tap()
        let confirm = app.buttons["confirm-delete-\(pieceSlug)"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5),
                      "a piece holding arrangements was deleted without asking")
        XCTAssertTrue(app.staticTexts["Delete \(piece) and its 2 arrangements?"].exists,
                      "the question does not say what goes with the piece")
        shot("library-piece-asks")

        app.buttons["confirm-delete-\(pieceSlug)-keep"].tap()
        XCTAssertTrue(waitFor(5) { !confirm.exists }, "Keep did not put the row back")
        XCTAssertTrue(pieceRow.exists, "Keep deleted the piece")

        pieceRow.swipeLeft()
        XCTAssertTrue(trash.waitForExistence(timeout: 5))
        trash.tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(waitFor(180) { !self.pieceRow.exists }, "the piece is still listed")
        shot("library-piece-deleted")
    }

    /// An arrangement filed under no piece is deleted at once, and the undo
    /// bar brings it back.
    func testALoneArrangementGoesAtOnceAndUndoBringsItBack() {
        launch(["-seedLibraryShape"])
        let search = app.descendants(matching: .any)["library-search"].firstMatch
        let row = app.buttons["row-\(solo)"]
        // sixteen pieces above it; the search brings it on screen
        XCTAssertTrue(waitFor(240) {
            self.app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "row-"))
                .count >= 10
        }, "the library shape never arrived")
        search.tap()
        search.typeText("Under")
        XCTAssertTrue(row.waitForExistence(timeout: 60), "no row for the unfiled arrangement")

        row.swipeLeft()
        let trash = app.buttons["row-delete-\(solo)"]
        XCTAssertTrue(trash.waitForExistence(timeout: 5), "a swipe left showed no trash button")
        trash.tap()
        XCTAssertFalse(app.buttons["confirm-delete-\(solo)"].exists,
                       "an arrangement the undo bar can bring back asked first")
        // Either identifier: the bar's `undo-bar` is handed to the Undo button
        // inside it, which is why ScorangerUITests.waitForDelete looks for both.
        let undo = app.buttons.matching(
            NSPredicate(format: "identifier IN %@ AND label == %@",
                        ["undo-delete", "undo-bar"], "Undo")).firstMatch
        XCTAssertTrue(waitFor(180) { undo.exists }, "the engine never answered the delete")
        XCTAssertTrue(waitFor(30) { !row.exists }, "the deleted arrangement is still listed")
        shot("library-arrangement-deleted")

        undo.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 60), "undo did not bring the arrangement back")
        shot("library-arrangement-undone")
    }

    /// A set list and a book ask first, and then go. Through 0.22.0 a book's
    /// Delete reached the engine as an arrangement's and was refused, so this
    /// is also the proof that a book can be deleted at all.
    func testASetListAndABookAskFirstAndThenDelete() {
        launch(["-seedTestBook"])
        XCTAssertTrue(pieceRow.waitForExistence(timeout: 240), "the seed never started")

        select("segment-setlists")
        let setlist = app.buttons["row-test-setlist"]
        XCTAssertTrue(setlist.waitForExistence(timeout: 60), "no row for the seeded set list")
        setlist.swipeLeft()
        let setlistTrash = app.buttons["row-delete-test-setlist"]
        XCTAssertTrue(setlistTrash.waitForExistence(timeout: 5), "a set list row did not swipe")
        setlistTrash.tap()
        let setlistConfirm = app.buttons["confirm-delete-test-setlist"]
        XCTAssertTrue(setlistConfirm.waitForExistence(timeout: 5),
                      "a set list was deleted without asking")
        XCTAssertTrue(app.staticTexts["Its arrangements stay in the library."].exists)
        shot("library-setlist-asks")
        setlistConfirm.tap()
        XCTAssertTrue(waitFor(180) { !setlist.exists }, "the set list is still listed")

        select("segment-books")
        let book = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@ AND NOT (identifier BEGINSWITH %@) "
                        + "AND label CONTAINS %@", "row-", "row-menu-", "Seeded Tunebook")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 240), "the seeded book never appeared")
        let slug = book.identifier.replacingOccurrences(of: "row-", with: "")
        book.swipeLeft()
        let bookTrash = app.buttons["row-delete-\(slug)"]
        XCTAssertTrue(bookTrash.waitForExistence(timeout: 5), "a book row did not swipe")
        bookTrash.tap()
        let bookConfirm = app.buttons["confirm-delete-\(slug)"]
        XCTAssertTrue(bookConfirm.waitForExistence(timeout: 5), "a book was deleted without asking")
        shot("library-book-asks")
        bookConfirm.tap()
        XCTAssertTrue(waitFor(180) { !book.exists }, "the book is still listed")
        XCTAssertFalse(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "delete that")).firstMatch.exists,
                       "the delete reported an error")
        shot("library-book-deleted")
    }

    // MARK: - helpers

    private var pieceRow: XCUIElement {
        app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@ AND NOT (identifier BEGINSWITH %@) "
                        + "AND label CONTAINS %@", "row-", "row-menu-", piece)).firstMatch
    }

    private func select(_ segment: String) {
        let button = app.buttons[segment]
        XCTAssertTrue(button.waitForExistence(timeout: 20), "no \(segment)")
        for _ in 0..<4 where !button.isSelected {
            button.tap()
            usleep(400_000)
        }
    }

    private func waitFor(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(200_000)
        }
        return condition()
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
