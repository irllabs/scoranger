import XCTest

/// The App Store screenshots, on the public-domain library `-seedStoreLibrary`
/// writes. Run by hand on a 6.5" iPhone and a 13" iPad with
/// TEST_RUNNER_SCORANGER_SHOT_DIR set; skipped by the gate, like every shot.
/// It asserts only that each screen arrived, so a picture of the wrong screen
/// cannot be taken quietly.
final class StoreShots: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
    }

    private func snap(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let directory = ProcessInfo.processInfo.environment["SCORANGER_SHOT_DIR"] {
            let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
            try? screenshot.pngRepresentation.write(
                to: URL(fileURLWithPath: directory).appending(path: "\(device)-\(name).png"))
        }
    }

    private func launchSeeded() {
        app = XCUIApplication()
        app.launchArguments = ["-resetLibrary", "-resetViewPreferences", "-seedStoreLibrary"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["row-amazing-grace"]
            .waitForExistence(timeout: 240), "the store library never arrived")
    }

    private func open(_ piece: String) {
        app.descendants(matching: .any)["row-\(piece)"].tap()
        let choice = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "arrangement-choice-")).firstMatch
        if choice.waitForExistence(timeout: 10) { choice.tap() }
        XCTAssertTrue(app.buttons["score-title"].waitForExistence(timeout: 240), "\(piece) never opened")
        let page = app.buttons["layout-page"]
        if page.waitForExistence(timeout: 5), page.isHittable { page.tap() }
        _ = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "canvas-"))
            .firstMatch.waitForExistence(timeout: 180)
        sleep(4)
    }

    func test1LibraryAndSetLists() {
        launchSeeded()
        sleep(2)
        snap("1-library")
        let setlists = app.buttons.matching(NSPredicate(format: "label == %@", "Set lists")).firstMatch
        XCTAssertTrue(setlists.waitForExistence(timeout: 20))
        setlists.tap()
        XCTAssertTrue(app.descendants(matching: .any)["row-share-echo-and-bubba"]
            .waitForExistence(timeout: 60), "no shared set list row")
        sleep(1)
        snap("4-setlists")
    }

    func test2ScoreWithTabAndPlayback() {
        launchSeeded()
        open("amazing-grace")
        snap("2-score-tab")
        let play = app.buttons["transport-play"]
        guard play.waitForExistence(timeout: 60) else { return XCTFail("no transport") }
        let usable = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isEnabled == true"), object: play)
        _ = XCTWaiter().wait(for: [usable], timeout: 120)
        play.tap()
        sleep(4)
        snap("5-playing")
        play.tap()
    }

    func test3WhistleFingerings() {
        launchSeeded()
        open("ode-to-joy")
        snap("3-whistle")
    }
}
