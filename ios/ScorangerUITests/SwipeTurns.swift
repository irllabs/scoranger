import XCTest

/// D (0.8.0 build 196): in performance mode a swipe turns the page, the tap on
/// the right edge still does, the turn stops at either end, and the page
/// readout follows a swipe-turn.
final class SwipeTurns: XCTestCase {

    private var app: XCUIApplication!

    private func counter() -> String {
        let chip = app.descendants(matching: .any)["counter-pages"].firstMatch
        return chip.exists ? chip.label : ""
    }

    private func page() -> Int? {
        // "p. 2 / 9" -> 2
        let words = counter().split(separator: " ")
        return words.count >= 2 ? Int(words[1]) : nil
    }

    private func swipe(_ direction: Int) {
        let canvas = app.scrollViews["score-canvas"]
        let from = canvas.coordinate(withNormalizedOffset: CGVector(dx: direction > 0 ? 0.8 : 0.2, dy: 0.5))
        let to = canvas.coordinate(withNormalizedOffset: CGVector(dx: direction > 0 ? 0.2 : 0.8, dy: 0.5))
        from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .fast, thenHoldForDuration: 0.05)
        sleep(1)
    }

    private func expectPage(_ expected: Int, _ why: String) {
        let ok = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label BEGINSWITH %@", "p. \(expected) "),
            object: app.descendants(matching: .any)["counter-pages"].firstMatch)
        XCTAssertEqual(XCTWaiter().wait(for: [ok], timeout: 10), .completed,
                       "\(why): the readout says \"\(counter())\", expected page \(expected)")
    }

    func testASwipeTurnsThePageInPerformanceModeAndStopsAtTheEnds() {
        app = XCUIApplication()
        app.launchArguments = ["-resetLibrary", "-resetViewPreferences", "-seedTestLibrary"]
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        _ = app.descendants(matching: .any)["library-search"].waitForExistence(timeout: 240)
        waitForTheSeededPiece(app).tap()
        let choice = app.descendants(matching: .any)["arrangement-choice-sous-le-ciel-quartet"]
        XCTAssertTrue(choice.waitForExistence(timeout: 60), "the piece screen offered no quartet")
        choice.tap()
        XCTAssertTrue(app.buttons["score-title"].waitForExistence(timeout: 300), "the score did not open")
        let canvas = app.scrollViews["score-canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 240), "no canvas")
        XCTAssertTrue(app.descendants(matching: .any)["counter-pages"].waitForExistence(timeout: 60),
                      "no page readout")
        sleep(2)

        // Into performance mode, where Ali met it.
        let perform = app.buttons["score-performance"]
        XCTAssertTrue(perform.waitForExistence(timeout: 20), "no way into performance mode")
        perform.tap()
        XCTAssertTrue(app.otherElements["performance-bar"].waitForExistence(timeout: 20))
        sleep(1)
        expectPage(1, "at the start")

        // A swipe leftwards brings the next page; the readout follows.
        swipe(+1)
        expectPage(2, "after a swipe forward")
        swipe(+1)
        expectPage(3, "after a second swipe forward")

        // A swipe rightwards goes back.
        swipe(-1)
        expectPage(2, "after a swipe back")
        swipe(-1)
        expectPage(1, "after a second swipe back")

        // The end: a swipe back on page 1 stays on page 1.
        swipe(-1)
        sleep(1)
        expectPage(1, "a swipe back at the first page")

        // And the tap on the right edge still turns.
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        expectPage(2, "after a tap on the right edge")
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.5)).tap()
        expectPage(1, "after a tap on the left edge")
    }
}
