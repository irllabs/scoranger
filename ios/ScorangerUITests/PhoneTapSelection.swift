import XCTest

/// A finger taps a bar, presses to see under itself, and turns a page from a
/// corner -- on the phone, where all three are new.
///
/// design/IPHONE_0.6.14.md §9.1, §9.2, §12. The rules are pure and fuzzed in
/// `CanvasTapTests`; what a unit test cannot say is whether a real finger on a
/// real canvas reaches them -- whether the tap arrives at all, whether the
/// selection lands on the bar under the finger, whether the loupe is drawn
/// where the reader is looking. So this drives the actual gestures and keeps
/// the frames.
final class PhoneTapSelection: XCTestCase {

    private var app: XCUIApplication!

    private func snap(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func openAScore() -> Bool {
        _ = app.descendants(matching: .any)["library-search"].waitForExistence(timeout: 240)
        let row = waitForTheSeededPiece(app, timeout: 180)
        guard row.exists else { return false }
        row.tap()
        openWhicheverArrives(app)
        return app.buttons["score-title"].waitForExistence(timeout: 300)
    }

    /// The engraved page, which is what a SELECTION is aimed at.
    private func canvas() -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "canvas-"))
            .firstMatch
    }

    /// The scroll view, which is what a TURN is measured against.
    ///
    /// The two are not the same rectangle and the difference is the whole of
    /// §12: the turn zones are corners of the CANVAS, and at fit the page does
    /// not reach the canvas's bottom -- on an iPad it stops well above it.
    /// Aiming a corner tap at a fraction of the PAGE therefore lands in the
    /// middle of the canvas on a large screen, which is how this test passed
    /// on an iPhone and failed on the gate's iPad.
    private func surface() -> XCUIElement { app.scrollViews["score-canvas"] }

    private func chip() -> XCUIElement { app.staticTexts["selection-chip"] }
    private func counter() -> XCUIElement { app.staticTexts["counter-pages"] }

    /// ONE launch, every claim: seeding the library is minutes of engine work
    /// and all of these look at the same opened score.
    func testAFingerSelectsInTheMiddleAndTurnsFromACorner() {
        app = XCUIApplication()
        app.launchArguments = ["-resetLibrary", "-seedTestLibrary"]
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        guard openAScore() else { return XCTFail("the score never opened") }
        let page = canvas()
        XCTAssertTrue(page.waitForExistence(timeout: 240), "no engraved canvas")
        settle(page, still: 0.8)
        // The counter reads "p. 1" until the engraving has counted its pages
        // and "p. 1 / 9" after; read before that, the comparison below says
        // the page turned when the engraving only finished.
        expect("the page counter to carry a total", timeout: 120) {
            counter().exists && counter().label.contains("/")
        }

        // 1. A TAP IN THE MIDDLE SELECTS. At fit that means the bar under the
        // finger (§9.1), and the chip naming it is the proof the address
        // resolved -- a highlight alone could be drawn over nothing.
        let before = counter().label
        // dy 0.55 rather than the exact middle: a sweep down this page put a
        // whole-bar REST at 0.45, and a bar holding one rest is a true but
        // uninformative picture of what a bar selection looks like. 0.55 lands
        // on a busy bar, which is what the designer needs to judge the fill.
        page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55)).tap()
        XCTAssertTrue(chip().waitForExistence(timeout: 20),
                      "a tap in the middle of the page selected nothing")
        XCTAssertEqual(counter().label, before,
                       "a tap in the middle turned the page")
        settle(chip(), still: 0.6)

        // 1b. AND THE CHIP FITS. Its longest line -- the hint about holding a
        // finger down -- is wider than a phone, so left to size itself the
        // panel hung off both edges and clipped its own headline, its place
        // line and "Use in chat". Asked in the general form, against the
        // WINDOW: a panel measured against its own ideal width always reports
        // that it fits, which is how the mixer's clipping survived a release.
        assertFitsOnScreen(["selection-chip", "selection-place", "selection-confirm"],
                           in: app, context: "selection chip, iPhone portrait")

        // 1c. AND THE BAR IS STILL A BAR. `ScoreBarLayout` promises the title
        // never falls below `titleMinimum`, and the way that promise broke was
        // the bar measuring ITSELF: an overflowing bar reports its overflow,
        // believes it has the room, and seats another control -- until the
        // title is "S…" and nobody can tell which score they are in.
        //
        // Asserted on the title's drawn width, which is the symptom (#62), not
        // on the fit, which the unit tests already hold.
        let title = app.buttons["score-title"].firstMatch
        XCTAssertGreaterThan(title.frame.width, 60,
                             "the title has collapsed to \(title.frame.width)pt: "
                             + "the bar is seating more than it can draw")
        assertFitsOnScreen(["score-close", "score-select", "score-ask",
                            "score-more"], in: app, context: "score bar")

        // THE FRAME THE DESIGNER ASKED FOR: a bar selected mid-system, at fit,
        // portrait -- to confirm the 12% measure fill against a dense page.
        snap("phone-bar-selected-12pc-fill")

        // 2. A TAP IN A BOTTOM CORNER TURNS. Same finger, same canvas, no
        // mode change -- the region is the whole separator (§12). Forward
        // first: the score opens on page one and there is nothing behind it.
        state(chipGone: true)
        let page1 = counter().label
        surface().coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.95)).tap()
        expect(counter(), toChangeFrom: page1,
               "a tap in the bottom-right corner did not turn forward")
        snap("phone-corner-turned")
        let page2 = counter().label
        surface().coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.95)).tap()
        expect(counter(), toChangeFrom: page2,
               "a tap in the bottom-left corner did not turn back")

        // 3. THE TOP CORNERS ARE MUSIC. They were full-height turn columns
        // until §12; a tap up there must not move the page now.
        state(chipGone: true)
        let stay = counter().label
        surface().coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: 0.12)).tap()
        _ = chip().waitForExistence(timeout: 10)
        XCTAssertEqual(counter().label, stay,
                       "the top-left corner still turns the page")
        snap("phone-top-corner-is-music")
    }

    /// A PRESS -- the gesture the loupe belongs to -- reaches the selection.
    ///
    /// The loupe itself cannot be asserted from here: XCUITest's press blocks
    /// its own thread for the whole gesture and every XCUI call must be on
    /// that thread, so nothing can look at the screen while a finger is down.
    /// Its placement is asserted in `TapSelectionTests` and its drawing is
    /// verified from frames captured outside the process.
    ///
    /// What IS provable here is the rule the loupe made necessary: a finger
    /// held still for seconds still selects. Under the old rule -- a tap is
    /// under 0.3s -- this touch meant nothing at all, so the assertion
    /// discriminates.
    func testAPressSelectsAfterSecondsOfHolding() {
        app = XCUIApplication()
        app.launchArguments = ["-resetLibrary", "-seedTestLibrary"]
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        guard openAScore() else { return XCTFail("the score never opened") }
        let page = canvas()
        XCTAssertTrue(page.waitForExistence(timeout: 240), "no engraved canvas")
        settle(page, still: 0.8)

        let before = counter().label
        page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
            .press(forDuration: 2.5)
        XCTAssertTrue(chip().waitForExistence(timeout: 20),
                      "a finger held still for two and a half seconds selected "
                      + "nothing: the press never reached the selection")
        XCTAssertEqual(counter().label, before, "a press turned the page")
        snap("phone-press-selected")
    }

    // MARK: - waits, never sleeps

    private func expect(_ element: XCUIElement, toChangeFrom old: String,
                        _ message: String, timeout: TimeInterval = 20) {
        let changed = NSPredicate(format: "label != %@", old)
        let done = XCTNSPredicateExpectation(predicate: changed, object: element)
        XCTAssertEqual(XCTWaiter().wait(for: [done], timeout: timeout), .completed,
                       message)
    }

    private func waitFor(_ element: XCUIElement, toExist exists: Bool,
                         timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "exists == %@", NSNumber(value: exists))
        let done = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [done], timeout: timeout) == .completed
    }

    private func state(chipGone: Bool) {
        guard chipGone, chip().exists else { return }
        app.buttons["Clear selection"].firstMatch.tap()
        _ = waitFor(chip(), toExist: false, timeout: 10)
    }
}
