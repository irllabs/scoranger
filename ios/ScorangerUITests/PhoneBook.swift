import XCTest

/// A book on a phone: the reader's two views, Tunes and Extract fit the bar,
/// and Extract opens with its pages above its panel (0.19.0). Phone lane.
final class PhoneBook: XCTestCase {
    func testABookReadsAndExtractsOnAPhone() {
        let app = XCUIApplication()
        app.launchArguments = ["-resetLibrary", "-shareInSampleBook"]
        app.launch()
        let asBook = app.descendants(matching: .any)["import-as-new-book"].firstMatch
        XCTAssertTrue(asBook.waitForExistence(timeout: 120))
        asBook.tap()
        // a book just imported opens on Extract
        XCTAssertTrue(app.descendants(matching: .any)["extract-mode"].waitForExistence(timeout: 180))
        XCTAssertTrue(app.descendants(matching: .any)["extract-list"].waitForExistence(timeout: 120))
        XCTAssertTrue(app.descendants(matching: .any)["book-view"].exists, "no pages above the panel")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "phone-extract"; shot.lifetime = .keepAlways; add(shot)
        app.descendants(matching: .any)["screen-back"].firstMatch.tap()
        // the reader: one page and continuous, no spread on a phone
        XCTAssertTrue(app.buttons["book-layout-page"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["book-layout-continuous"].exists)
        XCTAssertFalse(app.buttons["book-layout-spread"].exists)
        for id in ["book-tunes", "book-extract", "screen-back"] {
            let button = app.descendants(matching: .any)[id].firstMatch
            XCTAssertTrue(button.isHittable, "\(id) does not fit the phone's bar")
        }
        let reader = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        reader.name = "phone-reader"; reader.lifetime = .keepAlways; add(reader)
    }
}
