import XCTest

/// The render overhaul's evidence, and its regression.
///
/// The fault it exists to hold shut: Verovio's `setOptions` MERGES, so an
/// option one layout's set names and the other's omits is not a default -- it
/// is a value the first layout leaves on the shared toolkit for the second to
/// find. The paged set did not name `breaks`. One visit to continuous mode set
/// it to "none", and every paged engrave for the rest of the session laid the
/// whole score out as ONE system on one enormous page: no pagination, a counter
/// reading "p. 1 / 1", a blurred raster (the strip is 17000pt wide and the
/// paged canvas caps a page at 5200px) and thumbnails of the whole score
/// squeezed into a page-shaped box.
///
/// So the assertion is the round trip, not the first render: page, then
/// continuous, then page again, and the score must still have its pages.
///
/// Run it on its own, screenshots and all:
///   xcodebuild test -project Scoranger.xcodeproj -scheme Scoranger \
///     -destination "platform=iOS Simulator,id=<udid>" \
///     -only-testing:ScorangerUITests/RenderShot -resultBundlePath out.xcresult
///   xcrun xcresulttool export attachments --path out.xcresult --output-path shots
final class RenderShot: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        // every step photographs something; one missing control must not cost
        // the rest of the evidence
        continueAfterFailure = true
    }

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

    /// A fixed pause. What is LEFT of it after the condition-wait pass: the
    /// polling interval inside `waitForPages`/`waitFor`, the interval this
    /// deliberately lets playback advance across, and the pauses before a
    /// SCREENSHOT of the continuous strip -- which has no page counter, no
    /// annotation canvas and nothing else to observe, so there is no fact to
    /// wait for and a shorter pause would photograph the previous layout.
    private func settle(_ seconds: TimeInterval = 1.2) {
        Thread.sleep(forTimeInterval: seconds)
    }

    /// The page on the canvas: an engraving that has landed, rather than a
    /// canvas that exists.
    private var engravedPage: XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "canvas-"))
            .firstMatch
    }

    @discardableResult
    private func tap(_ id: String, wait: TimeInterval = 6) -> Bool {
        for element in [app.buttons[id], app.otherElements[id], app.staticTexts[id]]
        where element.exists && element.isHittable {
            element.tap()
            return true
        }
        if app.buttons[id].waitForExistence(timeout: wait), app.buttons[id].isHittable {
            app.buttons[id].tap()
            return true
        }
        print("RENDERSHOT: no element \(id)")
        return false
    }

    /// What the page counter says right now, or "" when there is none.
    ///
    /// Read through `snapshot()`, in ONE query. `chip.exists ? chip.label : ""`
    /// is two: the element can go between them, and reading `.label` off one
    /// that has gone records a test failure that cannot be caught. This poller
    /// runs while the counter is DELIBERATELY being removed -- switching to
    /// continuous takes it away -- so it is polling exactly the window the
    /// race lives in, and it failed intermittently on both trees with
    /// "Failed to get matching snapshot: No matches found for counter-pages".
    /// `snapshot()` throws in Swift, so `try?` is an answer rather than a
    /// failure, and the absent counter reads as "" the way it is meant to.
    private var counter: String {
        (try? app.staticTexts["counter-pages"].snapshot().label) ?? ""
    }

    /// The total in "p. 3 / 9", or 0 when the counter is absent.
    private func pages(in label: String) -> Int {
        guard let slash = label.lastIndex(of: "/") else { return 0 }
        return Int(label[label.index(after: slash)...]
            .trimmingCharacters(in: .whitespaces)) ?? 0
    }

    /// Wait for a re-engrave to land. Switching layout re-engraves the whole
    /// score, and the PREVIOUS pages deliberately stay up until the new ones
    /// arrive (#44) -- so a screenshot taken too early is a photograph of the
    /// last layout, whatever the fix did.
    @discardableResult
    private func waitForPages(_ want: (Int) -> Bool,
                              timeout: TimeInterval = 90) -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let now = counter
            if want(pages(in: now)) { settle(0.8); return counter }
            settle(0.5)
        }
        return counter
    }

    /// The transport's own bar readout, which says whether a sound is running.
    /// One query, for the reason above.
    private var transportBar: String {
        (try? app.staticTexts["transport-bar"].snapshot().label) ?? ""
    }

    /// Poll for a condition. Playback has to be BUILT before it can play, and
    /// how long that takes is a property of the score, not a number to guess.
    private func waitFor(_ seconds: TimeInterval, _ done: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if done() { return }
            settle(0.5)
        }
    }

    private func openFirstScore() {
        // The quartet, by name and once the seed has filed both samples: it is
        // the score PaginationAfterAnOp's control relies on paginating plain.
        waitForTheSeededPiece(app).tap()
        let quartet = app.descendants(matching: .any)["arrangement-choice-sous-le-ciel-quartet"]
        XCTAssertTrue(quartet.waitForExistence(timeout: 60), "the piece screen offered no quartet")
        settle(quartet)
        quartet.tap()
        XCTAssertTrue(app.buttons["score-title"].waitForExistence(timeout: 120),
                      "the score never opened")
        XCTAssertTrue(engravedPage.waitForExistence(timeout: 180),
                      "no engraved page: the score is not in page layout")
    }

    /// Page -> continuous -> page, photographed at every step.
    func testPaginationSurvivesAVisitToContinuous() {
        app = XCUIApplication()
        app.launchArguments = ["-resetLibrary", "-seedTestLibrary"]
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        _ = app.descendants(matching: .any)["library-search"].waitForExistence(timeout: 240)
        openFirstScore()

        tap("layout-page")
        let first = waitForPages { $0 > 0 }
        snap("01-paged-first-open")
        print("RENDERSHOT: paged on open = \"\(first)\"")

        tap("layout-continuous")
        // the counter goes as soon as the layout does; the STRIP takes as long
        // as an engrave, and the paged canvas stays up until it lands
        waitForPages { $0 == 0 }
        settle(12)
        snap("02-continuous")
        print("RENDERSHOT: continuous counter = \"\(counter)\" (there should be none)")

        tap("layout-page")
        let after = waitForPages { $0 > 1 }
        snap("03-paged-after-continuous")
        print("RENDERSHOT: paged after continuous = \"\(after)\"")

        // The whole bug, in one line.
        XCTAssertGreaterThan(pages(in: after), 1,
                             "a notation score lost its pages on the way back from "
                             + "continuous mode: the counter reads \"\(after)\"")
        XCTAssertEqual(pages(in: after), pages(in: first),
                       "the same music engraved to a different number of pages "
                       + "before (\(first)) and after (\(after)) a visit to continuous")

        // and the strip, which is where the thumbnails come from
        if app.otherElements["thumbnail-strip"].exists {
            snap("04-thumbnail-strip")
        }

        // Bug 4's second half: the shading flipped lighter/darker between one
        // page and two, because the raster cap landed on a different size of
        // the same enormous single "page". Two real pages, photographed.
        if tap("layout-spread", wait: 4) {
            waitForPages { $0 > 1 }
            settle(3)
            snap("05-two-page-spread")
            print("RENDERSHOT: spread counter = \"\(counter)\"")
        }
    }

    /// What the strip looks like with the version band open over it.
    ///
    /// The band takes height off the canvas, and the strip is fitted BY height
    /// -- so opening a dropdown used to re-scale the whole score and redraw
    /// every tile of it, which was 511 ms of a 575 ms tap. The strip keeps its
    /// size now and the shorter canvas shows less of it. That is a judgement a
    /// person has to make by looking, so these are photographs: the strip
    /// before, with the band open, and after it closes, which must match the
    /// first.
    func testTheStripKeepsItsSizeWhenTheVersionBandOpens() {
        app = XCUIApplication()
        app.launchArguments = ["-resetViewPreferences", "-seedTestLibrary"]
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        _ = app.descendants(matching: .any)["library-search"].waitForExistence(timeout: 240)
        openFirstScore()

        tap("layout-continuous")
        settle(12)
        snap("20-strip-band-closed")

        guard app.buttons["score-versions"].waitForExistence(timeout: 10) else {
            return XCTFail("no versions control on the bar")
        }
        app.buttons["score-versions"].tap()
        settle(2)
        snap("21-strip-band-open")

        app.buttons["score-versions"].tap()
        settle(2)
        snap("22-strip-band-closed-again")
    }

    /// Bug 6: the line stands still and the score scrolls past it, a hand on
    /// the score hands following over, and Sync hands it back.
    ///
    /// A sweep with one assertion. What it can prove without ears is that the
    /// strip MOVED under a playhead that stayed put, and that the chip turns up
    /// after a manual scroll -- the rest is in the screenshots.
    func testTheStripScrollsUnderTheLine() {
        app = XCUIApplication()
        app.launchArguments = ["-resetViewPreferences", "-seedTestLibrary"]
        app.launch()
        _ = app.descendants(matching: .any)["library-search"].waitForExistence(timeout: 240)
        XCUIDevice.shared.orientation = .portrait
        openFirstScore()

        tap("layout-continuous")
        waitForPages { $0 == 0 }
        settle(12)
        snap("10-continuous-before-play")

        guard tap("transport-play", wait: 10) else {
            print("RENDERSHOT: no transport-play; nothing to photograph")
            return
        }
        // Building the performance takes a moment on a long score, and how long
        // is not a number to guess. The sound has started when the transport's
        // own bar readout MOVES -- "bar 1" is what it says standing still.
        let standing = transportBar
        waitFor(90) { self.transportBar != standing }
        settle(3)
        snap("11-playing-line-parked")
        let firstBar = app.staticTexts["counter-bar"].exists
            ? app.staticTexts["counter-bar"].label : ""
        settle(6)
        snap("12-playing-later")
        let laterBar = app.staticTexts["counter-bar"].exists
            ? app.staticTexts["counter-bar"].label : ""
        print("RENDERSHOT: bar readout \"\(firstBar)\" then \"\(laterBar)\"")

        // a hand on the score: playback does NOT stop, following does
        app.scrollViews["score-canvas"].firstMatch.swipeLeft()
        app.scrollViews["score-canvas"].firstMatch.swipeLeft()
        let chip = app.buttons["sync-to-playback"]
        waitFor(12) { chip.exists }
        snap("13-after-a-manual-scroll")
        print("RENDERSHOT: sync chip after a manual scroll = \(chip.exists)")
        if chip.exists {
            chip.tap()
            settle(2.5)
            snap("14-after-sync")
        }
        if app.buttons["transport-play"].exists { app.buttons["transport-play"].tap() }
    }
}
