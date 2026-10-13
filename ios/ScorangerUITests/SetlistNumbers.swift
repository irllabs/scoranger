import XCTest

/// A set list's titles line up (0.20.1). The arrangement stamp (#1, #5) sat
/// between the ordinal and the title, and only some rows carry one, so the
/// titles were in two columns (Ali's photograph of Echo and Baba). It now
/// stands at the end of the row, beside the menu.
final class SetlistNumbers: XCTestCase {

    private var app: XCUIApplication!

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func beginning(_ prefix: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix)).firstMatch
    }

    func testTheArrangementStampStandsAtTheEndOfTheRow() {
        app = XCUIApplication()
        app.launchArguments = ["-resetLibrary", "-seedTestLibrary"]
        app.launch()
        let setlists = app.buttons["segment-setlists"]
        XCTAssertTrue(setlists.waitForExistence(timeout: 240), "the library never appeared")
        for _ in 0..<4 where !setlists.isSelected {
            setlists.tap()
            usleep(400_000)
        }
        let menu = beginning("row-menu-")
        XCTAssertTrue(menu.waitForExistence(timeout: 40), "no set list row")
        menu.tap()
        let toScreen = beginning("row-setlist-screen-")
        XCTAssertTrue(toScreen.waitForExistence(timeout: 10), "the row's ☰ offers no Set list")
        toScreen.tap()
        let member = beginning("setlist-member-")
        XCTAssertTrue(member.waitForExistence(timeout: 30), "nothing is listed in the set list")
        let slug = member.identifier.replacingOccurrences(of: "setlist-member-", with: "")
        let stamp = element("setlist-number-\(slug)")
        XCTAssertTrue(stamp.waitForExistence(timeout: 10),
                      "the seeded arrangements share a piece, so each carries a number")
        XCTAssertGreaterThan(stamp.frame.minX, member.frame.midX,
                             "the stamp is not at the end of the row")
        XCTAssertLessThan(stamp.frame.maxX, beginning("row-menu-").frame.minX + 1,
                          "the stamp sits beyond the menu")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "setlist-stamps-trailing"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
