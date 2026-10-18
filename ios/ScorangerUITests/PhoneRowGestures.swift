import XCTest

/// The ☰ drag and the row swipe on a page that SCROLLS, which is a phone's:
/// a piece's rows overflow an iPhone held sideways, and an iPad's do not.
/// Runs in the gate's phone lane.
///
/// What it holds is the coexistence the gestures were built around
/// (`ReorderableRows`): a vertical drag on a row is the page's -- it scrolls
/// and opens nothing -- while a vertical drag on the ☰ is the row's, and the
/// page stays where it was under it.
final class PhoneRowGestures: XCTestCase {
    private var app: XCUIApplication!

    private let piece = "Sous le ciel de Paris"
    private let pieceSlug = "sous-le-ciel-de-paris"
    private let quartet = "sous-le-ciel-quartet"
    private let solo = "under-paris-skies-accordion-solo"

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-resetLibrary", "-seedTestLibrary"]
        XCUIDevice.shared.orientation = .landscapeLeft
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["library-search"]
                        .waitForExistence(timeout: 90),
                      "the app never showed the library")
        let row = pieceRow
        XCTAssertTrue(row.waitForExistence(timeout: 240), "the seed never started")
        XCTAssertTrue(waitFor(240) { row.label.contains("2 arrangements") },
                      "the seed stopped at: \(row.label)")
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }

    func testAVerticalDragOnARowScrollsAndOneOnTheHamburgerMovesTheRow() {
        openPieceScreen()
        // More rows until the list runs past the bottom of the screen: on an
        // iPhone 17 Pro held sideways that is the fifth or sixth.
        let window = app.windows.firstMatch.frame
        var count = 2
        while count < 8, arrangement(numbered: count).frame.maxY <= window.maxY {
            count += 1
            app.buttons["piece-new-arrangement-\(pieceSlug)"].tap()
            XCTAssertTrue(arrangement(numbered: count).waitForExistence(timeout: 180),
                          "arrangement #\(count) never appeared")
        }
        let last = arrangement(numbered: count)
        XCTAssertGreaterThan(last.frame.maxY, window.maxY,
                             "\(count) rows fit on the screen, so nothing here can scroll -- "
                             + "this test belongs on a phone: \(last.frame) in \(window)")

        // A vertical drag that starts on a row, not its ☰: the page scrolls,
        // and the row neither opens its score nor slides to its trash.
        let title = app.descendants(matching: .any)["piece-title"].firstMatch
        let before = title.frame.minY
        let row = choice(solo)
        let start = row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05,
                    thenDragTo: row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: -2.0)))
        XCTAssertLessThan(title.frame.minY, before - 20,
                          "a vertical drag on a row did not scroll the page")
        XCTAssertFalse(app.buttons["edit-delete-\(solo)"].exists,
                       "a vertical drag slid the row open")
        XCTAssertFalse(app.buttons["score-title"].exists, "a vertical drag opened the score")
        shot("phone-row-drag-scrolled")

        // Back to the top -- by a row, which is the other direction of the
        // same claim -- then the ☰: the row moves and the page does not.
        choice(solo).swipeDown()
        XCTAssertTrue(waitFor(5) { abs(title.frame.minY - before) < 2 }, "the page did not come back")
        let grip = app.buttons["row-menu-\(quartet)"]
        let onto = app.buttons["row-menu-\(solo)"]
        grip.press(forDuration: 0.4, thenDragTo: onto, withVelocity: .slow, thenHoldForDuration: 0.3)
        XCTAssertTrue(waitFor(30) { self.choice(self.quartet).label.contains("Arrangement number 2") },
                      "the ☰ drag did not move the row: \(choice(quartet).label)")
        XCTAssertEqual(title.frame.minY, before, accuracy: 2,
                       "the page scrolled under a ☰ drag")
        shot("phone-hamburger-drag")

        // and a sideways swipe still opens the trash on a page that scrolls
        choice(solo).swipeLeft()
        let trash = app.buttons["edit-delete-\(solo)"]
        XCTAssertTrue(trash.waitForExistence(timeout: 5), "no trash button on a phone")
        XCTAssertTrue(trash.isHittable)
        XCTAssertLessThanOrEqual(trash.frame.maxX, window.maxX + 1, "the trash button is off the screen")
        shot("phone-swipe-revealed")
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

    private func arrangement(numbered n: Int) -> XCUIElement {
        app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@",
                        "arrangement-choice-", "Arrangement number \(n)")).firstMatch
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
