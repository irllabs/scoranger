import XCTest

/// Looking through a book the size of a Real Book.
///
/// The browser shipped in 0.6.4 with NO test of any kind. This is that test:
/// a 512-page book opens, the strip is there, it survives being flicked
/// through, the scrub bar flies across it, and the three views keep the page.
///
/// # What it is NOT
///
/// It is not the guard for the fault it was written alongside. That was
/// checked the way this repository checks things -- the fix was reverted and
/// the test run again -- and it PASSED on the broken code, in the same time.
/// It has to, and the reason is worth writing down rather than papering over:
///
///  - The cost that broke the browser is DECODING A SCAN. A page of a real
///    fake book is a full-page JPEG and takes about 4 ms; `BigBookFixture` is
///    vector and takes a quarter of a millisecond. Making the fixture heavy
///    enough to hurt would mean inventing a slow book.
///  - Even at a scan's 4 ms, eight flicks sweep a few hundred cells: seconds,
///    not the tens of seconds a deadline here could sanely allow. To fail on
///    that this would have to assert a LATENCY BUDGET, and there is no agreed
///    one -- the same reason `PerfSweep` asserts nothing.
///
/// So the fault is guarded where it can actually fail, in the unit suite:
/// `ThumbnailRequestTests` (an ask withdrawn draws 7 pages of 120 instead of
/// 120; a peek never rasterises; the store holds its budget in bytes) and
/// `PageThumbnailsTests` (the count bound it replaces was five times the
/// budget). This is end-to-end coverage of a screen that had none.
final class BookBrowser: XCTestCase {

    private var app: XCUIApplication!

    private func launch() {
        app = XCUIApplication()
        app.launchArguments = ["-resetLibrary", "-seedTestLibrary", "-seedBigBook"]
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
    }

    /// Open the seeded book. The library files books under their own segment.
    private func openTheBook() -> Bool {
        guard app.descendants(matching: .any)["library-search"]
            .waitForExistence(timeout: 240) else {
            XCTFail("the library never appeared")
            return false
        }
        let books = app.descendants(matching: .any)["segment-books"].firstMatch
        guard books.waitForExistence(timeout: 30) else {
            XCTFail("no books segment")
            return false
        }
        books.tap()
        let row = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "row-")).firstMatch
        guard row.waitForExistence(timeout: 240) else {
            XCTFail("the seeded book never appeared")
            return false
        }
        row.tap()
        return app.descendants(matching: .any)["book-thumbnails"]
            .waitForExistence(timeout: 120)
    }

    private func label() -> String {
        app.descendants(matching: .any)["book-page-label"].firstMatch.label
    }

    /// A hard flick through the strip of a 512-page book, and then a tap.
    ///
    /// The deadline is deliberately generous: see the note on the class. This
    /// says the browser works on a book of that size, not how fast.
    func testTheBrowserStillAnswersAfterFlickingThroughABigBook() {
        launch()
        guard openTheBook() else { return }

        let strip = app.descendants(matching: .any)["book-thumbnails"].firstMatch
        XCTAssertTrue(strip.exists)
        XCTAssertTrue(label().hasSuffix("/ 512"),
                      "the seeded book is not 512 pages: \(label())")

        for _ in 0..<8 {
            strip.swipeLeft(velocity: .fast)
        }

        // The question: does anything still work? A generous deadline, because
        // this is a hang test and not a latency budget.
        let before = label()
        // A tap in the strip's thumbnail row lands on whichever page is there;
        // asking 512 lazy cells which one is hittable is not a question
        // XCUITest can answer reliably.
        strip.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
        let moved = NSPredicate(format: "label != %@", before)
        expectation(for: moved, evaluatedWith:
                        app.descendants(matching: .any)["book-page-label"].firstMatch)
        waitForExpectations(timeout: 30) { error in
            XCTAssertNil(error, "the browser stopped answering after a flick "
                         + "through a 512-page book")
        }
    }

    /// The scrub bar flies the book four hundred pages in one drag -- what a
    /// reader looking for one tune does (0.19.0: it replaced typing a page).
    func testTheScrubBarFliesAcrossTheBook() {
        launch()
        guard openTheBook() else { return }
        let scrub = app.descendants(matching: .any)["book-scrub"].firstMatch
        XCTAssertTrue(scrub.waitForExistence(timeout: 30))
        let from = scrub.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5))
        from.press(forDuration: 0.2,
                   thenDragTo: scrub.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)),
                   withVelocity: .slow, thenHoldForDuration: 0.3)
        sleep(1)
        let seen = label()
        let page = Int(label().split(separator: "/").first?
            .trimmingCharacters(in: .whitespaces) ?? "") ?? 0
        XCTAssertGreaterThan(page, 380, "the scrub bar did not fly the book: \(seen)")
    }

    /// The score's three views, on a book, and the reader keeps its page
    /// through them. Extract and Tunes are on the bar (0.19.0).
    func testTheThreeViewsAndTheBar() {
        launch()
        guard openTheBook() else { return }
        for cell in ["book-layout-page", "book-layout-spread", "book-layout-continuous",
                     "book-tunes", "book-extract"] {
            XCTAssertTrue(app.buttons[cell].exists, "\(cell) is not on the book's bar")
        }
        app.descendants(matching: .any)["book-thumb-5"].firstMatch.tap()
        let five = NSPredicate(format: "label == %@", "5 / 512")
        expectation(for: five, evaluatedWith: app.descendants(matching: .any)["book-page-label"].firstMatch)
        waitForExpectations(timeout: 20)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "book-one-page"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["book-layout-spread"].tap()
        let spread = NSPredicate(format: "label BEGINSWITH %@", "5–6")
        expectation(for: spread, evaluatedWith: app.descendants(matching: .any)["book-page-label"].firstMatch)
        waitForExpectations(timeout: 20)
        XCTAssertTrue(app.buttons["book-layout-spread"].isSelected)
        sleep(2)
        let two = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        two.name = "book-two-pages"; two.lifetime = .keepAlways; add(two)
        app.buttons["book-layout-continuous"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["book-view"].waitForExistence(timeout: 20))
        sleep(2)
        let strip = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        strip.name = "book-continuous"; strip.lifetime = .keepAlways; add(strip)
        app.buttons["book-layout-page"].tap()
        app.buttons["book-tunes"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["book-tunes-panel"].waitForExistence(timeout: 10))
        let tunes = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        tunes.name = "book-tunes-panel"; tunes.lifetime = .keepAlways; add(tunes)
        app.buttons["book-extract"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["extract-mode"].waitForExistence(timeout: 30),
                      "Extract did not open")
    }
}
