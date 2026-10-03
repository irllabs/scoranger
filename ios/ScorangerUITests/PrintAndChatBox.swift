import XCTest

/// Print from the score's bar, and a chat box that keeps its shape (0.17.0).
///
/// Ali: "add a print button at the score in the top bar along with the other
/// buttons ... use the standard print ... available in single page view and
/// double page view", not in the strip; and "the chat box ... gets messy if I
/// stretch it up to make it taller. The orange outline does not fit the box."
final class PrintAndChatBox: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
    }

    private func snap(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func openFirstScore() {
        let row = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "row-")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 240), "the seeded library never appeared")
        row.tap()
        if !app.buttons["score-title"].waitForExistence(timeout: 5) {
            let open = app.buttons.matching(
                NSPredicate(format: "identifier BEGINSWITH %@", "arrangement-")).firstMatch
            if open.waitForExistence(timeout: 8) { open.tap() }
        }
        XCTAssertTrue(app.buttons["score-title"].waitForExistence(timeout: 120))
        _ = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "canvas-"))
            .firstMatch.waitForExistence(timeout: 180)
    }

    func testPrintOpensTheSystemSheetOnThePagesAndNotOnTheStrip() {
        app = XCUIApplication()
        app.launchArguments = ["-resetLibrary", "-seedTestLibrary"]
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        openFirstScore()

        app.buttons["layout-page"].tap()
        let print = app.buttons["score-print"]
        XCTAssertTrue(print.waitForExistence(timeout: 20), "no Print on the bar")
        let enabled = NSPredicate(format: "isEnabled == true")
        expectation(for: enabled, evaluatedWith: print)
        waitForExpectations(timeout: 120)   // the engraving has to exist to be printed
        snap("01-bar-with-print")
        print.tap()
        // The system's own sheet: on iPadOS a bar titled "Options" over a
        // "Printer" row (measured: "No Printer Selected" on a simulator).
        let sheet = app.staticTexts["Printer"].firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 20), "the system print sheet did not open")
        snap("02-print-sheet")
        // The iPadOS sheet closes with an ✕ ("Close"), not a Cancel button.
        let close = app.buttons.matching(
            NSPredicate(format: "label IN %@", ["Close", "Cancel"])).firstMatch
        if close.exists {
            close.tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.9)).tap()
        }
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 10), "the print sheet did not close")

        app.buttons["layout-spread"].tap()
        XCTAssertTrue(print.waitForExistence(timeout: 10))
        expectation(for: enabled, evaluatedWith: print)
        waitForExpectations(timeout: 60)

        app.buttons["layout-continuous"].tap()
        expectation(for: NSPredicate(format: "isEnabled == false"), evaluatedWith: print)
        waitForExpectations(timeout: 20)
        snap("03-strip-print-off")
    }

    func testAStretchedChatBoxKeepsOneShape() {
        app = XCUIApplication()
        app.launchArguments = ["-resetLibrary", "-seedTestLibrary"]
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        openFirstScore()
        app.buttons["score-ask"].tap()
        let field = app.descendants(matching: .any)["chat-input"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        field.tap()
        let grip = app.descendants(matching: .any)["chat-input-grip"].firstMatch
        XCTAssertTrue(grip.waitForExistence(timeout: 10))
        let before = grip.frame.minY
        let from = grip.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        from.press(forDuration: 0.2,
                   thenDragTo: from.withOffset(CGVector(dx: 0, dy: -180)))
        sleep(1)
        // At least 30pt: with the keyboard up the room above the box is what
        // caps it, and under the gate's four simulators the same 180pt drag
        // grew it 58pt rather than the 100+ it grows alone. The SHAPE is what
        // this test is for, and the photograph is where that is read.
        XCTAssertLessThan(grip.frame.minY, before - 30, "the box did not grow")
        snap("04-chat-box-tall")
    }
}
