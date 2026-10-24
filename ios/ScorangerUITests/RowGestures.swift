import XCTest

/// The ☰ drags its row and a swipe to the left deletes it, on a piece's
/// arrangements and on a set list's running order.
///
/// Ali, on build 214: "Enable touch and drag up/down on the hamburger to move
/// the pieces up and down; do the same for piece order in set lists. This gets
/// rid of the 'Up' and 'Down'", and "swipe left on the row and that should
/// show a delete icon that's a red trashcan on the right side and then that
/// should delete."
///
/// The landing rule is `RowReorderTests`; these are the gestures in the
/// running app -- that a press on the ☰ that moves is a drag and one that does
/// not is still a tap, that the order a drop shows is the order the engine
/// kept, and that the trash button is where a thumb finds it.
///
/// Width-agnostic: the piece and set-list screens are the same views on a
/// phone, so the class runs on either simulator.
final class RowGestures: XCTestCase {
    private var app: XCUIApplication!

    private let piece = "Sous le ciel de Paris"
    private let pieceSlug = "sous-le-ciel-de-paris"
    private let quartet = "sous-le-ciel-quartet"
    private let solo = "under-paris-skies-accordion-solo"

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-resetLibrary", "-seedTestLibrary"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["library-search"]
                        .waitForExistence(timeout: 90),
                      "the app never showed the library")
        // The seed files both samples under one piece, and the row appears
        // when the FIRST lands: wait for the count, or a one-arrangement piece
        // opens its arrangement instead of its screen.
        let row = pieceRow
        XCTAssertTrue(row.waitForExistence(timeout: 240), "the seed never started")
        XCTAssertTrue(waitFor(240) { row.label.contains("2 arrangements") },
                      "the seed stopped at: \(row.label)")
    }

    // MARK: - Dragging by the ☰

    /// First to last across three rows: every row between steps up, the
    /// numbers follow the rows, and the order is the one the engine kept --
    /// read again from a fresh piece screen, not from the list that drew it.
    func testDraggingAnArrangementFromFirstToLastByItsHamburger() {
        openPieceScreen()
        app.buttons["piece-new-arrangement-\(pieceSlug)"].tap()
        let third = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@",
                        "arrangement-choice-", "Arrangement number 3")).firstMatch
        XCTAssertTrue(third.waitForExistence(timeout: 180),
                      "the new arrangement never appeared as #3")
        let newSlug = third.identifier.replacingOccurrences(of: "arrangement-choice-", with: "")
        XCTAssertTrue(choice(quartet).label.contains("Arrangement number 1"), choice(quartet).label)
        shot("drag-before")

        drag(quartet, toRowOf: newSlug)

        XCTAssertTrue(waitFor(30) { self.choice(self.quartet).label.contains("Arrangement number 3") },
                      "the dragged row did not land last: \(choice(quartet).label)")
        XCTAssertTrue(choice(solo).label.contains("Arrangement number 1"),
                      "the row it passed did not step up to #1: \(choice(solo).label)")
        XCTAssertTrue(choice(newSlug).label.contains("Arrangement number 2"),
                      "the row it passed did not step up to #2: \(choice(newSlug).label)")
        XCTAssertLessThan(choice(solo).frame.minY, choice(quartet).frame.minY,
                          "the numbers moved and the rows did not")
        shot("drag-after-drop")

        // the engine kept it: back to the library and in again
        app.buttons["screen-back"].firstMatch.tap()
        openPieceScreen()
        XCTAssertTrue(waitFor(30) { self.choice(self.quartet).label.contains("Arrangement number 3") },
                      "the order did not survive leaving the screen: \(choice(quartet).label)")
        XCTAssertTrue(choice(solo).label.contains("Arrangement number 1"), choice(solo).label)
        shot("drag-after-reopen")
    }

    /// A plain tap on the ☰ is still the row's actions. They carry no Up or
    /// Down -- the drag replaced both -- and DO carry Delete again (0.23.4,
    /// Ali: "add Delete"): the swipe is there too, but nobody finds a swipe.
    /// Delete asks in place, where it can be seen, and Keep keeps.
    func testATapOnTheHamburgerOpensTheActionsWithDeleteAndNoUpOrDown() {
        openPieceScreen()
        let menu = app.buttons["row-menu-\(solo)"]
        XCTAssertTrue(menu.waitForExistence(timeout: 20))
        menu.tap()
        XCTAssertTrue(app.buttons["arrangement-duplicate-\(solo)"].waitForExistence(timeout: 10),
                      "a tap on the ☰ no longer opens the row's actions")
        XCTAssertTrue(app.buttons["arrangement-manage-\(solo)"].exists)
        for gone in ["arr-up-\(solo)", "arr-down-\(solo)"] {
            XCTAssertFalse(app.buttons[gone].exists, "\(gone) is still among the row's actions")
        }
        XCTAssertTrue(choice(solo).label.contains("Arrangement number 2"),
                      "a tap moved the row: \(choice(solo).label)")
        shot("hamburger-tap-actions")

        let delete = app.buttons["arrangement-delete-\(solo)"]
        XCTAssertTrue(delete.exists, "the row's actions carry no Delete")
        delete.tap()
        let confirm = app.buttons["arrangement-delete-\(solo)-confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Delete did not ask first")
        XCTAssertTrue(waitFor(5) { confirm.isHittable },
                      "the question opened where it cannot be seen or pressed")
        shot("hamburger-delete-asks")
        app.buttons["arrangement-delete-\(solo)-keep"].tap()
        XCTAssertTrue(choice(solo).waitForExistence(timeout: 5), "Keep did not keep the arrangement")
    }

    /// The running order: the second member dragged above the first, kept by
    /// the engine, and so the order Play starts from.
    func testDraggingASetListMemberReordersTheRunningOrder() {
        openSetlistScreen()
        let first = member(quartet)
        let second = member(solo)
        XCTAssertTrue(first.waitForExistence(timeout: 30), "the seeded set list lists no quartet")
        XCTAssertTrue(second.exists, "the seeded set list lists no solo")
        XCTAssertLessThan(first.frame.minY, second.frame.minY,
                          "the seed's running order changed; this test assumes quartet first")
        shot("setlist-drag-before")

        drag(solo, toRowOf: quartet)

        XCTAssertTrue(waitFor(30) { self.member(self.solo).frame.minY < self.member(self.quartet).frame.minY },
                      "the dragged member did not move above the other")
        shot("setlist-drag-after-drop")

        // kept: out to the library and back in
        app.buttons["screen-back"].firstMatch.tap()
        openSetlistScreen()
        XCTAssertTrue(member(solo).waitForExistence(timeout: 30))
        XCTAssertTrue(waitFor(30) { self.member(self.solo).frame.minY < self.member(self.quartet).frame.minY },
                      "the running order did not survive leaving the screen")
        shot("setlist-drag-after-reopen")
    }

    // MARK: - Swiping to delete

    /// A swipe to the left uncovers a red trash button at the row's right
    /// edge; swiping back closes it; tapping it deletes, with the undo bar
    /// as the way back.
    func testSwipingARowLeftRevealsTheTrashAndDeletes() {
        openPieceScreen()
        let row = choice(solo)
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        let trash = app.buttons["edit-delete-\(solo)"]
        XCTAssertFalse(trash.exists, "the trash button is there before any swipe")

        row.swipeLeft()
        XCTAssertTrue(trash.waitForExistence(timeout: 5), "a swipe left showed no trash button")
        XCTAssertTrue(trash.isHittable, "the trash button is there and cannot be tapped")
        XCTAssertTrue(trash.label.hasPrefix("Delete "), "the trash button says \(trash.label)")
        XCTAssertTrue(choice(solo).label.contains(String(trash.label.dropFirst("Delete ".count))),
                      "the trash button (\(trash.label)) does not name the row it deletes "
                      + "(\(choice(solo).label))")
        let menu = app.buttons["row-menu-\(solo)"]
        // At the row's right edge, as tall as the row, and wide enough to hit.
        XCTAssertGreaterThanOrEqual(trash.frame.width, 44, "the trash button is a sliver")
        XCTAssertGreaterThanOrEqual(trash.frame.height, 44)
        XCTAssertGreaterThanOrEqual(trash.frame.maxX, menu.frame.maxX,
                                    "the trash button is not at the row's right edge")
        XCTAssertLessThanOrEqual(menu.frame.maxX, trash.frame.minX + 1,
                                 "the row did not slide aside: its ☰ is under the trash button")
        shot("swipe-revealed")

        // swiping back closes it
        row.swipeRight()
        XCTAssertTrue(waitFor(5) { !trash.exists }, "a swipe right did not close the row")
        XCTAssertTrue(choice(solo).exists, "closing the row deleted it")

        // open again, and a tap elsewhere closes it without opening anything
        row.swipeLeft()
        XCTAssertTrue(trash.waitForExistence(timeout: 5))
        choice(quartet).tap()
        XCTAssertTrue(waitFor(5) { !trash.exists }, "a tap elsewhere did not close the row")
        XCTAssertFalse(app.buttons["score-title"].exists,
                       "the tap that closed the row also opened a score")

        row.swipeLeft()
        XCTAssertTrue(trash.waitForExistence(timeout: 5))
        trash.tap()

        // the engine's answer is the undo bar, or the row already gone
        let undo = app.buttons["undo-delete"]
        XCTAssertTrue(waitFor(180) { undo.exists || !self.choice(self.solo).exists },
                      "the engine never answered the delete")
        XCTAssertTrue(waitFor(30) { !self.choice(self.solo).exists },
                      "the deleted arrangement is still listed")
        XCTAssertTrue(choice(quartet).label.contains("Arrangement number 1"),
                      "the arrangement left behind is not #1: \(choice(quartet).label)")
        shot("swipe-after-delete")
    }

    /// A set-list row swiped and its trash tapped leaves the set list and
    /// stays in the library.
    func testSwipingASetListMemberLeftRemovesItFromTheSetList() {
        openSetlistScreen()
        let row = member(solo)
        XCTAssertTrue(row.waitForExistence(timeout: 30))
        row.swipeLeft()
        let trash = app.buttons["setlist-remove-\(solo)"]
        XCTAssertTrue(trash.waitForExistence(timeout: 5), "a swipe left showed no trash button")
        XCTAssertTrue(trash.label.hasSuffix("from the set list"),
                      "the trash button does not say it only takes the row out: \(trash.label)")
        shot("setlist-swipe-revealed")
        trash.tap()
        XCTAssertTrue(waitFor(180) { !self.member(self.solo).exists },
                      "the member is still in the set list")
        XCTAssertTrue(member(quartet).exists, "the other member went with it")
        shot("setlist-swipe-after-remove")

        // still in the library, under its piece
        app.buttons["screen-back"].firstMatch.tap()
        openPieceScreen()
        XCTAssertTrue(choice(solo).waitForExistence(timeout: 30),
                      "taking it out of the set list deleted the arrangement")
    }

    // MARK: - helpers

    private var pieceRow: XCUIElement {
        app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@ AND NOT (identifier BEGINSWITH %@) "
                        + "AND label CONTAINS %@", "row-", "row-menu-", piece)).firstMatch
    }

    private func choice(_ slug: String) -> XCUIElement {
        app.buttons["arrangement-choice-\(slug)"]
    }

    private func member(_ slug: String) -> XCUIElement {
        app.buttons["setlist-member-\(slug)"]
    }

    private func openPieceScreen() {
        let segment = app.buttons["segment-pieces"]
        if segment.waitForExistence(timeout: 20) {
            for _ in 0..<4 where !segment.isSelected {
                segment.tap()
                usleep(400_000)
            }
        }
        let row = pieceRow
        XCTAssertTrue(row.waitForExistence(timeout: 60), "no row for \(piece)")
        row.tap()
        XCTAssertTrue(app.buttons["piece-new-arrangement-\(pieceSlug)"].waitForExistence(timeout: 30),
                      "the piece screen did not open")
        XCTAssertTrue(choice(quartet).waitForExistence(timeout: 30), "the piece lists no quartet")
    }

    /// The seeded set list's own screen: its row's ☰, then Set list.
    private func openSetlistScreen() {
        let segment = app.buttons["segment-setlists"]
        XCTAssertTrue(segment.waitForExistence(timeout: 20), "no Set lists segment")
        for _ in 0..<4 where !segment.isSelected {
            segment.tap()
            usleep(400_000)
        }
        let menu = app.buttons["row-menu-test-setlist"]
        XCTAssertTrue(menu.waitForExistence(timeout: 30), "no ☰ on the seeded set list")
        let toScreen = app.buttons["row-setlist-screen-test-setlist"]
        for _ in 0..<3 where !toScreen.exists {
            menu.tap()
            _ = toScreen.waitForExistence(timeout: 5)
        }
        XCTAssertTrue(toScreen.exists, "the set list row's ☰ offers no Set list")
        toScreen.tap()
    }

    /// Press a row's ☰, then drag it slowly onto another row's ☰ and hold
    /// there a moment before lifting. The press first: a ☰ flicked is a
    /// scroll of the page, a ☰ pressed and moved is a drag.
    private func drag(_ slug: String, toRowOf target: String) {
        let grip = app.buttons["row-menu-\(slug)"]
        let destination = app.buttons["row-menu-\(target)"]
        XCTAssertTrue(grip.waitForExistence(timeout: 20), "no ☰ on \(slug)")
        XCTAssertTrue(destination.exists, "no ☰ on \(target)")
        grip.press(forDuration: 0.4, thenDragTo: destination,
                   withVelocity: .slow, thenHoldForDuration: 0.3)
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
