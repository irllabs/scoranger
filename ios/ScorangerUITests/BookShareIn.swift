import XCTest

/// A book shared into the app: asked about, its tunes found, kept, and read
/// one at a time (0.14.0).
///
/// Before 0.14.0 a PDF from another app's share sheet could only become a
/// scan arrangement, so a book could not be shared in at all. The chooser is
/// driven here by `-shareInSampleBook`, which hands a twelve-page book to
/// `AppState.offerImport` -- the door `onOpenURL` uses -- because the
/// simulator has no share sheet to drive.
final class BookShareIn: XCTestCase {

    private var app: XCUIApplication!

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func snap(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func importTheSampleBook(_ argument: String = "-shareInSampleBook") {
        app = XCUIApplication()
        app.launchArguments = ["-resetLibrary", argument]
        app.launch()
        let asBook = element("import-as-new-book")
        XCTAssertTrue(asBook.waitForExistence(timeout: 120), "a shared file was not asked about")
        asBook.tap()
    }

    func testASharedBookIsAskedAboutFoundKeptAndRead() {
        app = XCUIApplication()
        app.launchArguments = ["-resetLibrary", "-shareInSampleBook"]
        app.launch()

        // Asked, not imported.
        let asBook = element("import-as-new-book")
        XCTAssertTrue(asBook.waitForExistence(timeout: 120),
                      "a shared file was not asked about")
        XCTAssertTrue(element("import-as-new-piece").exists)
        XCTAssertTrue(element("import-as-existing-piece").exists)
        snap("import-as")
        asBook.tap()

        // 0.19.0: the book opens on Extract, its found tunes ticked: twelve
        // titled pages, twelve tunes.
        let list = element("extract-list")
        XCTAssertTrue(list.waitForExistence(timeout: 180),
                      "the book did not open on its found tunes")
        XCTAssertTrue(app.staticTexts["12 tunes"].exists, "twelve titled pages should be twelve tunes")
        XCTAssertEqual(element("extract-found").label, "From the titles on its pages")
        XCTAssertTrue(element("extract-row-1").exists)
        XCTAssertEqual(element("extract-auto").label, "Extract 12 tunes")
        snap("extract-list")

        // Saved as the book's tune list: the book stays one book.
        element("extract-keep").tap()
        let show = element("extract-show-tunes")
        XCTAssertTrue(show.waitForExistence(timeout: 60), "saving the list said nothing")
        show.tap()
        // ... and read from the reader's Tunes panel, the list's way in.
        let first = element("book-tune-1")
        XCTAssertTrue(first.waitForExistence(timeout: 60),
                      "the saved tune list was not in the Tunes panel")
        XCTAssertTrue(element("book-tune-12").exists)
        snap("book-tunes")

        // Read like a set list: a tune, then the next one.
        first.tap()
        XCTAssertTrue(element("book-entry-page-1").waitForExistence(timeout: 30),
                      "the first tune's page was not shown")
        let next = element("book-entry-next")
        XCTAssertTrue(next.isEnabled)
        XCTAssertFalse(element("book-entry-previous").isEnabled)
        snap("book-entry-1")
        next.tap()
        XCTAssertTrue(element("book-entry-page-2").waitForExistence(timeout: 30),
                      "Next did not turn to the second tune")
        snap("book-entry-2")
    }

    /// A scanned book has no text layer, so its titles are read on the device
    /// with Vision and judged by the engine's scan rule (BookOCR, booksplit).
    func testAScannedBooksTunesAreReadFromItsPages() {
        importTheSampleBook("-shareInScannedBook")
        let found = element("extract-found")
        XCTAssertTrue(found.waitForExistence(timeout: 240),
                      "the scanned book did not open on its found tunes")
        XCTAssertEqual(found.label, "Read from its scanned pages")
        XCTAssertTrue(app.staticTexts["6 tunes"].exists,
                      "six scanned pages, each titled, should be six tunes")
        snap("scanned-book-extract")
    }

    /// One press, no confirm: the count is on the button (0.19.0).
    func testExtractingTheTunesMakesAPieceForEach() {
        importTheSampleBook()
        let extract = element("extract-auto")
        XCTAssertTrue(extract.waitForExistence(timeout: 180))
        extract.tap()
        let result = element("extract-result")
        XCTAssertTrue(result.waitForExistence(timeout: 180), "extracting said nothing")
        XCTAssertTrue(app.staticTexts["Extracted 12 tunes"].exists)
        XCTAssertTrue(app.staticTexts["12 new pieces."].exists)
        XCTAssertTrue(element("extract-result-row-1").exists, "what was made is not listed to open")
        snap("extract-result")
    }

    /// What is extracted is what is ticked: no Remove, no Join, no Split.
    func testOnlyTheTickedTunesAreExtracted() {
        importTheSampleBook()
        let check = element("extract-check-2")
        XCTAssertTrue(check.waitForExistence(timeout: 180))
        XCTAssertFalse(element("book-review-remove-1").exists)
        check.tap()
        XCTAssertEqual(element("extract-auto").label, "Extract 11 tunes")
        element("extract-select-all").tap()          // "Select all" brings it back
        XCTAssertEqual(element("extract-auto").label, "Extract 12 tunes")
        element("extract-select-all").tap()          // "Select none"
        XCTAssertFalse(element("extract-auto").isEnabled, "nothing ticked, nothing to extract")
        snap("extract-none-ticked")
    }

    /// Choose pages: Start on the current page, End on another, a name, and
    /// it goes to a new piece.
    func testAPageRangeIsMarkedWithStartAndEnd() {
        importTheSampleBook()
        XCTAssertTrue(element("extract-list").waitForExistence(timeout: 180))
        element("extract-mode-range").tap()
        let start = element("extract-range-start")
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.tap()
        // a tune starts on page 1, so Start names it
        let name = app.textFields["extract-name"].firstMatch
        XCTAssertFalse((name.value as? String ?? "").isEmpty, "Start did not name the tune")
        element("book-thumb-3").tap()
        element("extract-range-end").tap()
        XCTAssertEqual(element("extract-range-summary").label, "Pages 1–3")
        XCTAssertEqual(element("extract-range").label, "Extract pages 1–3")
        snap("extract-range")
        element("extract-range").tap()
        XCTAssertTrue(element("extract-made").waitForExistence(timeout: 120),
                      "extracting a range said nothing")
        XCTAssertTrue(element("extract-open").exists)
    }

    /// Cancel means nothing was imported.
    func testCancellingTheChoiceImportsNothing() {
        app = XCUIApplication()
        app.launchArguments = ["-resetLibrary", "-shareInSampleBook"]
        app.launch()
        XCTAssertTrue(element("import-as-new-book").waitForExistence(timeout: 120))
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertFalse(element("screen-import-as").waitForExistence(timeout: 3))
        app.buttons["Books"].firstMatch.tap()
        XCTAssertFalse(app.staticTexts["Sample Tunebook"].waitForExistence(timeout: 5),
                       "cancelling still imported the book")
    }
}
