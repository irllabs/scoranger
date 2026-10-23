import XCTest

/// A filter belongs to the tab it was chosen on.
///
/// Ali, 2026-10-22: "in build 217 i lost all of my setlists". They were on
/// the server and on his iPhone the whole time. The library held ONE filter
/// for all three tabs, so an instrument chosen on Pieces followed him onto Set
/// lists, matched no set list, and the header read "No set lists yet". A
/// relaunch cleared the filter, which is why they "came back".
///
/// The seeded library has one piece of four arrangements and one set list
/// holding all of them, and an instrument filter matches arrangements, never
/// a set list -- so before the fix this test finds no set list row.
final class LibraryFilterPerTab: XCTestCase {

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

    private func closePanel() {
        let back = element("screen-back")
        if back.waitForExistence(timeout: 3), back.isHittable { back.tap() }
        else { element("library-filter").tap() }
    }

    func testAPiecesFilterDoesNotFollowTheReaderOntoSetLists() {
        app = XCUIApplication()
        app.launchArguments = ["-resetLibrary", "-seedTestLibrary"]
        app.launch()

        // the seed's set list, before anything is filtered
        XCTAssertTrue(element("segment-setlists").waitForExistence(timeout: 240))
        element("segment-setlists").tap()
        let setlist = element("row-test-setlist")
        XCTAssertTrue(setlist.waitForExistence(timeout: 240),
                      "the seeded set list never appeared")

        // an instrument filter on Pieces
        element("segment-pieces").tap()
        XCTAssertTrue(element("library-filter").waitForExistence(timeout: 10))
        element("library-filter").tap()
        let instrument = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "filter-instrument-"))
            .firstMatch
        XCTAssertTrue(instrument.waitForExistence(timeout: 10),
                      "the Filter panel offered no instrument to filter by")
        instrument.tap()
        closePanel()
        let piecesCount = element("library-count")
        XCTAssertTrue(piecesCount.waitForExistence(timeout: 10))
        snap("pieces-filtered")

        // Set lists: unfiltered, so the set list is there and the header
        // counts it
        element("segment-setlists").tap()
        XCTAssertTrue(setlist.waitForExistence(timeout: 10),
                      "a Pieces filter hid the set list")
        XCTAssertEqual(element("library-count").label, "1 set list")
        snap("setlists-unfiltered")

        // ...and Pieces still has its filter: its panel says one is on
        element("segment-pieces").tap()
        XCTAssertTrue(element("library-filter").waitForExistence(timeout: 10))
        element("library-filter").tap()
        XCTAssertTrue(app.staticTexts["1 on"].waitForExistence(timeout: 10),
                      "the Pieces filter was lost on the way back to Pieces")
        XCTAssertTrue(element("filter-clear").exists)
        snap("pieces-filter-kept")
    }
}
