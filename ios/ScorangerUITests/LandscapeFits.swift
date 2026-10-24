import XCTest

/// Every screen, in landscape, on a phone.
///
/// One line of project.yml made this reachable -- Ali asked for landscape and
/// `UISupportedInterfaceOrientations_iPhone` was the whole of portrait-only --
/// and the line is cheap where the consequence is not. At 874×402 the WIDTH is
/// more generous than any portrait phone and the HEIGHT is less than half of
/// one, so what breaks is chrome: a 52pt bar, a transport and a scrubber come
/// to a third of 402 before any music is drawn.
///
/// It asks the same question `DynamicTypeFits` asks and in the same words --
/// `assertFitsOnScreen`, against the WINDOW rather than against what a layout
/// intended. Two spellings of "is it cut off" would drift, and the drift would
/// be silent.
///
/// It also asserts the rotation itself, which is the part a fits-check cannot
/// see: a screen that never rotated fits trivially. So the window is measured
/// before and after and the test fails if it did not actually turn.
final class LandscapeFits: XCTestCase {

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }

    private func snap(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func launched() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-resetViewPreferences", "-seedTestLibrary"]
        app.launch()
        return app
    }

    /// The app's actual window.
    ///
    /// The BIGGEST of them, not `firstMatch`. With a panel open, firstMatch
    /// resolves to whichever window the query reaches first, and it reported
    /// 959×72 and 185pt-tall screens in the first run of this file -- so the
    /// ratio assertions below were dividing by nonsense while the fits-check,
    /// which asks separately, saw the true 874×402.
    private func windowFrame(_ app: XCUIApplication) -> CGRect {
        app.windows.allElementsBoundByIndex
            .map(\.frame)
            .filter { $0.width > 0 && $0.height > 0 }
            .max { $0.width * $0.height < $1.width * $1.height }
            ?? .zero
    }

    /// Turn the device and prove it turned, returning the landscape window.
    ///
    /// Waits for the frame to STOP MOVING, not merely to be wider than it is
    /// tall. Mid-animation the window is a rotating rectangle -- this returned
    /// (-1.6, 9.5, 886.9, 372.6) on the first run, which is the real 874×402
    /// caught in flight -- and every ratio measured against it was wrong by
    /// whatever fraction of the animation had elapsed. It made the mixer
    /// assertion fail at 267pt and then pass at 402pt when a debug print
    /// happened to delay it, which is the shape of a test that measures a
    /// moving thing.
    private func rotateToLandscape(_ app: XCUIApplication) -> CGRect {
        let portrait = windowFrame(app)
        XCUIDevice.shared.orientation = .landscapeLeft
        // Budget and re-ask, for the reason in Rotation.swift: four workers
        // drop or delay the request past anything measured on one.
        let deadline = Date().addingTimeInterval(XCTestCase.rotationBudget)
        var askedAgain = Date()
        var landscape = windowFrame(app)
        var stable = 0
        while Date() < deadline {
            usleep(200_000)
            if Date().timeIntervalSince(askedAgain) > XCTestCase.rotationRetry,
               landscape.width <= landscape.height {
                XCUIDevice.shared.orientation = .landscapeLeft
                askedAgain = Date()
            }
            let next = windowFrame(app)
            // still, landscape, and sitting at the origin on whole points --
            // an animating frame satisfies none of those for long
            let settled = next == landscape
                && next.width > next.height
                && next.origin == .zero
                && next.width == next.width.rounded()
            stable = settled ? stable + 1 : 0
            landscape = next
            if stable >= 2 { break }
        }
        XCTAssertGreaterThan(landscape.width, landscape.height,
                             "the app did not rotate: \(portrait) -> \(landscape). "
                             + "If this fails, landscape is not enabled in the plist "
                             + "and every other assertion here is vacuous.")
        XCTAssertEqual(landscape.origin, .zero,
                       "the window never settled: \(landscape) is a frame caught "
                       + "mid-rotation, so nothing measured against it means anything")
        return landscape
    }

    func testTheLibraryFitsInLandscape() {
        let app = launched()
        let search = app.descendants(matching: .any)["library-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 240), "no library")
        let window = rotateToLandscape(app)
        settle(search, still: 0.6)
        snap("library-landscape")
        assertFitsOnScreen(["library-search", "library-import", "library-new",
                            "library-sort", "library-filter", "library-edit"],
                           in: app, context: "library landscape \(window.size)")
        assertNotTruncated(["library-import", "library-new"],
                           in: app, context: "library landscape")
        // A-B: rows stay ONE column capped and centred, so a row must not span
        // the full 874 -- a label and its own chevron that far apart stop
        // reading as one row (the iPad lesson, L34).
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@ AND NOT "
                                  + "(identifier BEGINSWITH %@)", "row-", "row-menu-"))
            .firstMatch
        // 0.8: the page has the table's width (L1) and rows have the page's;
        // what must hold is that the row sits inside the page, 16 from the
        // table's edge, and not off it.
        if row.waitForExistence(timeout: 60) {
            XCTAssertGreaterThanOrEqual(row.frame.minX, 15,
                                        "a library row runs into the table's margin")
            XCTAssertLessThanOrEqual(row.frame.maxX, window.width - 15,
                                     "a library row runs off the page")
        }
    }

    func testTheScoreViewFitsInLandscape() {
        let app = launched()
        let row = app.descendants(matching: .any)["row-sous-le-ciel-de-paris"]
        XCTAssertTrue(row.waitForExistence(timeout: 240), "no arrangement")
        row.tap()
        let choice = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@",
                                  "arrangement-choice-")).firstMatch
        if choice.waitForExistence(timeout: 60) { settle(choice); choice.tap() }
        XCTAssertTrue(app.buttons["score-title"].waitForExistence(timeout: 300),
                      "the score never opened")
        settle(app.buttons["score-title"], still: 0.8)

        let window = rotateToLandscape(app)
        settle(app.buttons["score-title"], still: 0.8)
        snap("score-landscape")
        assertFitsOnScreen(["score-close", "score-title", "score-select",
                            "score-ask", "score-more", "counter-pages",
                            "page-scrubber", "scrubber-page"],
                           in: app, context: "score landscape \(window.size)")
        assertNotTruncated(["score-select", "score-ask", "score-more"],
                           in: app, context: "score landscape")

        // THE MUSIC MUST GET MOST OF IT. Chrome at 874×402 is the whole risk:
        // E-B allows 88 of 130, so the canvas is entitled to the rest. A canvas
        // squeezed under a third of the height is the failure this exists for.
        let canvas = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "canvas-"))
            .firstMatch
        if canvas.waitForExistence(timeout: 120) {
            XCTAssertGreaterThan(canvas.frame.height, window.height * 0.55,
                                 "the music got \(canvas.frame.height)pt of "
                                 + "\(window.height): chrome has taken most of "
                                 + "the screen")
        }
    }

    func testTheOptionsScreenFitsInLandscape() {
        let app = launched()
        let row = app.descendants(matching: .any)["row-sous-le-ciel-de-paris"]
        XCTAssertTrue(row.waitForExistence(timeout: 240), "no arrangement")
        row.tap()
        let choice = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@",
                                  "arrangement-choice-")).firstMatch
        if choice.waitForExistence(timeout: 60) { settle(choice); choice.tap() }
        XCTAssertTrue(app.buttons["score-title"].waitForExistence(timeout: 300),
                      "the score never opened")
        _ = rotateToLandscape(app)
        app.descendants(matching: .any)["score-more"].firstMatch.tap()
        let details = app.descendants(matching: .any)["more-details"]
        XCTAssertTrue(details.waitForExistence(timeout: 60),
                      "the options screen never appeared in landscape")
        settle(details, still: 0.5)
        snap("options-landscape")
        // A SCROLL VIEW, so a row below the fold is not a clip -- it is the
        // list being longer than 402pt, which at seven rows of 44 it simply
        // is. What must hold is that nothing is cut off SIDEWAYS (Ali's
        // complaint class: clipped at both edges) and that the last row can
        // still be reached.
        let window = windowFrame(app)
        for identifier in ["more-annotations", "more-chords", "more-selection",
                           "more-setlists", "more-details", "more-export",
                           "more-settings"] {
            let element = app.descendants(matching: .any)[identifier].firstMatch
            guard element.exists, element.frame.width > 0 else { continue }
            XCTAssertGreaterThanOrEqual(element.frame.minX, window.minX - 0.5,
                                        "\(identifier) is off the left edge")
            XCTAssertLessThanOrEqual(element.frame.maxX, window.maxX + 0.5,
                                     "\(identifier) is off the right edge")
        }
        assertNotTruncated(["more-details", "more-export", "more-settings"],
                           in: app, context: "options landscape")
        let last = app.descendants(matching: .any)["more-settings"].firstMatch
        if last.exists, !last.isHittable {
            app.swipeUp()
            XCTAssertTrue(last.isHittable,
                          "the last options row cannot be reached in landscape")
        }
    }

    /// The tray in landscape: a line at the foot of a 402pt screen, with its
    /// knobs, tempo and readout inside the window, and no more than a quarter
    /// of the height -- the music is what landscape is for.
    func testTheMixerFitsInLandscape() {
        let app = launched()
        let row = app.descendants(matching: .any)["row-sous-le-ciel-de-paris"]
        XCTAssertTrue(row.waitForExistence(timeout: 240), "no arrangement")
        row.tap()
        let choice = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@",
                                  "arrangement-choice-")).firstMatch
        if choice.waitForExistence(timeout: 60) { settle(choice); choice.tap() }
        XCTAssertTrue(app.buttons["score-title"].waitForExistence(timeout: 300),
                      "the score never opened")
        let window = rotateToLandscape(app)
        let tray = app.otherElements["transport"].firstMatch
        guard tray.waitForExistence(timeout: 120) else {
            return XCTFail("no tray in landscape")
        }
        XCTAssertTrue(app.descendants(matching: .any)["strip-mute-0"].waitForExistence(timeout: 180),
                      "the tray never grew a knob in landscape")
        settle(tray, still: 0.5)
        snap("tray-landscape")
        assertFitsOnScreen(["transport", "tray-knobs", "transport-tempo",
                            "transport-play", "transport-bar"],
                           in: app, context: "tray landscape \(window.size)")
        XCTAssertLessThan(tray.frame.height, window.height * 0.25,
                          "the tray is \(tray.frame.height)pt of "
                          + "\(window.height): it is taking the music's room")
    }
}
