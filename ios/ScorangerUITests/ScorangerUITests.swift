import XCTest

/// iPad audit of the score-first layout. The split view is gone: the canvas is
/// the root, the library and chat are overlays, and every control lives in the
/// pill. These tests are written against that, and against the piece →
/// arrangement → version hierarchy the sidebar presents.
///
/// Fixtures come from engine/scripts/make_test_fixture.py via -seedTestLibrary;
/// -annotateWithFinger lets a finger draw, since the simulator has no Pencil.
final class ScorangerUITests: XCTestCase {
    var app: XCUIApplication!

    private let piece = "Sous le ciel de Paris"
    private let firstArrangement = "sous-le-ciel-quartet"

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // -resetLibrary so each test starts from the same seeded library: these
        // tests rename things, and the on-device workspace outlives the app.
        app.launchArguments = ["-resetLibrary", "-seedTestLibrary",
                               "-annotateWithFinger"]
        // Portrait, every time. The suite's page-geometry assertions are
        // written for it -- in landscape the fit is bound by HEIGHT, so a page
        // is narrower than the canvas and "zooming fills the width" is simply
        // not true. A screenshot harness that rotates the device left the whole
        // suite reading the wrong geometry.
        XCUIDevice.shared.orientation = .portrait
        // and WAIT for it. Assigning orientation is asynchronous: the sweeps
        // leave the device in landscape, and under load this request had not
        // taken effect before the test measured the canvas.
        let upright = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                XCUIDevice.shared.orientation == .portrait
            }, object: nil)
        _ = XCTWaiter().wait(for: [upright], timeout: 10)
        app.launch()
        // A system sheet left standing by a previous test swallows every tap
        // that follows it. Launch clears the app's own state; this clears the
        // one thing it cannot.
        if app.otherElements["ActivityListView"].exists { dismissSystemSheet() }
        // The library IS the app now (§4C): no Home, no tab bar, and the
        // search field is the first thing that exists on it.
        XCTAssertTrue(app.descendants(matching: .any)["library-search"]
                        .waitForExistence(timeout: 90),
                      "the app never showed My Library")
        // ...and then wait for the SEED to finish, which is not the same thing.
        //
        // seedLibraryIfEmpty imports the sample scores and only afterwards
        // assigns them to a set list, while the Pieces band appears as soon as
        // the FIRST import lands. Tests that started there were racing the rest
        // of the fixture: two builds running, a different early-alphabetical
        // test failed each time -- one could not find the arrangement it had
        // just made, the next could not find the set list the seed had not
        // reached yet. Waiting for the arrangement every test goes on to use
        // waits for the imports; nothing here retries an assertion.
        //
        // And waiting for the piece ROW is not enough either. Both samples are
        // filed under the SAME piece, so the row appears when the FIRST import
        // lands and says nothing about the second. `waitForTheSeedToFinish`
        // waits for the count.
        waitForTheSeedToFinish()
    }

    /// How many arrangements the fixture files under the seeded piece: both
    /// `.mxl` files in `testdata/app-samples`.
    private let seededArrangements = 2

    /// Wait for the seed to be FINISHED, not merely started.
    ///
    /// `seedLibraryIfEmpty` guards on `m.scores.isEmpty`, so it runs once and
    /// never resumes: an app terminated between the first import and the second
    /// comes back to a library that is permanently half-seeded, and nothing
    /// will ever add to it. `withPencilStandIn` terminates the app, so a setUp
    /// that returned as soon as the piece row appeared was handing tests a
    /// library with one arrangement in it perhaps one time in three.
    ///
    /// What that did downstream is worth stating, because it does not look like
    /// a seeding fault: a piece holding ONE arrangement opens that arrangement
    /// when its row is tapped, instead of pushing the piece screen. So the
    /// symptom was "the piece screen did not list its arrangements" -- a
    /// navigation failure, in a test about something else entirely.
    private func waitForTheSeedToFinish(_ timeout: TimeInterval = 240) {
        let row = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                        "row-", piece)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: timeout),
                      "the seeded library never finished importing")
        XCTAssertTrue(
            waitForLabel(row, contains: "\(seededArrangements) arrangements",
                         timeout: timeout),
            "the seed stopped at: \(row.label). The piece should hold "
            + "\(seededArrangements) arrangements — both samples in "
            + "testdata/app-samples. seedLibraryIfEmpty does not resume, so if "
            + "the app was terminated part-way this can never come right.")
    }

    /// Relaunch with the Pencil stand-in, so a finger can drive the selection
    /// pipeline.
    ///
    /// Said plainly, because a stand-in is how the FIRST selection scheme
    /// fooled itself into looking tested: this exercises everything downstream
    /// of touch classification — which page the lasso landed on, the unit
    /// points, the hit test, the selection, the chip, the handoff to chat — and
    /// it does NOT exercise Pencil input, which no simulator can produce.
    /// Whether a Pencil reaches the recognizer at all is settled by
    /// `LassoGateTests` and by a person holding an iPad.
    ///
    /// It is per-test, never in `setUp`: with it on, every finger drag on the
    /// canvas is a lasso, which would break the pan and zoom tests.
    private func withPencilStandIn() {
        app.terminate()
        // -resetLibrary is dropped: the library was seeded by the first launch
        // and re-seeding costs another engrave
        app.launchArguments = ["-seedTestLibrary", "-annotateWithFinger",
                               "-uiTestPencil"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["library-search"]
                        .waitForExistence(timeout: 90),
                      "the app never came back after the relaunch")
        // and wait for the LIBRARY, not just the chrome around it. This waited
        // on the search field alone, which exists on the first frame.
        //
        // The relaunch INHERITS the library rather than re-seeding it, so this
        // is a check, not a wait: setUp has already seen the seed finish, and
        // if the count is short here the terminate above cut it off and no
        // amount of waiting will fix it.
        waitForTheSeedToFinish()
    }

    /// Open an arrangement the way a person now does: the library is already
    /// on screen, so this is its row. Browsing and reading are separate places
    /// (§3), but browsing is now the app's only place (§4C).
    private func openArrangement(_ slug: String) {
        // An arrangement is not a top-level row: a PIECE is, and a piece is not
        // openable (§2). Opening one means opening one of its arrangements, so
        // this goes the way a person does -- the piece row, then the choice.
        // (A 5 s probe for a `row-<slug>` button stood here first. No such row
        // exists, so it expired on every call: 53 times, 265 s, per gate.)

        // A piece with several arrangements pushes its screen; the arrangement
        // is chosen there. A piece is not openable -- opening one means opening
        // one of its arrangements.
        let pieceRow = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                        "row-", piece)).firstMatch
        XCTAssertTrue(pieceRow.waitForExistence(timeout: 180),
                      "the library never listed the piece holding \(slug)")
        pieceRow.tap()

        // The tap can land while the library is still settling -- after the
        // pencil stand-in relaunch it reliably does -- and then it opens
        // nothing at all. Whichever lasso test ran FIRST after that relaunch
        // failed here, and the other passed, which is what made it look like a
        // flake rather than a race.
        //
        // The retry that was here was ONE attempt guarded by `isHittable`, and
        // that guard is why it never fired: an import holds the engine, the
        // library stops hit-testing, and `isHittable` is false for exactly as
        // long as the tap is being swallowed. So the retry sat out the whole
        // window it existed for.
        //
        // Three attempts, no hittability guard, and a coordinate tap -- which
        // goes to the row's own frame and does not care, the same reason
        // `tapAnyway` uses one. `pieceRow.exists` still gates it, so once the
        // piece screen IS pushed this stops tapping and only waits. The
        // assertion below is unchanged: the piece screen must still list its
        // arrangements.
        let choice = app.buttons["arrangement-choice-\(slug)"]
        for _ in 0..<3 {
            if choice.waitForExistence(timeout: 20) { break }
            guard pieceRow.exists else { continue }
            pieceRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        XCTAssertTrue(choice.waitForExistence(timeout: 30),
                      "the piece screen did not list its arrangements")
        choice.tap()
    }

    /// The piece screen -- where the arrangement sheet went (§3.1).
    ///
    /// Reached by the piece row's ☰, which is the one visible control a row
    /// carries. No long press: that is the rule this revision adds.
    /// The piece screen. 0.8: the row itself opens it (a piece with several
    /// arrangements pushes its screen); the row's ☰ opens the row's actions.
    private func openPieceSheet() {
        resetToLibraryRoot()
        // The pop is still animating when the library is first there; a tap
        // on the segment then is swallowed, so switch until it has switched.
        let pieces = app.buttons["segment-pieces"]
        if pieces.waitForExistence(timeout: 20) {
            for _ in 0..<4 where !pieces.isSelected {
                settle(pieces, still: 0.5)
                pieces.tap()
                usleep(400_000)
            }
        }
        let row = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@ AND NOT (identifier BEGINSWITH %@) "
                        + "AND label CONTAINS %@", "row-", "row-menu-", piece)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 180), "no row for \(piece)")
        row.tap()
        XCTAssertTrue(app.buttons["piece-new-arrangement-\(pieceSlug)"]
                        .waitForExistence(timeout: 20),
                      "the piece screen did not open")
    }

    /// A row's ☰. Pushes to the item's screen.
    /// Get back to the library's own list, from wherever the test has got to.
    ///
    /// The score covers the library, and the library keeps a navigation stack,
    /// so both have to be unwound or the next tap goes somewhere unintended.
    private func resetToLibraryRoot() {
        if app.buttons["score-close"].exists { app.buttons["score-close"].tap() }
        for _ in 0..<4 {
            guard app.buttons["segment-pieces"].exists == false else { break }
            let back = app.buttons.matching(
                NSPredicate(format: "label BEGINSWITH %@", "Back to")).firstMatch
            guard back.exists, back.isHittable else { break }
            back.tap()
        }
    }

    private func rowMenu(_ id: String) {
        resetToLibraryRoot()
        // pieces and unfiled arrangements live in the Pieces half; a test that
        // was last looking at set lists would otherwise search the wrong list
        if app.buttons["segment-pieces"].exists { app.buttons["segment-pieces"].tap() }
        let row = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                        "row-", id)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 180), "no row for \(id)")
        let menu = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                        "row-menu-", id)).firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 20), "no ☰ on the row for \(id)")
        menu.tap()
    }

    /// The arrangement screen: the per-item actions screen (§3.2).
    /// The arrangement's panel (0.8, A1): the piece screen, the row's ☰, and
    /// the row's Arrangement action, which opens it beside the row.
    private func openArrangementScreen(_ slug: String) {
        openPieceSheet()
        tapAnyway(app.buttons["row-menu-\(slug)"], in: app.scrollViews.firstMatch)
        let manage = app.buttons["arrangement-manage-\(slug)"]
        XCTAssertTrue(manage.waitForExistence(timeout: 20), "the row's ☰ offers no Arrangement")
        manage.tap()
        XCTAssertTrue(app.buttons["arrangement-title"].waitForExistence(timeout: 20),
                      "the arrangement panel did not open")
    }

    /// The seeded piece's slug, for the ids the screens carry.
    private var pieceSlug: String { "sous-le-ciel-de-paris" }

    /// Open the VERSIONS band from the score bar.
    ///
    /// 0.6.3 #8 split the one dropdown in two: the version count opens the
    /// versions, the title block opens the piece's other arrangements. Tests
    /// that switch version go through the version count now — the title no
    /// longer reaches it.
    ///
    /// `score-versions` is optional on a narrow bar (`ScoreBarLayout`), so the
    /// failure message says so rather than reading as a missing element.
    @discardableResult
    private func openVersionsBand() -> XCUIElement {
        let versions = app.buttons["score-versions"]
        XCTAssertTrue(versions.waitForExistence(timeout: 20),
                      "no version count in the score bar. At this width it is "
                      + "the only route to the versions band — the title block "
                      + "opens the arrangements since 0.6.3 #8")
        versions.tap()
        let row = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "menu-version-")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20),
                      "the version count did not open the versions band")
        return versions
    }

    /// Every version row currently in the band, newest first.
    private var versionRows: XCUIElementQuery {
        app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "menu-version-"))
    }

    /// A row of the "…" menu, by identifier rather than by element type.
    private func menuRow(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// Renaming is tapping the name (0.4.2 simplify pass).
    ///
    /// There is no Rename button anywhere: the value IS the control, so this
    /// taps the title, types, and returns. A button whose only job was to make
    /// the thing beside it editable had nothing left to do.
    func testTappingATitleRenamesItInPlace() {
        openArrangementScreen(firstArrangement)
        let title = app.buttons["arrangement-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 20),
                      "the arrangement screen shows no tappable title")
        title.tap()
        let field = app.textFields["arrangement-title-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10),
                      "tapping the title did not turn it into a field")
        replaceText(field, with: "Tapped rename")
        app.typeText("\n")
        XCTAssertTrue(app.buttons["arrangement-title"].waitForExistence(timeout: 30),
                      "the field did not commit back to a title")
        shot("tap-to-rename")
    }

    /// And no Rename button survives anywhere it used to be.
    func testNothingOffersARenameButton() {
        openArrangementScreen(firstArrangement)
        XCTAssertFalse(app.buttons["edit-rename-\(firstArrangement)"].exists,
                       "the arrangement screen still has a Rename row")
        XCTAssertFalse(app.buttons["bar-rename"].exists,
                       "the action bar still has a Rename button")
    }

    /// Leave a pushed screen.
    ///
    /// By label rather than identifier: a nav bar's back button is a stack
    /// inside a Button, and which of the two XCUITest reports as the queryable
    /// element varies with what else is on the screen. The label is set on the
    /// same element either way and says where it goes.
    /// A freshly seeded arrangement may have exactly one version, and a test
    /// about switching between versions needs two. Make the second rather than
    /// hope for it.
    private func ensureASecondVersion() {
        // Read the count BEFORE the menu covers the bar. The version control
        // lives on the top bar and the options screen the transpose runs from
        // sits over it, so the count cannot be watched while the op is in
        // flight -- it is checked on the way back out. This replaced a
        // `sleep(25)`, the most expensive wait in the suite, which was still
        // not always long enough on four simulators at once.
        let versionsBefore = versionCount()
        let engravingBefore = engravingKey()
        app.buttons["score-more"].tap()
        // the … menu is layered: Transpose opens its own layer, and the two
        // semitone rows live in there
        let layer = menuRow("more-transpose")
        guard layer.waitForExistence(timeout: 10) else {
            return XCTFail("the … menu has no Transpose")
        }
        layer.tap()
        let up = menuRow("transpose-up")
        guard up.waitForExistence(timeout: 10) else {
            return XCTFail("Transpose opened but offers no semitone up")
        }
        up.tap()
        // and put the panel away: transposing pops to More's root, which
        // sits beside the score (0.8 §7.2) -- a test that went straight on to
        // draw was drawing with the panel narrowing the page
        let done = app.buttons["panel-done"].firstMatch
        if done.waitForExistence(timeout: 30) { done.tap() }
        if app.buttons["score-more"].exists && app.buttons["score-more"].isSelected {
            app.buttons["score-more"].tap()
        }
        XCTAssertTrue(app.scrollViews["score-canvas"].waitForExistence(timeout: 120),
                      "the canvas never came back after transposing")
        expect("the transposed version to be recorded", timeout: 180) {
            versionCount() > versionsBefore
        }
        // ...and to reach the canvas, which is a second round trip: the score
        // is re-engraved after the op lands, and the OLD engraving stays up
        // until it does.
        waitForEngraving(replacing: engravingBefore)
    }

    /// Close Settings, whichever shape it is: a docked panel from the library
    /// (#51), a pushed screen from the score.
    private func closeSettings() {
        if app.buttons["Close settings"].exists {
            app.buttons["Close settings"].tap()
        } else {
            goBack()
        }
    }

    private func goBack() {
        // 0.8: inside the panel, back is the panel's own ‹, and from its root
        // state Done; on a page it is ‹ and the place it goes.
        let panelBack = app.buttons["panel-back"].firstMatch
        if panelBack.exists && panelBack.isHittable { panelBack.tap(); return }
        let panelDone = app.buttons["panel-done"].firstMatch
        if panelDone.exists && panelDone.isHittable { panelDone.tap(); return }
        let byId = app.buttons["screen-back"].firstMatch
        if byId.exists && byId.isHittable { byId.tap(); return }
        let byLabel = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Back to")).firstMatch
        XCTAssertTrue(byLabel.waitForExistence(timeout: 10),
                      "no way back from this screen")
        byLabel.tap()
    }

    /// Bring an element into view before touching it.
    ///
    /// A pushed screen scrolls, and `exists` is true for something below the
    /// fold -- so a tap can land on nothing while the assertion before it
    /// passes. That is what made the part rows look unreachable.
    /// Tap something that exists, wherever it is.
    ///
    /// `isHittable` is false for anything below the fold, and scrolling does
    /// not always bring a row inside a nested scroll view into reach. A
    /// coordinate tap goes to the element's own frame and does not care.
    /// Drag a row by its ☰ onto another row's place. A press first, long
    /// enough to be a press rather than a flick the page would take, then a
    /// slow drag to the other row's ☰ and a moment held there before the lift.
    private func dragRow(_ slug: String, ontoRowOf target: String) {
        let grip = app.buttons["row-menu-\(slug)"]
        let destination = app.buttons["row-menu-\(target)"]
        XCTAssertTrue(grip.waitForExistence(timeout: 20), "no ☰ on \(slug)")
        XCTAssertTrue(destination.exists, "no ☰ on \(target)")
        grip.press(forDuration: 0.4, thenDragTo: destination,
                   withVelocity: .slow, thenHoldForDuration: 0.3)
    }

    private func tapAnyway(_ element: XCUIElement, in container: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 20),
                      "no element to tap: \(element)")
        if scrollTo(element, in: container) { element.tap(); return }
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    @discardableResult
    private func scrollTo(_ element: XCUIElement, in container: XCUIElement,
                          tries: Int = 6) -> Bool {
        guard element.waitForExistence(timeout: 10) else { return false }
        for _ in 0..<tries {
            if element.isHittable { return true }
            container.swipeUp(velocity: .slow)
        }
        return element.isHittable
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Replace a field's whole contents.
    ///
    /// `typeText` inserts at the cursor and a tap puts the cursor wherever it
    /// landed, so appending is not setting. Command-A never reaches the
    /// simulator, and neither arrow keys nor backspace go through typeText on
    /// this OS — a triple tap selects the whole line the way a finger would,
    /// and typing then replaces the selection.
    private func replaceText(_ field: XCUIElement, with text: String) {
        // Select all, then type over it. A triple tap selects a WORD in a
        // dashed slug, and the new text was appended to the old.
        field.tap()
        field.press(forDuration: 1.2)
        let selectAll = app.menuItems["Select All"]
        if selectAll.waitForExistence(timeout: 3) {
            selectAll.tap()
        } else {
            field.tap(withNumberOfTaps: 3, numberOfTouches: 1)
        }
        field.typeText(text)
    }

    /// Poll a field's value: a write that goes through the engine lands a
    /// moment after the button that started it disappears.
    @discardableResult
    private func waitForValue(_ element: XCUIElement, _ expected: String,
                              timeout: TimeInterval = 30) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (element.value as? String) == expected { return true }
            usleep(200_000)
        }
        return false
    }

    /// Poll an element's label: a reorder round-trips through the engine.
    private func waitForLabel(_ element: XCUIElement, contains text: String,
                              timeout: TimeInterval = 30) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.label.contains(text) { return true }
            usleep(200_000)
        }
        return false
    }

    /// The page the canvas is showing.
    ///
    /// Its identifier is "canvas-<slug>/<version>/pN" and its value is the
    /// stroke count, which makes it the one element a test can read the
    /// engraving's IDENTITY from rather than merely its presence.
    private var engravedPage: XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "canvas-"))
            .firstMatch
    }

    /// Which engraving is on the canvas, or "" when none is.
    private func engravingKey() -> String {
        let page = engravedPage
        return page.exists ? page.identifier : ""
    }

    /// Wait for the ENGRAVING, not for the canvas.
    ///
    /// `score-canvas` appears before anything is on it, the previous pages
    /// deliberately stay up until the new ones land (#44), and the app opens
    /// the most recently touched arrangement by itself at launch -- so the
    /// first canvas to exist can belong to a different arrangement than the
    /// one the test just opened, and a stroke drawn on it lands mid-swap.
    ///
    /// Fifteen places waited twelve seconds for this and hoped. Twelve seconds
    /// is both too long on a machine that is not busy and too short on four
    /// simulators that are.
    @discardableResult
    private func waitForEngraving(of slug: String? = nil,
                                  replacing previous: String? = nil,
                                  timeout: TimeInterval = 180) -> XCUIElement {
        let canvas = app.scrollViews["score-canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: timeout),
                      "the score never finished engraving")
        expect("an engraving on the canvas"
               + (slug.map { " for \($0)" } ?? "")
               + (previous.map { " other than \($0)" } ?? ""), timeout: timeout) {
            let key = engravingKey()
            guard !key.isEmpty else { return false }
            if let slug, !key.hasPrefix("canvas-\(slug)/") { return false }
            if let previous, key == previous { return false }
            return true
        }
        settle(all: [canvas, engravedPage])
        return canvas
    }

    /// "3 versions" in the top bar, as a number. -1 when the bar is covered or
    /// the score is not open.
    private func versionCount() -> Int {
        let control = app.buttons["score-versions"]
        guard control.exists else { return -1 }
        return Int(control.label.split(separator: " ").first ?? "") ?? -1
    }

    private func element(labelStartingWith prefix: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH[c] %@", prefix))
            .firstMatch
    }

    private func waitForDisappearance(of element: XCUIElement,
                                      timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !element.exists { return true }
            usleep(200_000)
        }
        return !element.exists
    }

    /// A row is gone after a DELETE -- waited for on the app's own signal
    /// rather than on the clock.
    ///
    /// `waitForDisappearance(of: row, timeout: 40)` after a delete measures the
    /// MACHINE: the engine call inside that window takes as long as the host
    /// lets it, and 40s was enough solo and not enough under four gate workers.
    /// Re-rolling such a test until it is green keeps the fragility and buys a
    /// pass; sizing the clock up hides it behind a bigger number.
    ///
    /// So wait on what the app SAYS. `AppState.deleteScore` raises
    /// `undoableDelete` only after `local.deleteScore` returned, and that draws
    /// the undo bar. Once it is up, the engine is done and only a local refresh
    /// is left, which is what the short second budget is for. The row already
    /// being gone is the same answer arriving first.
    ///
    /// The long budget is a backstop, not a wait: this returns as soon as
    /// either signal lands, so a fast machine pays nothing for it.
    /// Wait for a delete to LAND, and say which half failed if it does not.
    ///
    /// Two phases, because they fail for different reasons and a single
    /// boolean cannot tell them apart. The first waits for the app's own
    /// signal that the work RETURNED -- the undo bar, or the row simply gone
    /// -- and that signal is on the far side of an engine round trip. The
    /// second gives only the redraw after it a short budget.
    ///
    /// The ceiling is a BACKSTOP against an infinite hang and nothing else.
    /// It is 180, unchanged, which is five times the 25-32 seconds a delete
    /// takes on a quiet machine -- so it is not what makes this pass.
    ///
    /// It was briefly raised to 420 to survive four workers all calling the
    /// embedded engine at once, and that was the wrong fix: it left the
    /// contention in place and bought a pass with a number. The contention is
    /// gone instead -- these tests run outside the parallel pool, one at a
    /// time (`SERIAL` in gate.sh) -- so the original ceiling is ample again.
    ///
    /// It returns a reason rather than a bool so the failure names the phase.
    /// This test has cost two release gates, both times reported as "still in
    /// the library after deleting it" -- which is true of an engine that never
    /// answered and of a list that never redrew, and those are not the same
    /// bug.
    private enum DeleteOutcome: Equatable {
        case landed
        /// The engine never answered: no undo bar, and the row is still there.
        case noSignal(waited: TimeInterval)
        /// It answered, and the list did not redraw.
        case noRedraw
    }

    private func waitForDelete(of row: XCUIElement,
                               signal: TimeInterval = 180,
                               redraw: TimeInterval = 30) -> DeleteOutcome {
        // Both, because which of the two a SwiftUI overlay exposes is not
        // ours to decide: the bar carries the identifier and the Undo inside
        // it is unambiguously a button.
        let undoBar = app.otherElements["undo-bar"]
        let undoButton = app.buttons["undo-delete"]
        let started = Date()
        let deadline = started.addingTimeInterval(signal)
        var sawSignal = false
        while Date() < deadline {
            if !row.exists { return .landed }
            if undoBar.exists || undoButton.exists {
                sawSignal = true
                break
            }
            usleep(200_000)
        }
        guard sawSignal else {
            return .noSignal(waited: Date().timeIntervalSince(started))
        }
        return waitForDisappearance(of: row, timeout: redraw) ? .landed : .noRedraw
    }

    /// Kept under the old name for the other callers, now that the one that
    /// diagnoses uses the outcome.
    private func waitForDeleteToLand(of row: XCUIElement,
                                     signal: TimeInterval = 180,
                                     redraw: TimeInterval = 30) -> Bool {
        waitForDelete(of: row, signal: signal, redraw: redraw) == .landed
    }

    // MARK: - The score view's own chrome (NAVIGATION_SYSTEM.md §4.5)

    /// The pill is gone from the score view. Its duties did not vanish -- they
    /// moved (§8), and this is the list of where to.
    func testTheTopBarCarriesEveryControlAndThereIsNoNavigationBar() {
        openArrangement(firstArrangement)
        XCTAssertTrue(app.buttons["score-close"].waitForExistence(timeout: 180),
                      "no way out of the score")
        XCTAssertTrue(app.buttons["score-ask"].exists, "chat has no button")
        XCTAssertTrue(app.buttons["score-more"].exists, "no … menu")
        XCTAssertTrue(app.buttons["score-edit"].exists, "no Edit")
        // The spread toggle became the three-way layout control (page / spread
        // / continuous). The property is unchanged: how the score is laid out
        // is chosen in the BAR, not buried in Settings.
        XCTAssertTrue(app.buttons["layout-spread"].exists,
                      "the layout control should be in the top bar")
        XCTAssertTrue(app.buttons["layout-page"].exists && app.buttons["layout-continuous"].exists,
                      "all three layouts should be offered")
        XCTAssertFalse(app.buttons["score-spread"].exists,
                       "the old two-state spread button should be gone")
        XCTAssertTrue(app.buttons["score-title"].exists, "no title block to switch from")
        // Perform came UP from Options (0.6.8) and is a labelled button
        // (0.8 [C5]); on a bar too narrow to seat it Options carries it. The
        // transport switch it used to yield with is gone: the tray is always
        // there (§7.7), so the bar has no such control and Options no such row.
        XCTAssertFalse(app.buttons["score-transport-toggle"].exists,
                       "the bar has a transport switch again: the tray is not switchable")
        if !app.buttons["score-performance"].exists {
            app.buttons["score-more"].tap()
            XCTAssertTrue(app.switches["Performance mode"].waitForExistence(timeout: 20),
                          "the bar yielded Perform and Options has not got it")
            XCTAssertFalse(app.switches["Show transport"].exists,
                           "Options carries a Show transport switch for a tray that cannot be hidden")
            goBack()
        }
        XCTAssertFalse(app.buttons["pill-library"].exists,
                       "the pill's library toggle should be gone: browsing is a tab now")
        XCTAssertFalse(app.navigationBars.element.exists,
                       "the score-first layout has no navigation bar")
        shot("score-top-bar")
    }

    /// Performance mode from the TOP BAR, and the way back out (0.6.8).
    ///
    /// It was the top row of the Options screen: two taps and a screen away
    /// from the music, for the one control that changes what every input on
    /// that music means. What this pins is not where the button is but that the
    /// MODE actually takes from there -- the performance bar is a different bar
    /// and its ✕ says so -- because moving a control that does not work in its
    /// new home is how a feature gets dropped.
    ///
    /// On a bar too narrow to seat the switch the Options row is still the way
    /// in, and this walks that route instead; either way the assertion is the
    /// mode, not the control.
    func testPerformanceModeIsEnteredFromTheTopBarAndLeftFromItsOwn() {
        openArrangement(firstArrangement)
        XCTAssertTrue(app.buttons["score-close"].waitForExistence(timeout: 180),
                      "the score never opened")

        let onBar = app.buttons["score-performance"]
        if onBar.exists {
            onBar.tap()
        } else {
            app.buttons["score-more"].tap()
            let row = app.switches["Performance mode"]
            XCTAssertTrue(row.waitForExistence(timeout: 20),
                          "the bar yielded Performance mode and Options has not got "
                          + "it: there is no way into the mode at this width")
            row.tap()
        }

        // The mode, not the button: the bar becomes the performance strip.
        XCTAssertTrue(app.otherElements["performance-bar"].waitForExistence(timeout: 20),
                      "the switch did not put the score into performance mode")
        XCTAssertFalse(app.buttons["layout-page"].exists,
                       "the layout control should be gone in performance mode")
        shot("top-bar-performance-mode")

        // And out again, by the one control that bar has.
        app.buttons["score-close"].tap()
        XCTAssertTrue(waitForDisappearance(of: app.otherElements["performance-bar"],
                                           timeout: 20),
                      "✕ in performance mode did not come back to reading")
        XCTAssertTrue(app.buttons["score-edit"].waitForExistence(timeout: 20),
                      "leaving performance mode did not restore the full bar")
    }

    /// The tray is always there while reading, and Perform is what hides it.
    ///
    /// This was the transport switch's test: the switch put the chrome away
    /// and brought it back. 0.8 has no switch (§7.7); the one thing that
    /// takes the tray off the screen is performance mode, and the one thing
    /// that brings it back is leaving. Both directions, as before.
    func testTheTrayIsAlwaysThereAndPerformHidesIt() {
        openArrangement(firstArrangement)
        XCTAssertTrue(app.buttons["score-close"].waitForExistence(timeout: 180))
        XCTAssertFalse(app.buttons["score-transport-toggle"].exists,
                       "the bar has a transport switch: the tray is not switchable")
        revealTransport()
        let tray = app.otherElements["transport"]
        XCTAssertTrue(tray.exists, "no tray to hide")

        let perform = app.buttons["score-performance"]
        if perform.exists {
            perform.tap()
        } else {
            app.buttons["score-more"].tap()
            let row = app.switches["Performance mode"]
            XCTAssertTrue(row.waitForExistence(timeout: 20),
                          "the bar yielded Perform and Options has not got it")
            row.tap()
        }
        XCTAssertTrue(app.otherElements["performance-bar"].waitForExistence(timeout: 20),
                      "Perform did not put the score into performance mode")
        XCTAssertTrue(waitForDisappearance(of: tray, timeout: 20),
                      "performance mode left the tray on screen")
        app.buttons["score-close"].tap()
        XCTAssertTrue(tray.waitForExistence(timeout: 20),
                      "leaving performance mode did not bring the tray back")
    }

    /// Reading happens over the library, and X ALWAYS lands back on it -- there
    /// is nowhere else to land now that Home is gone (§4C).
    func testTheScoreOpensOverTheLibraryAndClosesBack() {
        openArrangement(firstArrangement)
        XCTAssertTrue(app.buttons["score-close"].waitForExistence(timeout: 180))
        XCTAssertFalse(app.descendants(matching: .any)["library-search"].isHittable,
                       "the score covers the library while you are in it")
        app.buttons["score-close"].tap()
        XCTAssertTrue(app.buttons["segment-pieces"].waitForExistence(timeout: 20)
                        || app.buttons.matching(
                            NSPredicate(format: "label BEGINSWITH %@", "Back to")).count > 0,
                      "closing the score did not go back to the library")
        shot("closed-back-to-library")
    }

    func testTheLibraryHasBothHalves() {
        XCTAssertTrue(app.buttons["segment-pieces"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["segment-setlists"].exists)
        XCTAssertTrue(app.otherElements["alphabet-rail"].exists
                        || app.buttons["library-sort"].exists,
                      "the library has no sort control")
        app.buttons["segment-setlists"].tap()
        XCTAssertTrue(app.buttons["segment-setlists"].isSelected)
        shot("library-setlists")
    }

    /// Home's actions, on the library where they now live (§4C) -- less Ask,
    /// which Ali had removed (#47).
    ///
    /// The row carries two verbs since IPHONE_0.6.14 §14. Import still opens a
    /// band of variants; New does not, and has not since 0.8.2 item 13 -- it
    /// makes the thing the segment is showing, which on Pieces is a piece with
    /// its name waiting to be typed.
    func testTheLibraryCarriesTheMakingActions() {
        XCTAssertTrue(app.buttons["library-import"].waitForExistence(timeout: 30),
                      "the library has no import action")
        XCTAssertTrue(app.buttons["library-new"].exists)
        XCTAssertFalse(app.buttons["library-ask"].exists, "Ask is back")

        app.buttons["library-new"].tap()
        let field = app.textFields["inline-rename-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 20),
                      "New did not raise the naming row")
        XCTAssertEqual(field.placeholderValue, "Piece name",
                       "on Pieces, New makes a piece")
        XCTAssertFalse(app.buttons["library-new-setlist"].exists,
                       "the New band is back")
        shot("library-action-row")
        app.buttons["inline-rename-cancel"].tap()
    }

    /// #48-#50: the library's top row is the gear and nothing else. Help and
    /// the inbox were drawn and inert; the engine chip restated in the corner
    /// of every screen a question that Settings answers properly.
    func testTheLibraryTopRowIsJustTheGear() {
        XCTAssertTrue(app.buttons["library-settings"].waitForExistence(timeout: 30),
                      "the gear went with the rest of the top row")
        XCTAssertFalse(app.buttons["Help"].exists, "the ? is back")
        XCTAssertFalse(app.buttons["Inbox"].exists, "the tray is back")
        XCTAssertFalse(app.descendants(matching: .any)["library-engine-chip"].exists,
                       "the engine chip is back")
    }

    /// Import opens the file picker. Nothing else, and nothing first.
    ///
    /// It used to push a "which piece should this land in?" screen, and that
    /// screen could not deliver: naming a new piece popped the navigation
    /// stack and asked to present the picker in the same tick, so SwiftUI
    /// dropped the presentation mid-transition. You named a piece and the
    /// picker never came. Import was unusable, and no test covered it -- which
    /// is why it could break in silence.
    func testImportGoesStraightToTheFilePicker() {
        XCTAssertTrue(app.buttons["library-import"].waitForExistence(timeout: 30),
                      "no Import button")
        XCTAssertFalse(app.buttons["Cancel"].exists,
                       "something was already presented before Import was tapped")
        // Import is a verb with three kinds under it since §14: the button
        // opens the band, and `Score` in the band is the old Import. The claim
        // this test makes is unchanged -- nothing is asked before the picker.
        app.buttons["library-import"].tap()
        let score = app.buttons["library-import-score"]
        XCTAssertTrue(score.waitForExistence(timeout: 20),
                      "the Import band did not offer Score")
        score.tap()

        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 20),
                      "tapping Import did not open the file picker")
        // and it got there without asking anything first
        XCTAssertFalse(app.textFields["inline-rename-field"].exists,
                       "Import stopped to ask for a name")
        XCTAssertEqual(app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Back to")).count, 0,
                       "Import pushed a screen instead of opening the picker")
        shot("import-picker")
        app.buttons["Cancel"].tap()
    }

    /// #53: which build this is, on the screen the app opens to.
    func testTheLibraryShowsWhichBuildThisIs() {
        let stamp = app.staticTexts["build-stamp"]
        XCTAssertTrue(stamp.waitForExistence(timeout: 30),
                      "no build stamp on the library")
        XCTAssertTrue(stamp.label.contains("b"), "the stamp says \(stamp.label)")
    }

    /// #51: Settings is a panel docked at the trailing edge, with the library
    /// still there behind it -- not a screen that covers everything.
    /// Settings is a PAGE on the table (0.8 §7.17, T1–T10): an index at the
    /// left and one section beside it, reached from the gear, left with
    /// Close settings -- and the library is where it was when it closes.
    func testSettingsOpensAsAPanelBesideTheLibrary() {
        app.buttons["library-settings"].tap()
        let panel = app.descendants(matching: .any)["settings-panel"].firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 20), "Settings did not open")
        XCTAssertTrue(app.buttons["settings-reading"].exists, "no index of sections")
        XCTAssertTrue(app.descendants(matching: .any)["settings-section-title"].exists,
                      "no section beside the index")
        shot("settings-panel")
        app.buttons["Close settings"].tap()
        XCTAssertTrue(waitForDisappearance(of: panel, timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["library-search"].waitForExistence(timeout: 10),
                      "closing Settings did not come back to the library")
    }

    /// The tab bar is gone entirely: one live tab and a disabled placeholder
    /// was not a tab bar (§4C).
    func testThereIsNoTabBar() {
        for id in ["tab-home", "tab-library", "tab-shared"] {
            XCTAssertFalse(app.buttons[id].exists, "\(id) survived the merge")
        }
    }

    /// The `+` offered exactly what the action row now shows permanently, so
    /// it went with Home rather than becoming a second way in (§4C).
    func testTheFABIsGone() {
        XCTAssertFalse(app.buttons["library-add"].exists)
        XCTAssertTrue(app.buttons["library-import"].exists,
                      "Import must be permanently visible now that + is gone")
    }

    /// L12: the empty library is the first screen a new user meets, so it is a
    /// STATE with something to do -- not a sentence in the top-left corner.
    func testAnEmptyLibraryIsAStateWithSomethingToDo() {
        app.terminate()
        app.launchArguments = ["-resetLibrary"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["library-search"]
                        .waitForExistence(timeout: 90))
        let state = app.descendants(matching: .any)["library-empty"]
        XCTAssertTrue(state.waitForExistence(timeout: 30), "no empty state")
        XCTAssertTrue(app.buttons["state-action"].exists,
                      "the empty library offers nothing to do about it")
        // and the count says it in words (L11)
        XCTAssertTrue(app.staticTexts["No pieces yet"].exists,
                      "the empty library still counts in digits")
        shot("empty-library")
    }

    // The engine-chip tests went with the chip (#50). What they were really
    // protecting -- that the mode is printed once, and that it says "remote"
    // in remote mode -- now lives where the chip's job moved to, in Settings,
    // and the sweep checks it there.

    /// The score screen has no library overlay any more.

    func testTheLibraryOverlayIsGoneFromTheScore() {
        openArrangement(firstArrangement)
        XCTAssertTrue(app.buttons["score-close"].waitForExistence(timeout: 180))
        XCTAssertFalse(app.staticTexts["PIECES"].exists,
                       "the score view should not carry a library overlay any more")
        // browsing is a tab now, and it is still one tap away
        XCTAssertTrue(app.buttons["score-close"].exists)
    }

    func testChatOverlayOpensFromAsk() {
        openArrangement(firstArrangement)
        XCTAssertTrue(app.buttons["score-ask"].waitForExistence(timeout: 180))
        app.buttons["score-ask"].tap()
        XCTAssertTrue(app.buttons["Close chat"].waitForExistence(timeout: 10),
                      "the chat overlay did not open")
        // the primer and the input are the panel's own, not a system sheet
        XCTAssertTrue(app.textFields["Arrange…"].exists || app.buttons["Send"].exists,
                      "the chat input is missing")
        shot("chat-overlay")
        app.buttons["Close chat"].tap()
        XCTAssertTrue(waitForDisappearance(of: app.buttons["Close chat"], timeout: 5))
    }

    /// The canvas must fill the gap the panels leave, in every combination.
    /// Build 119 capped the score pane to the spec's 520pt page width, which
    /// left dead bands beside the score and — because the pane is also the
    /// scroll view — put hard limits on how far zoom could pan. Asserted
    /// numerically because eyeballing missed it twice.
    func testCanvasFillsTheGapBesideTheChatPanel() {
        let screen = app.windows.firstMatch.frame.width
        let chat: CGFloat = 380
        // the score view only exists once an arrangement has engraved
        openArrangement(firstArrangement)
        let score = app.scrollViews["score-canvas"]
        XCTAssertTrue(score.waitForExistence(timeout: 180),
                      "the score never finished engraving")

        // the page itself, via the PencilKit canvas that overlays it: the
        // build-120 second defect was the canvas frame being right while the
        // page stayed centred on the region it had *before* a panel opened.
        let page = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "canvas-"))
            .firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 30), "no page found in the canvas")

        func assertPageFillsCanvas(_ what: String) {
            XCTAssertEqual(page.frame.midX, score.frame.midX, accuracy: 6,
                           "page off-centre in the canvas with \(what): page "
                           + "\(page.frame) in canvas \(score.frame)")
            // FITTED, not fit-to-width. The canvas shows one page fitted to
            // the viewport now, so a portrait page on a landscape canvas is
            // HEIGHT-bound and cannot fill the width -- that is what fit-to-page
            // means, and asserting otherwise was asserting the old layout.
            // What must still hold: the page is inside the canvas, and it fills
            // whichever dimension binds.
            let fitsWide = page.frame.width <= score.frame.width - 16
            let fitsTall = page.frame.height <= score.frame.height + 8
            XCTAssertTrue(fitsWide && fitsTall,
                          "page overflows the canvas with \(what): "
                          + "\(page.frame) in \(score.frame)")
            let fillsWidth = abs(page.frame.width - (score.frame.width - 24)) < 12
            // minus the pill's reserve: a height-bound page fills the height
            // that is CLEAR, not the whole canvas. Filling the canvas is what
            // pushed the unit past its own scroll view and scrolled the top of
            // the page away (L21).
            let clear = score.frame.height - 24 - 84
            let fillsHeight = abs(page.frame.height - clear) < 24
            XCTAssertTrue(fillsWidth || fillsHeight,
                          "page fills neither dimension with \(what): "
                          + "\(page.frame) in \(score.frame)")
        }

        func assertWidth(_ expected: CGFloat, _ what: String) {
            // a couple of points of slack for panel borders
            XCTAssertEqual(score.frame.width, expected, accuracy: 4,
                           "canvas width with \(what): expected ~\(expected), "
                           + "got \(score.frame.width) of \(screen) available")
        }

        // The library overlay is gone from the score view (§8), so there is
        // one panel left to make room for and two states to check rather than
        // four. The property being protected is unchanged: whatever gap the
        // chrome leaves, the score fills it.
        // The thumbnail rail (0.8 §7.11) has the left 60pt in paged reading;
        // the canvas has everything the chrome leaves it.
        let rail = app.descendants(matching: .any)["thumbnail-rail"].firstMatch
        let railWidth = rail.exists ? rail.frame.width : 0
        assertWidth(screen - railWidth, "nothing open")
        assertPageFillsCanvas("nothing open")
        shot("width-none-open")

        app.buttons["score-ask"].tap()
        XCTAssertTrue(app.buttons["Close chat"].waitForExistence(timeout: 10))
        settle(all: [app.scrollViews["score-canvas"], engravedPage])
        // The panel's lane is its width and the 10pt gap before it (§3).
        assertWidth(screen - railWidth - chat - 10, "chat open")
        assertPageFillsCanvas("chat open")
        shot("width-chat-only")

        app.buttons["Close chat"].tap()
        settle(all: [app.scrollViews["score-canvas"], engravedPage])
        assertWidth(screen - railWidth, "chat closed again")
        assertPageFillsCanvas("chat closed again")
    }

    /// #60: there is always a way out of the score.
    ///
    /// On a phone the bar had no ✕ at all -- the version count added beside the
    /// title pushed it off, and a phone has no other route back. Present in
    /// 149, gone in 152. This runs at whatever width the destination gives it,
    /// so it guards the phone when pointed at one and the iPad otherwise.
    func testTheWayOutOfTheScoreIsAlwaysOnTheBar() {
        openArrangement(firstArrangement)
        let close = app.buttons["score-close"]
        XCTAssertTrue(close.waitForExistence(timeout: 180),
                      "no ✕ on the score bar: the score is a dead end")
        XCTAssertTrue(close.isHittable,
                      "the ✕ exists but cannot be tapped: \(close.frame) in "
                      + "\(app.windows.firstMatch.frame)")
        // and it actually leaves
        close.tap()
        expect("the score to close", timeout: 30) {
            !app.buttons["score-title"].exists
        }
        // by what is GONE, not by what appears: the library's compact layout
        // has no search field, so asserting one made this fail on the very
        // device the bug was about
        XCTAssertFalse(app.buttons["score-title"].exists, "✕ did not leave the score")
        XCTAssertFalse(app.scrollViews["score-canvas"].exists)
        XCTAssertGreaterThan(
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@", "row-")).count, 0,
            "✕ left the score but landed nowhere")
    }

    /// A PDF arrangement opens, reads, and is honest about what it cannot do.
    ///
    /// This is the Newzik migration's shape: the library arrives as scans, they
    /// open straight away with no service and no wait, and OMR is a later
    /// choice. What a scan must NOT do is offer editing it cannot perform.
    func testAScanArrangementOpensAndSaysWhatItCannotDo() {
        app.terminate()
        app.launchArguments = ["-seedTestLibrary", "-seedScanArrangement"]
        app.launch()
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "row-scanned"))
            .firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 120),
                      "the scan never reached the library")
        row.tap()
        openWhicheverArrives(app, timeout: 20)
        let canvas = app.scrollViews["score-canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 120),
                      "the scan did not open — a PDF needs no engraving, so this "
                      + "should be fast")
        let page = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "canvas-"))
            .firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 30), "no page drawn for the scan")
        shot("scan-arrangement")

        // continuous re-engraves with Verovio, and a scan is never engraved
        XCTAssertFalse(app.buttons["layout-continuous"].isEnabled,
                       "continuous should be unavailable for a scan")
        // the ones that do work still do
        XCTAssertTrue(app.buttons["layout-page"].isEnabled)
        XCTAssertTrue(app.buttons["score-edit"].exists,
                      "Pencil markup is the whole point of bringing scans in early")

        // and the way OUT of being a scan offers ITSELF (0.8.2, SC13). Until
        // this build it was a switch two taps behind `…`, so a scan opened as
        // a PDF and said nothing about what it could become.
        let convert = menuRow("convert-run")
        XCTAssertTrue(convert.waitForExistence(timeout: 20),
                      "the scan did not offer to be converted when it opened")
        XCTAssertTrue(menuRow("convert-read-as-is").exists,
                      "the offer has no second answer")
        // Read as is closes it, and More offers Convert again after.
        menuRow("convert-read-as-is").tap()
        XCTAssertFalse(convert.waitForExistence(timeout: 3),
                       "Read as is left the offer on screen")
        app.buttons["score-more"].tap()
        XCTAssertTrue(menuRow("more-make-editable").waitForExistence(timeout: 10),
                      "a scan should offer to be read into notation")
        goBack()
    }

    /// Continuous mode: one strip, no pages.
    func testContinuousLayoutShowsOneStripAndNoPageCounter() {
        openArrangement(firstArrangement)
        let canvas = app.scrollViews["score-canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 180),
                      "the score never finished engraving")

        // the three-way control replaced the spread button
        XCTAssertFalse(app.buttons["score-spread"].exists,
                       "the old spread toggle should be gone")
        for option in ["page", "spread", "continuous"] {
            XCTAssertTrue(app.buttons["layout-\(option)"].exists,
                          "no \(option) cell in the layout control")
        }
        XCTAssertTrue(app.staticTexts["counter-pages"].exists
                        || app.descendants(matching: .any)["counter-pages"].exists,
                      "paged mode should count pages")

        app.buttons["layout-continuous"].tap()
        XCTAssertTrue(canvas.waitForExistence(timeout: 180),
                      "the continuous engraving never arrived")
        // Continuous has no pages to count, so the page counter GOING is the
        // new engraving landing: the previous layout's pages stay up until it
        // does (#44), counter and all.
        expect("the continuous engraving to replace the paged one", timeout: 180) {
            !app.descendants(matching: .any)["counter-pages"].exists
        }
        settle(canvas)
        // proof for the release notes: the APP's window, not the device
        // display -- simctl's capture composites a stale band when the
        // simulator has been rotated by another harness
        if let png = XCUIScreen.main.screenshot().pngRepresentation as NSData?,
           let dir = ProcessInfo.processInfo.environment["SCORANGER_SHOT_DIR"] {
            png.write(toFile: dir + "/continuous-proof.png", atomically: true)
        }
        let window = app.windows.firstMatch.frame
        XCTAssertEqual(app.buttons["score-title"].frame.minY, 34.5, accuracy: 20,
                       "the one top bar should be at the top of a \(window) window")
        shot("continuous")

        XCTAssertTrue(app.buttons["layout-continuous"].isSelected,
                      "the continuous cell should read as selected")
        XCTAssertFalse(app.descendants(matching: .any)["counter-pages"].exists,
                       "continuous mode has no pages to count")
        // exactly one of everything: a second top bar would mean the score
        // screen is on screen twice
        XCTAssertEqual(app.buttons.matching(identifier: "score-title").count, 1,
                       "the score top bar is drawn more than once")
    }

    /// Performance mode, from wherever this width keeps it.
    ///
    /// It is a bar button now and an Options row only where the bar cannot
    /// seat it -- and it is in exactly ONE of those places at any width, which
    /// is the rule ScoreBarLayout.Fit enforces. So this asks the bar first and
    /// falls back, rather than naming one home and failing on the other.
    private func enterPerformanceMode() {
        let onBar = app.buttons["score-performance"]
        if onBar.waitForExistence(timeout: 10) {
            onBar.tap()
        } else {
            app.buttons["score-more"].tap()
            // a PanelToggle, exposed as a SWITCH (L33): the row around it is a
            // container and tapping that does not flip it
            let toggle = app.switches["Performance mode"]
            XCTAssertTrue(toggle.waitForExistence(timeout: 10),
                          "the bar yielded Performance mode and Options has not got it")
            toggle.tap()
            if app.buttons["score-more"].exists, app.buttons["score-more"].isSelected {
                app.buttons["score-more"].tap()
            }
        }
        XCTAssertTrue(app.otherElements["performance-bar"].waitForExistence(timeout: 10),
                      "performance mode did not start")
    }

    /// Jumping to another version is two taps from the canvas: the version
    /// count, then the version. It was reachable only through the title block
    /// or a pushed screen, and the band showed the last FOUR with the rest
    /// behind an "All N versions" push -- a menu that gave information about
    /// versions without switching to one.
    ///
    /// #62: and it has to be reachable FROM THE SCORE BAR at whatever width
    /// the bar happens to be, or it is dead on that device. It used to tap the
    /// title block, on `ScoreBarLayout`'s stated invariant that "the title
    /// block opens the same dropdown, so versions stay REACHABLE" when the
    /// version count yields. 0.6.3 #8 ended that: the title opens the
    /// ARRANGEMENTS now. So this asks the question the invariant was making a
    /// promise about -- is there ANY route from this bar to the versions --
    /// and takes whichever control offers it. On a bar too narrow to seat the
    /// version count there is currently no answer, and this fails saying
    /// exactly that rather than reporting a missing element.
    ///
    /// Then the same two taps in performance mode, which had no route to
    /// versions at all -- its bar is the way out and the mode, and nothing
    /// else.
    ///
    /// One test, where there were three (with testTheTitleOpensTheVersionsAndJumps
    /// and testVersionsAreReachableInPerformanceMode): on an iPad all three
    /// took the version count and tapped v001, each after its own launch,
    /// engrave and transpose.
    func testTheVersionCountOpensTheVersionsAndJumpsToOne() {
        openArrangement(firstArrangement)
        XCTAssertTrue(app.scrollViews["score-canvas"].waitForExistence(timeout: 180),
                      "the score never finished engraving")
        ensureASecondVersion()

        let versions = app.buttons["score-versions"]
        let title = app.buttons["score-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 20), "no title block")
        // Whichever control this width offers. The version count is the route
        // #8 made; the title block is the route #62 relied on.
        let route: XCUIElement
        if versions.waitForExistence(timeout: 20), versions.isHittable {
            XCTAssertTrue(versions.label.contains("version"),
                          "the trigger should say how many: got \(versions.label)")
            route = versions
        } else {
            XCTAssertTrue(title.isHittable,
                          "the version count has yielded at this width and the "
                          + "title cannot be tapped either: \(title.frame)")
            route = title
        }
        route.tap()

        let first = app.buttons["menu-version-v001"]
        XCTAssertTrue(first.waitForExistence(timeout: 10),
                      "no route from the score bar to the versions at this width. "
                      + "The version count is \(versions.exists ? "present" : "yielded") "
                      + "and the title block opens the arrangements since 0.6.3 #8 -- "
                      + "so version switching is unreachable while reading. "
                      + "ScoreBarLayout still documents the opposite.")
        first.tap()
        // the canvas re-engraves at that version, and the bar says so
        XCTAssertTrue(waitForLabel(title, contains: "v001", timeout: 60),
                      "tapping a version did not jump the canvas to it: \(title.label)")
        shot("version-jumped")

        // PERFORMANCE MODE, and back to a version other than the one showing.
        enterPerformanceMode()
        XCTAssertTrue(versions.waitForExistence(timeout: 20),
                      "performance mode has no way to reach the versions")
        versions.tap()
        let other = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@ AND identifier != %@",
                        "menu-version-", "menu-version-v001")).firstMatch
        XCTAssertTrue(other.waitForExistence(timeout: 10),
                      "the versions did not drop down in performance mode")
        other.tap()
        expect("the version dropdown to close on the switch", timeout: 30) {
            !other.exists
        }
        XCTAssertTrue(app.otherElements["performance-bar"].exists,
                      "switching version dropped out of performance mode")
        shot("version-jumped-performance")
    }

    /// One press, one undo. The ink canvas and the lasso overlay each owned a
    /// two-finger tap -- the canvas recogniser declares
    /// `cancelsTouchesInView = false` so it cannot eat the score's pinch, which
    /// means the same tap reached the overlay too. Both called undo: draw two
    /// circles, tap once, BOTH disappear.
    func testOneUndoTapRemovesExactlyOneStroke() {
        app.terminate()
        app.launchArguments = ["-seedTestLibrary", "-annotateWithFinger"]
        app.launch()
        openArrangement(firstArrangement)
        let score = app.scrollViews["score-canvas"]
        XCTAssertTrue(score.waitForExistence(timeout: 180),
                      "the score never finished engraving")
        let page = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "canvas-"))
            .firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 30), "no page found")

        app.buttons["score-edit"].tap()
        XCTAssertTrue(app.buttons["Draw"].waitForExistence(timeout: 20),
                      "the ink bar did not open")
        // the canvas publishes its own stroke count, so this is the drawing
        // itself and not a screenshot read -- and it is what says a stroke has
        // landed, which is what the two `sleep(1)`s here were guessing at
        func strokes() -> Int {
            Int((page.value as? String ?? "").split(separator: " ").first ?? "") ?? -1
        }
        // two separate strokes, well apart, neither crossing the other
        for (index, ends) in [(CGVector(dx: 0.25, dy: 0.30), CGVector(dx: 0.45, dy: 0.34)),
                              (CGVector(dx: 0.55, dy: 0.55), CGVector(dx: 0.75, dy: 0.60))]
            .enumerated() {
            score.coordinate(withNormalizedOffset: ends.0)
                .press(forDuration: 0.1,
                       thenDragTo: score.coordinate(withNormalizedOffset: ends.1))
            waitUntil("stroke \(index + 1) to land", timeout: 20) {
                strokes() >= index + 1
            }
        }
        XCTAssertEqual(strokes(), 2, "the two strokes did not land; value was "
                       + "\(page.value as? String ?? "nil")")
        shot("undo-two-strokes")

        page.twoFingerTap()
        waitUntil("the undo to remove a stroke", timeout: 20) { strokes() < 2 }
        XCTAssertEqual(strokes(), 1,
                       "one tap should undo one stroke, not two")
        shot("undo-one-left")
    }

    /// #59: typing must not resize the music. SwiftUI's automatic keyboard
    /// avoidance inset the whole score screen, the canvas lost the keyboard's
    /// height and the page re-fitted to what was left, so a full page became a
    /// thumbnail while someone asked a question about it.
    func testTheKeyboardDoesNotShrinkThePage() {
        openArrangement(firstArrangement)
        let score = app.scrollViews["score-canvas"]
        XCTAssertTrue(score.waitForExistence(timeout: 180),
                      "the score never finished engraving")
        let page = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "canvas-"))
            .firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 30), "no page found in the canvas")

        app.buttons["score-ask"].tap()
        XCTAssertTrue(app.buttons["Close chat"].waitForExistence(timeout: 10))
        settle(all: [score, page])
        // the canvas has already given the chat its width; only the keyboard
        // is still to come
        let canvasBefore = score.frame
        let pageBefore = page.frame

        let input = app.descendants(matching: .any)["chat-input"].firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 10), "no chat input")
        input.tap()
        XCTAssertTrue(app.keyboards.element.waitForExistence(timeout: 15),
                      "no keyboard came up, so this proves nothing")
        // the keyboard SLIDES in, and everything below is a geometry: wait for
        // the three frames to stop moving rather than for two seconds
        settle(all: [app.keyboards.element, score, page])
        shot("keyboard-up")

        XCTAssertEqual(score.frame.height, canvasBefore.height, accuracy: 2,
                       "the keyboard took "
                       + "\(canvasBefore.height - score.frame.height)pt off the canvas")
        XCTAssertEqual(page.frame.height, pageBefore.height, accuracy: 2,
                       "the page shrank when the keyboard came up: "
                       + "\(pageBefore) -> \(page.frame)")
        // and the field being typed into is still above the keyboard
        let keyboard = app.keyboards.element.frame
        XCTAssertLessThanOrEqual(input.frame.maxY, keyboard.minY + 1,
                                 "the chat input \(input.frame) is under the "
                                 + "keyboard \(keyboard)")
    }

    /// Zoomed in, the page has to be bigger than the region and pannable to
    /// both of its edges -- the build-120 symptom was hard left/right limits
    /// well inside the screen, because the scroll view itself was only 544pt
    /// wide. XCUITest's pinch under-delivers (a requested 2.5 lands near 1.2),
    /// so the canvas publishes its live zoom scale and the test pinches until
    /// it reads high enough.
    func testTheZoomedPageUsesTheWholeCanvas() {
        openArrangement(firstArrangement)
        let score = app.scrollViews["score-canvas"]
        XCTAssertTrue(score.waitForExistence(timeout: 180),
                      "the score never finished engraving")
        let page = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier ENDSWITH %@", "/p0"))
            .firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 30), "no first page")

        func scale() -> CGFloat {
            CGFloat(Double((score.value as? String)?
                .replacingOccurrences(of: "zoom ", with: "") ?? "0") ?? 0)
        }
        func zoom(toAtLeast target: CGFloat) -> CGFloat {
            // one pinch only multiplies the scale by ~1.15 however large the
            // requested factor, so this walks up to the target
            for _ in 0..<24 where scale() < target {
                score.pinch(withScale: 3.0, velocity: 2.0)
            }
            return scale()
        }

        // a drag rather than swipeLeft/Right: a flick's inertia makes "did we
        // reach the extreme" depend on how many flicks land before the
        // deceleration ends, which is not something to assert on.
        //
        // And no long drag that STARTS at a limit. A swipe that begins with
        // the canvas hard against either horizontal limit is the deliberate
        // second gesture that turns the page (`PagedCanvas.swipeMayTurn`,
        // `Coordinator.atHorizontalLimit`). Reading it as a swipe is correct
        // behaviour that this test does not mean to ask for -- it turned the
        // page seven times and then failed looking for a first page that was
        // no longer on screen.
        //
        // This used to stay out of that by panning ONLY in steps under
        // `TurnTapRecognizer.swipeDistance`: 360 drags, 440 s of the gate's
        // most expensive test, to cross about one canvas width. A long drag is
        // a pan too, as long as it begins away from the limit. So: one short
        // step off the limit, one long drag that stops about 45 pt short of
        // the edge (the edge can rest up to 30 pt inside the canvas, which the
        // assertions allow), then short steps until the page stops moving.
        // The last of those may begin at the limit, and is short, so it pans.
        func drag(_ points: CGFloat) {
            // positive moves the finger RIGHT, which brings the page's left
            // edge in
            let half = points / score.frame.width / 2
            let a = score.coordinate(withNormalizedOffset: CGVector(dx: 0.5 - half, dy: 0.5))
            let b = score.coordinate(withNormalizedOffset: CGVector(dx: 0.5 + half, dy: 0.5))
            // held before the lift, so there is no deceleration to wait out
            a.press(forDuration: 0.05, thenDragTo: b, withVelocity: .slow,
                    thenHoldForDuration: 0.2)
            settle(page, still: 0.3)
        }
        func panToEdge(left: Bool) {
            let sign: CGFloat = left ? 1 : -1
            // Under TurnTapRecognizer.swipeDistance (60), so a step that
            // begins at the limit still pans; and well over the touch slop,
            // which ate most of a 0.05-of-the-canvas step once chat had
            // narrowed the canvas to 380 pt.
            let short: CGFloat = 45
            func remaining() -> CGFloat {
                left ? score.frame.minX - page.frame.minX
                     : page.frame.maxX - score.frame.maxX
            }
            drag(sign * short)
            for _ in 0..<3 {
                let far = remaining() - 45
                guard far > 60 else { break }
                drag(sign * min(far, score.frame.width * 0.8))
            }
            var still = 0
            for _ in 0..<12 where remaining() > 0.5 && still < 2 {
                let before = page.frame
                drag(sign * short)
                still = abs(page.frame.minX - before.minX) < 1 ? still + 1 : 0
            }
        }

        func checkRegion(_ what: String) {
            let z = zoom(toAtLeast: 1.8)
            XCTAssertGreaterThanOrEqual(z, 1.8, "could not zoom in (\(what))")
            XCTAssertTrue(app.buttons["score-close"].exists,
                          "the top bar should survive a zoom (\(what))")
            let canvas = score.frame
            XCTAssertGreaterThan(page.frame.width, canvas.width,
                                 "at \(z)x the page (\(page.frame.width)) is still "
                                 + "narrower than the canvas (\(canvas.width)) (\(what))")
            // pan to the left extreme: the left of the page has to come to rest
            // at the canvas's own left edge, not at some inner limit
            panToEdge(left: true)
            settle(page, still: 0.5)
            XCTAssertEqual(page.frame.minX, canvas.minX, accuracy: 30,
                           "at \(z)x the left of the page stops at "
                           + "\(page.frame.minX), canvas starts at \(canvas.minX) (\(what))")
            shot("zoom-left-edge-\(what)")
            panToEdge(left: false)
            settle(page, still: 0.5)
            XCTAssertEqual(page.frame.maxX, canvas.maxX, accuracy: 30,
                           "at \(z)x the right of the page stops at "
                           + "\(page.frame.maxX), canvas ends at \(canvas.maxX) (\(what))")
            shot("zoom-right-edge-\(what)")
            // back to zoom 1 before the next stage (0.2 lands on the 0.5 floor,
            // from which a couple of pinches climb back)
            score.pinch(withScale: 0.2, velocity: -2.0)
            for _ in 0..<8 where scale() < 1 { score.pinch(withScale: 1.4, velocity: 1.0) }
            settle(page, still: 0.5)
        }

        checkRegion("no-panels")
        app.buttons["score-ask"].tap()
        XCTAssertTrue(app.buttons["Close chat"].waitForExistence(timeout: 10))
        settle(all: [score, page])
        checkRegion("chat-open")
    }

    /// And the region stays usable under zoom: the page can be panned across
    /// the whole gap rather than being clipped to an inner box.
    func testZoomPansAcrossTheWholeCanvas() {
        openArrangement(firstArrangement)
        let score = waitForEngraving(of: firstArrangement)
        // The thumbnail rail (0.8 §7.11) has the left 60pt in paged reading;
        // the canvas has everything else.
        let rail = app.descendants(matching: .any)["thumbnail-rail"].firstMatch
        let full = app.windows.firstMatch.frame.width - (rail.exists ? rail.frame.width : 0)
        XCTAssertEqual(score.frame.width, full, accuracy: 4,
                       "with no panels the canvas should be the whole screen beside the rail")
        for scale in [2.0, 1.5] {
            score.pinch(withScale: scale, velocity: 1.5)
            settle(engravedPage, still: 0.4)
            score.swipeLeft(velocity: .fast)
            score.swipeRight(velocity: .fast)
            XCTAssertEqual(score.frame.width, full, accuracy: 4,
                           "the canvas shrank while zoomed at \(scale)")
            shot("width-zoomed-\(scale)")
        }
        // and zoomed with the chat panel open, which is where the stale
        // centring inset used to strand the page under the panel. The pan
        // itself is checked by eye from the screenshot: XCUITest pinch scales
        // compound unpredictably, so asserting an exact page frame here is
        // flakier than it is useful. The canvas frame is what stays asserted.
        app.buttons["score-ask"].tap()
        XCTAssertTrue(app.buttons["Close chat"].waitForExistence(timeout: 20))
        settle(all: [score, engravedPage])
        score.pinch(withScale: 2.0, velocity: 1.5)
        settle(engravedPage, still: 0.4)
        for _ in 0..<3 { score.swipeRight(velocity: .fast) }
        settle(all: [score, engravedPage], still: 0.4)
        // The panel's lane: 380 and the 10pt gap before it (0.8 §3)
        XCTAssertEqual(score.frame.width, full - 380 - 10, accuracy: 4,
                       "the canvas shrank when the chat panel opened while zoomed")
        shot("width-zoomed-chat-open")
        score.pinch(withScale: 0.3, velocity: -2.0)
    }

    // MARK: - Hierarchy

    /// #N is a position WITHIN a piece, so the numbering is on the piece
    /// screen -- which is where a piece's arrangements live now.
    func testArrangementsAreNumberedWithinPiece() {
        openPieceSheet()
        XCTAssertTrue(element(labelStartingWith: "Arrangement number 1").exists)
        XCTAssertTrue(element(labelStartingWith: "Arrangement number 2").exists)
        shot("numbered-arrangements")
    }

    /// The sidebar's expanding caret is gone: a piece is a place you go to.
    /// What it did -- see this piece's arrangements, and get back -- is the
    /// piece screen and its back button.
    func testAPieceOpensItsOwnScreenAndComesBack() {
        openPieceSheet()
        XCTAssertTrue(app.buttons["arrangement-choice-\(firstArrangement)"].exists,
                      "the piece screen does not list its arrangements")
        XCTAssertFalse(app.buttons["Collapse \(piece)"].exists,
                       "the expanding caret should be gone")
        // The page's own ‹ (the panel at rest beside it has Done, which only
        // closes the panel).
        app.buttons["screen-back"].firstMatch.tap()
        XCTAssertTrue(app.buttons["segment-pieces"].waitForExistence(timeout: 20),
                      "back did not return to the library")
    }

    func testRowTapOpensArrangement() {
        openArrangement(firstArrangement)
        // the pill's version chip tracks whatever is open
        XCTAssertTrue(app.buttons["score-title"].waitForExistence(timeout: 60),
                      "row tap did not open an arrangement")
    }

    /// Versions used to nest under an arrangement row on a caret. They are a
    /// pushed list off the arrangement screen now -- the same history, somewhere
    /// you can name.
    func testVersionsAreAScreenOffTheArrangement() {
        openArrangementScreen(firstArrangement)
        let versions = app.buttons["edit-versions-\(firstArrangement)"]
        XCTAssertTrue(versions.exists, "the arrangement screen has no Versions row")
        versions.tap()
        XCTAssertTrue(app.buttons["version-\(firstArrangement)-v001"]
                        .waitForExistence(timeout: 20),
                      "the versions screen did not list them")
        shot("versions-screen")
        goBack()
    }

    func testPromptGroupStepsExpand() {

        openArrangementScreen(firstArrangement)
        app.buttons["edit-versions-\(firstArrangement)"].tap()
        let stepsToggle = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@",
                                  "steps-toggle-\(firstArrangement)-"))
            .firstMatch
        XCTAssertTrue(stepsToggle.waitForExistence(timeout: 20),
                      "a multi-step prompt group should offer a caret")
        let step = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@",
                                  "step-\(firstArrangement)-"))
            .firstMatch
        XCTAssertFalse(step.exists, "steps hidden until the caret opens")
        stepsToggle.tap()
        XCTAssertTrue(step.waitForExistence(timeout: 10),
                      "the caret did not reveal the intermediate versions")
        shot("prompt-group-steps")
    }

    // MARK: - Panel dialogs (§7.15, §7.16)

    func testArrangementSheetIsAPanelWithRenameAndDeleteLast() {

        openArrangementScreen(firstArrangement)
        app.buttons["row-details-\(firstArrangement)"].tap()
        XCTAssertTrue(app.staticTexts["Arrangement"].waitForExistence(timeout: 10),
                      "the arrangement sheet did not open")
        XCTAssertTrue(app.staticTexts["Scored for"].exists,
                      "the sheet should list what the arrangement is scored for")
        // destructive action sits in the body, last — never in the header
        XCTAssertTrue(app.staticTexts["Careful"].exists)
        XCTAssertTrue(app.buttons["Delete arrangement…"].exists)
        shot("arrangement-sheet")
        goBack()
        XCTAssertTrue(waitForDisappearance(of: app.staticTexts["Scored for"], timeout: 5))
    }

    // Renaming from the sheet -- Save offered once the title differs, gone
    // once written, the row's slug-based identifier surviving -- is every
    // step of testTitleAndCreditsAreEditableAndReachTheNotation below, which
    // goes on to the composer and reads both back out of the notation.

    /// Ali's build-121 report: the title at the top of the score, the title in
    /// the sidebar and the title in the sheet were three different values, and
    /// only one of them could be edited. One title now, and editing it reaches
    /// the notation — which is checked by reading the metadata back out of the
    /// engraved file (the sheet's mismatch note is derived from it), not just
    /// out of the library document.
    func testTitleAndCreditsAreEditableAndReachTheNotation() {

        openArrangement(firstArrangement)
        XCTAssertTrue(app.scrollViews["score-canvas"].waitForExistence(timeout: 180),
                      "the score never finished engraving")
        openArrangementScreen(firstArrangement)
        app.buttons["row-details-\(firstArrangement)"].tap()

        let title = app.textFields["arrangement-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10), "no title field")
        let composer = app.textFields["arrangement-composer"]
        XCTAssertTrue(composer.exists, "composer is metadata too, so it must be editable")
        XCTAssertTrue(app.textFields["arrangement-arranger"].exists, "no arranger field")

        replaceText(title, with: "Quartet Retitled")
        replaceText(composer, with: "Hubert Giraud")
        shot("metadata-editor")

        let save = app.buttons["save-metadata"]
        XCTAssertTrue(save.waitForExistence(timeout: 5), "no way to save the edit")
        save.tap()
        XCTAssertTrue(waitForDisappearance(of: save, timeout: 90),
                      "the metadata edit never completed")

        // the edit is a version, like every other change to the notation --
        // and the row says what happened in the reader's words, not the
        // engine's op name (VersionLabel; Ali marked "v001 bulk-import" and
        // "v002 omr" "Don't!"). "set-metadata" is what it must NOT say.
        XCTAssertTrue(app.staticTexts["title and credits"].waitForExistence(timeout: 10),
                      "editing metadata should append a version, labelled in the reader's words")
        XCTAssertFalse(app.staticTexts["set-metadata"].exists,
                       "a version row must never show the engine's own op name")
        goBack()            // details -> arrangement screen
        goBack()            // arrangement -> the piece it belongs to

        // the row under the piece now carries the same title (its label is
        // built from the numeral, the title and the subtitle, so this is a
        // contains-check)
        let row = app.buttons["arrangement-choice-\(firstArrangement)"]
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        XCTAssertTrue(row.label.contains("Quartet Retitled"),
                      "the sidebar still shows the old title: \(row.label)")

        // and reopening reads the credits back out of the notation
        openArrangementScreen(firstArrangement)
        app.buttons["row-details-\(firstArrangement)"].tap()
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        XCTAssertEqual(app.textFields["arrangement-composer"].value as? String,
                       "Hubert Giraud",
                       "the composer did not survive in the notation")
        XCTAssertEqual(title.value as? String, "Quartet Retitled")
        XCTAssertFalse(app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "still engraves")).firstMatch.exists,
                       "the page and the title should now agree")
        shot("metadata-saved")
        goBack()
    }

    // testTheEngravedTitleFollowsTheArrangementTitle photographed the page
    // before and after a retitle and asserted the values either side: the
    // sheet's fields and the row under the piece. Those are asserted by
    // testTitleAndCreditsAreEditableAndReachTheNotation, which also reads the
    // credits back out of the engraved file and checks the sheet no longer
    // says the page "still engraves" another title.

    /// Part names are the staff labels engraved on every system, so they are
    /// metadata the user can edit too.
    func testPartNamesAreEditableFromTheSheet() {

        openArrangementScreen(firstArrangement)
        app.buttons["row-details-\(firstArrangement)"].tap()
        XCTAssertTrue(app.staticTexts["Scored for"].waitForExistence(timeout: 20))
        let first = app.buttons["part-0"]
        XCTAssertTrue(scrollTo(first, in: app.scrollViews.firstMatch),
                      "part rows should be editable")
        first.tap()
        // tapping the name opens it in place, and Done commits it -- there is
        // no Rename button anywhere in the app any more
        let field = app.textFields["part-name-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "no part name field")
        XCTAssertFalse(app.buttons["Rename"].exists, "nothing offers a Rename button")
        replaceText(field, with: "Violin I")
        field.typeText("\n")
        XCTAssertTrue(app.buttons["part-0"].waitForExistence(timeout: 60))
        XCTAssertTrue(element(labelStartingWith: "Violin I").waitForExistence(timeout: 30),
                      "the part row still shows the old name")
        shot("part-renamed")
        goBack()
    }

    /// Every editable field in the sheet says what it is. A placeholder is not
    /// a label: it vanishes the moment the field has content, which is how Ali
    /// ended up with three unnamed boxes at the top of the sheet.
    func testEveryMetadataFieldIsLabelled() {
        openArrangementScreen(firstArrangement)
        app.buttons["row-details-\(firstArrangement)"].tap()
        XCTAssertTrue(app.staticTexts["Arrangement"].waitForExistence(timeout: 10))
        // Sentence case (0.8, §2 rule 2): the caps silkscreen is retired.
        for label in ["Title", "Composer", "Arranger", "Slug"] {
            XCTAssertTrue(app.staticTexts[label].exists, "no visible \(label) label")
        }
        // and exactly one title field: the old read-only Title row is gone.
        // The label itself now reads "Title", so the check is a COUNT.
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == %@", "Title")).count, 1,
                       "a second, title-ish row is back in the sheet")
        shot("labelled-metadata-fields")
        goBack()
    }

    /// The slug is the arrangement's handle, not a title — but auto-generated
    /// ones are ugly, so it is editable. Renaming it moves the artifacts and
    /// every reference, so the score has to still open and still have its
    /// history afterwards.
    func testSlugIsEditableAndReferencesSurvive() {

        openArrangement(firstArrangement)
        XCTAssertTrue(app.scrollViews["score-canvas"].waitForExistence(timeout: 180),
                      "the score never finished engraving")
        openArrangementScreen(firstArrangement)
        app.buttons["row-details-\(firstArrangement)"].tap()
        let slug = app.textFields["arrangement-slug"]
        XCTAssertTrue(slug.waitForExistence(timeout: 10), "no slug field")
        XCTAssertEqual(slug.value as? String, firstArrangement)
        let versionsBefore = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "v00")).count

        replaceText(slug, with: "Paris Quartet")
        let move = app.buttons["save-slug"]
        XCTAssertTrue(move.waitForExistence(timeout: 5), "no way to apply a new slug")
        move.tap()
        XCTAssertTrue(waitForDisappearance(of: move, timeout: 60), "the move never finished")

        // normalized, not taken literally
        XCTAssertTrue(waitForValue(slug, "paris-quartet"),
                      "slug field shows \(String(describing: slug.value))")
        // The history came with it. Not an equality: this counts v00* labels
        // anywhere on screen, and after the rename the sidebar shows the
        // arrangement's version rows as well as the sheet, so the number can
        // legitimately grow. What must never happen is losing one -- the engine
        // side of that invariant is check_workflows' "version history stays
        // addressable" journey.
        XCTAssertGreaterThanOrEqual(app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "v00")).count, versionsBefore,
                                    "versions were lost in the move")
        shot("slug-renamed")
        goBack()            // details -> arrangement screen
        goBack()            // arrangement -> the piece it belongs to

        // the row is filed under the new slug and still opens its score
        let row = app.buttons["arrangement-choice-paris-quartet"]
        XCTAssertTrue(row.waitForExistence(timeout: 30),
                      "the row under the piece did not follow the slug")
        XCTAssertFalse(app.buttons["arrangement-choice-\(firstArrangement)"].exists,
                       "the old slug is still around")
        row.tap()
        XCTAssertTrue(app.scrollViews["score-canvas"].waitForExistence(timeout: 180),
                      "the score no longer renders after the move")
        shot("slug-renamed-still-renders")
    }
    /// One selection at a time, and it can be cleared: the highlight has to be
    /// something the user chose, never a row the app picked for itself.
    func testSelectionIsSingleAndClearable() {

        openPieceSheet()
        let first = app.buttons["arrangement-choice-\(firstArrangement)"]
        XCTAssertTrue(first.waitForExistence(timeout: 20),
                      "the arrangement is not listed under its piece")
        first.tap()
        XCTAssertTrue(app.scrollViews["score-canvas"].waitForExistence(timeout: 180))
        shot("selection-single")
        // step back out to the list the row is on: the score covers it
        app.buttons["score-close"].tap()
        XCTAssertTrue(first.waitForExistence(timeout: 20), "never came back to the piece")
        // exactly one row is selected at a time
        XCTAssertEqual(app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@ AND selected == true",
                        "arrangement-choice-")).count, 1,
                       "more than one arrangement row is highlighted")
    }

    /// Settings lost its field labels in the design revamp: three unnamed
    /// boxes, one of which is a URL and two of which are secrets.
    func testSettingsFieldsAreLabelled() {
        app.buttons["Settings"].firstMatch.tap()
        XCTAssertTrue(app.buttons["settings-engine"].waitForExistence(timeout: 10),
                      "settings did not open")
        // The split shows one section at a time (0.8 §7.17): the key lives
        // in Engine, the service in Scanning.
        app.buttons["settings-engine"].tap()
        XCTAssertTrue(app.staticTexts["OpenRouter API key"].waitForExistence(timeout: 5),
                      "no visible OpenRouter API key label")
        app.buttons["settings-scanning"].tap()
        for label in ["OMR service URL", "OMR service API key"] {
            XCTAssertTrue(app.staticTexts[label].waitForExistence(timeout: 5), "no visible \(label) label")
        }
        app.buttons["settings-engine"].tap()
        // and the key fields say which key is actually in use, rather than
        // showing an empty box that means two different things
        // CONTAINS[c], not CONTAINS. The third branch of keyStatus reads "No
        // key: this build has none built in", with a capital N, so a
        // case-sensitive "no key" could never match it -- and that branch is
        // only reached by a build with no baked key, which is why the hole sat
        // here unseen until one was built in a worktree without a .env.
        XCTAssertTrue(app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] %@", "built into this build")).count > 0
            || app.staticTexts.containing(
                NSPredicate(format: "label CONTAINS[c] %@", "saved key")).count > 0
            || app.staticTexts.containing(
                NSPredicate(format: "label CONTAINS[c] %@", "no key")).count > 0,
            "the key fields do not say which key is in use")
        shot("settings-labelled")
        closeSettings()
    }

    // MARK: - Order (build 125)

    /// Reordering has to move the numbers with the rows: #N is what Ali types
    /// in chat ("take the violin part from #2"), so a badge that disagrees with
    /// the order is worse than no badge.
    /// #N is a POSITION within a piece, so changing the order changes the
    /// numbers. It was Move up / Move down among the row's actions; the ☰
    /// itself is the handle now, pressed and dragged (Ali, on build 214:
    /// "touch and drag up/down on the hamburger").
    func testReorderingArrangementsRenumbersThem() {
        openPieceSheet()
        let first = app.buttons["arrangement-choice-\(firstArrangement)"]
        XCTAssertTrue(first.waitForExistence(timeout: 20))
        XCTAssertTrue(first.label.contains("Arrangement number 1"),
                      "expected the quartet at #1: \(first.label)")
        let second = app.buttons["arrangement-choice-under-paris-skies-accordion-solo"]
        XCTAssertTrue(second.exists, "the seed should file two arrangements")
        XCTAssertTrue(second.label.contains("Arrangement number 2"), second.label)

        dragRow("under-paris-skies-accordion-solo", ontoRowOf: firstArrangement)

        // the numbers swapped, and they followed the rows rather than the slugs
        XCTAssertTrue(waitForLabel(second, contains: "Arrangement number 1"),
                      "the moved arrangement kept its old number: \(second.label)")
        XCTAssertTrue(first.label.contains("Arrangement number 2"),
                      "the displaced arrangement was not renumbered: \(first.label)")
        shot("reordered")
    }
    /// And chat is told the new order: the refs it is handed are built from the
    /// same list the badges are.
    func testChatContextFollowsTheNewOrder() {
        openPieceSheet()
        let second = app.buttons["arrangement-choice-under-paris-skies-accordion-solo"]
        XCTAssertTrue(second.waitForExistence(timeout: 20))
        dragRow("under-paris-skies-accordion-solo", ontoRowOf: firstArrangement)
        XCTAssertTrue(waitForLabel(second, contains: "Arrangement number 1"))

        // open the moved arrangement: the pill numeral is the same number the
        // chat context hands the model. A drag opens no actions, so the row
        // opens on a plain tap.
        second.tap()
        XCTAssertTrue(app.scrollViews["score-canvas"].waitForExistence(timeout: 180))
        app.buttons["score-ask"].tap()
        XCTAssertTrue(app.buttons["Close chat"].waitForExistence(timeout: 10))
        let numeral = element(labelStartingWith: "Arrangement number 1")
        XCTAssertTrue(numeral.exists, "the pill should show the new number")
        shot("reordered-chat")
    }

    // MARK: - Selection (build 124)

    // MARK: - Nudging and resizing a chord symbol

    /// The chip's position-and-size row (docs/size-and-position-spec.md).
    ///
    /// Seeded with a chord chart because neither sample score carries chord
    /// symbols, and the row only appears when everything selected is
    /// adjustable — which today means chord symbols.
    private func openScoreWithChords() {
        app.terminate()
        app.launchArguments = ["-resetLibrary", "-seedTestLibrary",
                               "-annotateWithFinger", "-uiTestPencil",
                               "-seedChordChart"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["library-search"]
                        .waitForExistence(timeout: 90))
        openArrangement(firstArrangement)
        waitForEngraving(of: firstArrangement)
    }

    // NOT covered end to end: selecting a chord symbol with the Pencil and
    // driving the chip's row. Three attempts at it were deleted rather than
    // left flaky -- a lasso has to land on a small target whose position
    // depends on the engraving, and a sweep from 6% to 46% of the page caught
    // notes and rests but never an all-chord-symbol selection. What IS covered:
    // the row's whole behaviour in ChordAdjustSessionTests (28 cases: the step,
    // the clamps, the ladder, pending, revert, reset, what commits), the
    // fixture above, the Chord symbols screen below, and the engine journey in
    // check_adjust_journey.py. The gap is the gesture, and it is recorded in
    // BACKLOG.md rather than papered over.

    /// The part-wide half: a default every symbol inherits, reachable in one
    /// hop, and settable by pressing the size you want.
    ///
    /// It asserted "Reset all adjustments" until 0.6.3 #7 removed it — a
    /// destructive part-wide op on a screen whose other control is a size
    /// stepper. Per-element reset is untouched and lives on the element's own
    /// adjust bar; `ChordAdjustSessionTests` covers it. So the removal is
    /// asserted here rather than dropped, or the row can quietly come back.
    ///
    /// The screen also came UP a level in the same pass: it was … → Score
    /// display → Chord symbols, and "Score display" is gone (#6).
    func testTheChordSymbolsScreenCarriesTheDefaultAndTheLadder() {
        openScoreWithChords()
        app.buttons["score-more"].tap()
        let chords = menuRow("more-chords")
        XCTAssertTrue(chords.waitForExistence(timeout: 20),
                      "no Chord symbols row on the … menu — with Score display "
                      + "gone this is the only route to it")
        chords.tap()

        let size = app.staticTexts["chords-size"]
        XCTAssertTrue(size.waitForExistence(timeout: 10),
                      "no default size on the Chord symbols screen")
        XCTAssertTrue(app.buttons["chords-bigger"].exists)
        XCTAssertTrue(app.buttons["chords-smaller"].exists)
        // WHICH part it lands on: a part-wide op that names no part is
        // indistinguishable from one that never ran.
        XCTAssertTrue(app.descendants(matching: .any)["chords-part"].firstMatch.exists,
                      "the screen does not say which part the default applies to")

        // The ladder is the thing #7 actually fixed: the number between the
        // two glyphs was the obvious thing to press and was not a button, so
        // the control was reported as controlling nothing. Every rung is a
        // button now — press one that is NOT the current value and the default
        // has to follow it.
        let current = size.label
        let rungs = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "chords-size-"))
        XCTAssertGreaterThan(rungs.count, 1,
                             "the size ladder is not on the screen")
        var pressed: String?
        for index in 0..<rungs.count {
            let rung = rungs.element(boundBy: index)
            let points = rung.identifier
                .replacingOccurrences(of: "chords-size-", with: "")
            guard "\(points) pt" != current else { continue }
            guard rung.isHittable else { continue }
            rung.tap()
            pressed = points
            break
        }
        guard let pressed else {
            return XCTFail("no rung of the ladder could be tapped — the ladder is "
                           + "back to being a picture of a control")
        }
        XCTAssertTrue(waitForLabel(size, contains: "\(pressed) pt", timeout: 20),
                      "tapping \(pressed) on the ladder did not set the default: "
                      + "it still reads \(size.label)")

        // #7 removed reset-all from here. It must not reappear.
        XCTAssertFalse(app.descendants(matching: .any)["chords-reset-all"]
                        .firstMatch.exists,
                       "Reset all adjustments is back on the Chord symbols screen")
        shot("chords-screen")
    }

    // MARK: - Where am I in the score

    /// The bar readout followed the PAGE, not the viewport: zoomed into bar 30
    /// it still said bar 1, because it took every measure on the visible page.
    /// It reads the visible rect now.
    ///
    /// It also only appears while the transport is RUNNING (0.6.6) -- reading
    /// a score it repeated a number the engraving already prints above every
    /// system. So this starts playback first, and the two halves of that rule
    /// are both asserted here: nothing in the corner while merely reading, and
    /// the viewport-following readout once the music is moving. The geometry
    /// claim is untouched; only the moment it is made has changed.
    func testTheBarCounterFollowsTheViewportNotThePage() {
        openArrangement(firstArrangement)
        let canvas = waitForEngraving(of: firstArrangement)

        revealTransport()
        // The reading view, whole, for the owner to compare against
        // design/screenshots/transport-paged.png -- the picture he marked. The
        // three marks on it are all in this frame: no bar chip in the corner,
        // no voice dropdown on the transport, and a hairline cursor with its
        // handle at the top of the first system.
        settle(engravedPage, still: 0.5, timeout: 20)
        shot("canvas-transport-after-reading")

        let counter = app.staticTexts["counter-bar"]
        XCTAssertFalse(counter.exists,
                       "the bar chip is on screen over a score nobody is playing: "
                       + counter.label)
        // The page counter beside it is a DIFFERENT thing and is not playback's
        // business -- it says where in the document the reader is, which
        // nothing on the page says.
        XCTAssertTrue(app.staticTexts["counter-pages"].waitForExistence(timeout: 30),
                      "the page counter went with the bar chip")

        startPlaying()
        XCTAssertTrue(counter.waitForExistence(timeout: 30),
                      "no bar counter in the top bar while playing")

        // Hand page-following to the reader before measuring anything. While
        // the app is doing the paging, the music turns pages on its own -- and
        // then the counter would climb whether it read the viewport or the
        // page, which is exactly the difference this test exists to tell. A
        // thumbnail tap is a page turned BY THE READER and stops the app
        // turning any more of them.
        let firstThumb = app.descendants(matching: .any)["thumb-0"].firstMatch
        if firstThumb.waitForExistence(timeout: 10) { firstThumb.tap() }
        settle(engravedPage, still: 0.5)
        let pageAtFit = app.staticTexts["counter-pages"].label

        let atFit = counter.label
        XCTAssertTrue(atFit.hasPrefix("bar "), "the counter should name a bar: \(atFit)")
        let firstBar = Int(atFit.replacingOccurrences(of: "bar ", with: "")) ?? -1
        XCTAssertGreaterThan(firstBar, 0, "a bar number should be positive: \(atFit)")
        shot("bar-counter-at-fit")

        // Zoom in HARD, then pan toward the end of the page. One pinch of 3x
        // only reached 1.17x -- measured -- which left 83% of the page on
        // screen and bar 1 always in it, so the assertion below could not fail
        // for the right reason either.
        for _ in 0..<3 {
            canvas.pinch(withScale: 4.0, velocity: 3.0)
            settle(engravedPage, still: 0.4)
        }
        for _ in 0..<3 {
            canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.55))
                .press(forDuration: 0.05,
                       thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.5)))
            settle(engravedPage, still: 0.4)
        }
        // the counter reads the VISIBLE rect, so it settles with the page
        settle(engravedPage, still: 0.6)

        let after = app.staticTexts["counter-bar"]
        XCTAssertTrue(after.exists, "the counter disappeared once zoomed")
        // Same page as before: a bar that changed because the PAGE changed
        // would say nothing about the viewport, and the counter this replaced
        // would have moved too.
        XCTAssertEqual(app.staticTexts["counter-pages"].label, pageAtFit,
                       "the page turned under the test, so the bar reading "
                       + "proves nothing about the viewport")
        let laterBar = Int(after.label.replacingOccurrences(of: "bar ", with: "")) ?? -1
        // STRICTLY greater: the page-based counter this replaced would report
        // the same bar no matter where the reader panned, so an >= assertion
        // would pass against the bug it exists to catch.
        XCTAssertGreaterThan(laterBar, firstBar,
            "the counter did not follow the viewport: \(atFit) -> \(after.label) "
            + "pages=\(app.staticTexts["counter-pages"].label)")
        shot("bar-counter-zoomed")
    }

    // MARK: - Share & export

    /// The `Share & export` row used to push to a section with no `case`, so it
    /// landed on a note saying exporting happens in the engine -- which is not
    /// somewhere an iPad user can go. It offers the three formats now.
    func testShareAndExportOffersTheThreeFormats() {
        openArrangement(firstArrangement)
        XCTAssertTrue(app.scrollViews["score-canvas"].waitForExistence(timeout: 180),
                      "the score never engraved")
        app.buttons["score-more"].tap()
        let row = menuRow("more-export")
        XCTAssertTrue(row.waitForExistence(timeout: 20), "no Export row")
        row.tap()
        for format in ["musicxml", "midi", "pdf"] {
            XCTAssertTrue(menuRow("export-\(format)").waitForExistence(timeout: 10),
                          "no \(format) row on the export screen")
        }
        shot("share-and-export")
    }

    /// Tapping a format writes a real file and hands it to Apple's share sheet
    /// -- the one modal in the app, and the system's rather than ours.
    func testExportingMusicXMLRaisesTheSystemShareSheet() {
        openArrangement(firstArrangement)
        XCTAssertTrue(app.scrollViews["score-canvas"].waitForExistence(timeout: 180),
                      "the score never engraved")
        app.buttons["score-more"].tap()
        menuRow("more-export").tap()
        let musicxml = menuRow("export-musicxml")
        XCTAssertTrue(musicxml.waitForExistence(timeout: 20))
        musicxml.tap()

        // the share sheet is the system's, so it is identified by what it
        // always carries rather than by an identifier of ours
        let sheet = app.otherElements["ActivityListView"]
        let copy = app.buttons["Copy"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 60) || copy.waitForExistence(timeout: 60),
                      "exporting produced no share sheet")
        shot("share-sheet")
        // and PUT IT AWAY. This is the system's sheet, the one modal the app
        // is allowed, and it was left standing: whichever test ran next then
        // tapped into it instead of the app and failed somewhere unrelated --
        // twice in one evening, in two different tests, at the same assertion.
        dismissSystemSheet()
    }

    /// Close the share sheet, however this iOS names its way out.
    private func dismissSystemSheet() {
        // The share sheet's own button, not the panel's Done behind it.
        for label in ["Close", "Cancel", "Done"] {
            let button = app.buttons.matching(NSPredicate(
                format: "label == %@ AND identifier != %@", label, "panel-done")).firstMatch
            guard button.exists else { continue }
            button.tap()
            if waitForDisappearance(of: app.otherElements["ActivityListView"], timeout: 5) {
                return
            }
        }
        // no button: tap the ground above it, which is how a sheet is dismissed
        if app.otherElements["ActivityListView"].exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.04)).tap()
        }
    }

    /// The title band is ONE surface with two controls in front of it, and
    /// each opens its own column (0.6.3 #8).
    ///
    /// It used to be one dropdown showing both columns at once, so "N
    /// versions" put a list of other pieces on screen beside the thing that
    /// was asked for. The split is only worth having if each control shows its
    /// own list and NOT the other one, so that is what this asserts — in both
    /// directions, and including that switching between them does not need the
    /// band closed first.
    func testTheTitleBandOpensFromTheScoreTitle() {
        openArrangement(firstArrangement)
        XCTAssertTrue(app.scrollViews["score-canvas"].waitForExistence(timeout: 180),
                      "the score never engraved")
        let title = app.buttons["score-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 20), "no title in the score bar")

        // The title block: the piece's other ARRANGEMENTS.
        title.tap()
        XCTAssertTrue(title.isSelected, "the title does not show that it is open")
        // by their rows: an identifier on the band itself would be inherited by
        // the column and swallow every row in it
        let arrangements = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "menu-arrangement-"))
        XCTAssertTrue(arrangements.firstMatch.waitForExistence(timeout: 20),
                      "the title did not open the arrangements")
        XCTAssertEqual(versionRows.count, 0,
                       "the arrangements column is showing versions beside them — "
                       + "the two columns are back")
        shot("title-band-arrangements")

        // The version count: this arrangement's VERSIONS, and it swaps the
        // band over rather than needing it closed first.
        let versions = app.buttons["score-versions"]
        XCTAssertTrue(versions.waitForExistence(timeout: 20),
                      "no version count in the score bar")
        versions.tap()
        XCTAssertTrue(versionRows.firstMatch.waitForExistence(timeout: 20),
                      "the version count did not open the versions")
        XCTAssertTrue(waitForDisappearance(of: arrangements.firstMatch, timeout: 10),
                      "the versions column is showing arrangements beside them — "
                      + "which is the bug #8 fixed")
        XCTAssertTrue(versions.isSelected,
                      "the version count does not show that it is open")
        XCTAssertFalse(title.isSelected,
                       "the title still reads as open while the band shows versions")
        shot("title-band-versions")

        // and it closes from the control that opened it
        versions.tap()
        XCTAssertTrue(waitForDisappearance(of: versionRows.firstMatch, timeout: 10),
                      "the band did not close again")
    }

    /// The old yellow-band highlight is gone, replaced by a real selection.
    func testTheOldHighlightFeatureIsGone() {
        openArrangement(firstArrangement)
        XCTAssertTrue(app.scrollViews["score-canvas"].waitForExistence(timeout: 180))
        let more = app.buttons["score-more"]
        XCTAssertTrue(more.isHittable, "the … button is not tappable")
        // Read BEFORE the screen covers the bar: which of the two places holds
        // Performance mode is decided by what the bar could seat.
        let performanceOnBar = app.buttons["score-performance"].exists
        more.tap()
        XCTAssertTrue(more.isSelected, "the … button did not take: the action never ran")
        XCTAssertFalse(app.buttons["Highlight a passage for chat"].exists,
                       "the bar-estimate highlight toggle is still in the options menu")
        // Performance mode moved to the top bar (0.6.8), so it is no longer
        // what proves this screen opened -- Chord symbols is, being the first
        // row of the options root at every width. Where the bar has yielded the
        // switch, Options still carries it and it is still the app's own
        // PanelToggle rather than a stock iOS Toggle or a bare label (L33), so
        // it is exposed as a SWITCH.
        let chords = app.descendants(matching: .any)["more-chords"].firstMatch
        XCTAssertTrue(chords.waitForExistence(timeout: 5),
                      "the … menu did not open (no Chord symbols row)")
        let performance = app.descendants(matching: .any)["more-performance"].firstMatch
        if performanceOnBar {
            XCTAssertFalse(performance.exists,
                           "Performance mode is on the bar AND in Options: one "
                           + "control, two places, and they will drift")
        } else {
            XCTAssertTrue(performance.exists,
                          "the bar yielded Performance mode and Options has not got it")
            XCTAssertTrue(app.switches["Performance mode"].exists,
                          "Performance mode is not a switch to a screen reader")
        }
        // by identifier rather than by type: a menu row is a stack inside a
        // Button, which XCUITest reports as a container rather than a button --
        // the same reason the canvas is looked up this way
        // "Make editable" is for scans. Notation already is, so a row offering
        // to make it so would be a row that does nothing.
        XCTAssertFalse(app.descendants(matching: .any)["more-make-editable"].exists,
                       "notation should not be offered OMR")
        let annotations = menuRow("more-annotations")
        XCTAssertTrue(annotations.waitForExistence(timeout: 5),
                      "the … menu opened but Annotations is unreachable")
        annotations.tap()
        XCTAssertTrue(menuRow("annotations-clear").waitForExistence(timeout: 5),
                      "clearing markup lost its home")
        // the options are SCREENS now, so a sub-screen is left by the same
        // "Back to …" button every other screen uses
        goBack()
    }

    /// Draw across a bar: the elements under the stroke are
    /// selected, the chip says what was caught, chat opens by itself, and the
    /// reference lands in the input ready to be typed against.
    func testLassoSelectsElementsAndHandsThemToChat() {
        withPencilStandIn()
        openArrangement(firstArrangement)
        // The canvas existing is not the same as *this* score being on it: the
        // app opens the most recently touched arrangement at launch, so the
        // first canvas to appear can belong to the other one and the stroke
        // would land mid-swap. Wait for the engrave this test asked for --
        // BY NAME, which is what the page's identifier carries.
        let canvas = waitForEngraving(of: firstArrangement)

        // A stroke through a system. Which y holds notes depends on where the
        // page sits, so try a few bands rather than pinning one magic number —
        // what is being tested is that a lasso selects and reaches chat.
        // the chip is now named by its headline ("3 elements from bar 15"),
        // so it is found by identifier rather than by a fixed word
        let chip = app.staticTexts["selection-chip"]
        var caught = false
        for y in [0.30, 0.20, 0.42, 0.55] where !caught {
            let start = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.30, dy: y))
            let end = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.62, dy: y))
            // hold past the threshold, then drag: the gesture a person makes
            start.press(forDuration: 0.6, thenDragTo: end)
            caught = chip.waitForExistence(timeout: 8)
        }
        XCTAssertTrue(caught, "nothing was selected by any stroke across the page")
        shot("selection-made")

        // Nothing may have reached chat yet: a lasso is not a request to type.
        XCTAssertFalse(app.buttons["Close chat"].exists,
                       "a lasso opened chat by itself; it must wait to be confirmed")

        // the chip says what was caught, in the user's terms
        let headline = chip.label
        XCTAssertTrue(headline.contains("element") && headline.contains("bar"),
                      "the chip should say how many elements and which bar: \(headline)")
        // The Replace/Add/Subtract modes are gone: adding is a held finger
        // now, and the modes were a trap (Subtract emptied the selection,
        // which hid the chip, which was the only way out of Subtract).
        for mode in ["combine-replace", "combine-add", "combine-subtract"] {
            XCTAssertFalse(app.buttons[mode].exists, "\(mode) is still on the chip")
        }

        // Staff and voice, which were in every address and never shown.
        //
        // Staff is always there. Voice is not asserted here, and deliberately:
        // layer 0 is the parser's "not layer-specific" marker, and elements
        // that live under the <measure> rather than inside a <layer> -- chord
        // symbols, dynamics -- legitimately have no voice. A lasso can catch
        // only those, and did on this arrangement. That the voice is FORMATTED
        // correctly when there is one is settled by SelectionCombineTests,
        // which can state the addresses exactly instead of hoping a stroke
        // catches the right kind of thing.
        XCTAssertTrue(app.staticTexts["selection-place"].exists,
                      "the chip should say where the selection is")
        let place = app.staticTexts["selection-place"].label
        XCTAssertTrue(place.contains("staff") || place.contains("staves"),
                      "no staff in the chip: \(place)")
        if place.contains("voice") {
            // "staves 3, 4 · voice 1" -- the plural does not contain "staff"
            XCTAssertTrue((place.contains("staff") || place.contains("staves"))
                            && place.contains("·"),
                          "the place line is malformed: \(place)")
        }
        shot("selection-chip-redesigned")

        // hand it over deliberately
        let confirm = app.buttons["selection-confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "no Use in chat button")
        confirm.tap()

        XCTAssertTrue(app.buttons["Close chat"].waitForExistence(timeout: 20),
                      "confirming the selection should open chat")
        let input = app.textFields["chat-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 10), "no chat input")
        let value = (input.value as? String) ?? ""
        XCTAssertTrue(value.contains("[selection:"),
                      "the selection reference did not reach the chat input: \(value)")
        XCTAssertTrue(value.contains("bar"), "the reference should name bars: \(value)")
        shot("selection-in-chat")
    }
    /// Ali turns edit mode off from the PILL, and the ink bar stayed on screen.
    /// The existing test switches it off with the bar's own "Finish annotating"
    /// button, which is a different path -- and the bar's visibility is decided
    /// by a view that reads the annotation controller without observing it, so
    /// it only updated when something else happened to redraw the score pane.
    func testTheInkBarFollowsThePillToggleBothWays() {
        openArrangement(firstArrangement)
        let markup = app.buttons["score-edit"]
        XCTAssertTrue(markup.waitForExistence(timeout: 60))
        XCTAssertFalse(app.buttons["Draw"].exists, "the ink bar should start hidden")

        markup.tap()
        XCTAssertTrue(app.buttons["Draw"].waitForExistence(timeout: 10),
                      "the ink bar did not appear when edit mode was turned on")

        markup.tap()
        XCTAssertTrue(waitForDisappearance(of: app.buttons["Draw"], timeout: 10),
                      "the ink bar is still on screen after edit mode was turned off")
        XCTAssertFalse(app.buttons["Erase"].exists, "the eraser outlived the mode")
        XCTAssertFalse(app.buttons["Red pen"].exists, "the colours outlived the mode")
        shot("ink-bar-hidden-with-mode-off")

        // and it comes back
        markup.tap()
        XCTAssertTrue(app.buttons["Draw"].waitForExistence(timeout: 10),
                      "the ink bar did not come back when edit mode was turned on again")
        markup.tap()
        XCTAssertTrue(waitForDisappearance(of: app.buttons["Draw"], timeout: 10))
    }

    // MARK: - An arrangement with nothing in it

    /// Ali's device grew a "Morrison's jig" with ZERO versions. Tapping it sat
    /// on "Opening…" for ever: `renderIfNeeded` returns at its guard when there
    /// is no version to display, so nothing was ever in flight and the spinner
    /// was simply the fallback branch with no way out.
    func testAnArrangementWithNoVersionsSaysSoAndCanBeDeleted() {

        app.terminate()
        app.launchArguments = ["-resetLibrary", "-seedTestLibrary",
                               "-annotateWithFinger", "-seedBrokenArrangement"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["library-search"]
                        .waitForExistence(timeout: 90))
        app.buttons["segment-pieces"].tap()

        // it has no piece, so it sits in the library on its own
        let broken = app.buttons["row-broken-arrangement"]
        XCTAssertTrue(broken.waitForExistence(timeout: 60),
                      "the version-less arrangement is not in the library")
        // The wording moved in 0.8.2 (item 11): an unfiled arrangement's
        // subtitle names its KIND rather than counting versions, so a healthy
        // one reads "Arrangement" and this one has to say more than that.
        // Asserted against a HEALTHY row in the same list, or "contains
        // Arrangement" would pass for both and this test would stop
        // protecting anything.
        XCTAssertTrue(broken.label.contains("no versions"),
                      "expected it to admit it has no versions: \(broken.label)")
        let healthy = app.buttons["row-sous-le-ciel-de-paris"]
        XCTAssertTrue(healthy.waitForExistence(timeout: 60),
                      "no healthy row to tell the broken one apart from")
        XCTAssertFalse(healthy.label.contains("no versions"),
                       "a healthy row must not read as broken: \(healthy.label)")
        broken.tap()

        // it must say what is wrong rather than spin
        XCTAssertTrue(app.staticTexts["Nothing to show"].waitForExistence(timeout: 30),
                      "a version-less arrangement should explain itself, not spin")
        XCTAssertFalse(app.staticTexts["Opening…"].exists,
                       "still showing the spinner for an arrangement that can never load")
        shot("version-less-arrangement")

        // and there is a way out, right there
        // found by label: an identifier on the StateView container would be
        // inherited by this button, which is what hid the chip's mode buttons
        let delete = app.buttons["Delete this arrangement"]
        XCTAssertTrue(delete.waitForExistence(timeout: 10),
                      "no way to delete it from the screen that tells you it is broken")
        delete.tap()
        // NO confirmation step here, and waiting for one cost this test ten
        // seconds on every run: `Delete this arrangement` calls
        // `state.deleteScore` and closes the screen (ContentView), so the work
        // starts on the tap. The line that waited for a "Delete" button was
        // waiting for something the app has never shown.

        switch waitForDelete(of: broken) {
        case .landed:
            break
        case .noSignal(let waited):
            XCTFail("the engine never answered the delete: no undo bar and the "
                    + "row still there after \(Int(waited))s. On a quiet "
                    + "machine this lands in about 25s.")
        case .noRedraw:
            XCTFail("the delete landed -- the undo bar appeared -- and the "
                    + "library did not redraw: the broken arrangement is still "
                    + "in the list.")
        }
        shot("version-less-arrangement-deleted")
    }

    // MARK: - Hold-then-drag, and what it must not break

    /// A finger never selects, at any speed or duration. The hand moves the
    /// paper and nothing else; only the Pencil selects. If this fails the score
    /// is unreadable — every attempt to scroll would lasso instead.
    ///
    /// Launched WITHOUT the Pencil stand-in, so these really are fingers.
    func testAFingerNeverSelectsHoweverItDrags() {
        openArrangement(firstArrangement)
        let canvas = waitForEngraving(of: firstArrangement)

        // quick drags (a scroll), and slow held ones (what the old finger
        // lasso needed) -- neither may select
        // A finger that MOVES never selects: a drag is a pan. A finger held
        // STILL is the press, with its loupe -- the finger's way to select
        // (CanvasTap §9.2) -- so the drags are asserted and the presses are
        // not; the old presses passed only because the crosshair happened
        // to land on nothing.
        for dy in [0.55, 0.45, 0.40, 0.35] {
            canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: dy))
                .press(forDuration: 0.05,
                       thenDragTo: canvas.coordinate(
                        withNormalizedOffset: CGVector(dx: 0.85, dy: dy)))
        }
        XCTAssertFalse(app.staticTexts["selection-chip"].waitForExistence(timeout: 4),
                       "a finger's drag selected something; a drag is a pan")
        shot("finger-never-selects")
    }

    /// Two fingers, tapped and gone, undo the last stroke -- and it must work
    /// with markup mode OFF, which is where it was lost: the recognizer used to
    /// live on the PencilKit canvas, which only takes touches while markup is on.
    func testTwoFingerTapUndoesEvenWithMarkupOff() {
        openArrangement(firstArrangement)
        waitForEngraving(of: firstArrangement)
        app.buttons["score-edit"].tap()
        XCTAssertTrue(app.buttons["Draw"].waitForExistence(timeout: 10), "no ink bar")

        let canvas = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "canvas-"))
            .firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 20), "no annotation canvas")
        func strokes() -> Int {
            Int((canvas.value as? String)?
                .replacingOccurrences(of: " strokes", with: "") ?? "-1") ?? -1
        }
        for _ in 0..<3 where strokes() < 1 {
            canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.30, dy: 0.45))
                .press(forDuration: 0.05,
                       thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.70, dy: 0.45)))
            waitUntil("the stroke to land", timeout: 10) { strokes() >= 1 }
        }
        XCTAssertEqual(strokes(), 1, "the stroke did not land")

        // leave markup mode: this is where the gesture used to stop working
        app.buttons["score-edit"].tap()
        XCTAssertTrue(waitForDisappearance(of: app.buttons["Draw"], timeout: 10),
                      "markup mode did not close")

        // tap on the page, not the scroll view: XCUITest cannot compute a
        // two-finger gesture on a scroll view element. The touches land on the
        // recognizer either way -- it lives on the scroll view beneath.
        canvas.twoFingerTap()
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline && strokes() != 0 { usleep(200_000) }
        XCTAssertEqual(strokes(), 0,
                       "two-finger tap did not undo the stroke with markup off")
        shot("two-finger-undo-outside-markup")
    }

    // testTheChipNamesTheSelectionAndHasNoModes made the same lasso as
    // testLassoSelectsElementsAndHandsThemToChat and asserted the same
    // headline and the same missing modes. Its one assertion of its own, the
    // staff in the place line, is in that test now.

    /// A lasso must select in BOTH layouts.
    ///
    /// Bug 7: it worked on a page and did nothing at all on the strip. The
    /// recognizer finds the page a stroke landed on by looking for a
    /// `LassoAnchorView` whose frame contains the touch, and continuous mode
    /// put none in the tree -- so the gesture returned before it began, and no
    /// outline was drawn, nothing was caught and no chip appeared, whatever the
    /// reader did with the Pencil.
    ///
    /// Both halves are in one test on purpose. The paged half is the control:
    /// a failure there says the harness or the fixture broke, and a failure in
    /// the continuous half alone is the bug itself. Testing continuous on its
    /// own could not tell those apart, and they cost one three-minute setup
    /// between them.
    func testTheLassoSelectsOnTheStripAsWellAsThePage() {
        withPencilStandIn()
        openArrangement(firstArrangement)
        let canvas = waitForEngraving(of: firstArrangement)

        let chip = app.staticTexts["selection-chip"]

        // The control: paged, which is where it always worked.
        XCTAssertTrue(lasso(on: canvas, chip: chip),
                      "nothing was selected in PAGED mode -- the fixture or the "
                      + "harness is broken, not the strip")
        shot("lasso-in-paged")

        // Put the page back the way it was found, so the chip that turns up
        // after the next stroke can only be the STRIP's.
        app.buttons["Clear selection"].firstMatch.tap()
        XCTAssertTrue(waitForDisappearance(of: chip, timeout: 10),
                      "the selection would not clear")

        // The strip. Switching layout re-engraves the whole score and the
        // PREVIOUS pages stay up until the new ones land (#44), so a stroke
        // taken too early is a stroke on the old canvas.
        app.buttons["layout-continuous"].tap()
        XCTAssertTrue(waitForDisappearance(of: app.staticTexts["counter-pages"],
                                           timeout: 120),
                      "the layout never changed: the page counter is still there")
        XCTAssertTrue(canvas.waitForExistence(timeout: 180),
                      "the continuous engraving never arrived")
        // KEPT, and one of the few left. The strip has no PencilCanvas and no
        // page counter -- `continuousStrip` draws tiles and nothing in it
        // publishes an identifier or a value -- so there is no fact that says
        // its tiles have rasterised. The page counter going away, waited for
        // above, says the LAYOUT changed; this waits for the DRAWING, which
        // nothing reports.
        sleep(14)

        XCTAssertTrue(lasso(on: canvas, chip: chip),
                      "a lasso on the continuous strip caught nothing: the strip "
                      + "has no anchor for the gesture to land on")
        shot("lasso-in-continuous")
        XCTAssertTrue(app.staticTexts["selection-place"].exists,
                      "the strip's selection has no place line, so the stroke "
                      + "resolved to no bar at all")
    }

    /// Drag a band across the canvas until something is caught. Which y holds
    /// notes depends on where the music sits, and on the strip that is a
    /// different band from a page's, so this tries several rather than pinning
    /// one number.
    private func lasso(on canvas: XCUIElement, chip: XCUIElement) -> Bool {
        for dy in [0.45, 0.35, 0.55, 0.28, 0.62] {
            canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.32, dy: dy))
                .press(forDuration: 0.6,
                       thenDragTo: canvas.coordinate(
                        withNormalizedOffset: CGVector(dx: 0.64, dy: dy)))
            if chip.waitForExistence(timeout: 8) { return true }
        }
        return false
    }

    func testANewArrangementCanBeAddedToASetList() {

        // The seed assigns set lists only after every import, so this waits for
        // the fixture it depends on -- in the Setlists half of the library,
        // where a set list is a row like any other.
        resetToLibraryRoot()
        app.buttons["segment-setlists"].tap()
        let seededSetlist = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "row-")).firstMatch
        XCTAssertTrue(seededSetlist.waitForExistence(timeout: 180),
                      "the seed never created a set list to add to")

        openPieceSheet()
        // blank-or-import is two visible rows now, not a menu
        app.buttons["piece-new-arrangement-\(pieceSlug)"].tap()

        // it lands as #3 of the piece (the seed files two)
        let row = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Arrangement number 3")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 180),
                      "the new arrangement never appeared in the piece")
        shot("journey-new-arrangement")

        // into a set list from its own screen, reached by the row's ☰. The new
        // arrangement's slug is not known here, so the ☰ is found by position:
        // it is the one on the row that says #3.
        let menu = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "row-menu-"))
        XCTAssertTrue(menu.count >= 3, "no ☰ on the new arrangement's row")
        tapAnyway(menu.element(boundBy: 2), in: app.scrollViews.firstMatch)
        let manage = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "arrangement-manage-")).firstMatch
        XCTAssertTrue(manage.waitForExistence(timeout: 15), "the row's ☰ offers no Arrangement")
        manage.tap()
        let addToSet = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "arrangement-setlists-")).firstMatch
        guard addToSet.waitForExistence(timeout: 15) else {
            return XCTFail("the arrangement screen does not offer set lists")
        }
        addToSet.tap()
        let chooser = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@ AND NOT identifier CONTAINS %@",
                        "chooser-", "new-setlist")).firstMatch
        guard chooser.waitForExistence(timeout: 15) else {
            return XCTFail("no existing set list offered to add it to")
        }
        let setlistName = chooser.label
            .replacingOccurrences(of: "Add to ", with: "")
            .replacingOccurrences(of: "Remove from ", with: "")
        chooser.tap()
        goBack()

        // and it now shows in that set list's own screen, as well as keeping
        // its place in the piece
        resetToLibraryRoot()
        // The pop is still animating when the library is first there; a tap
        // on the segment then is swallowed, so switch until it has switched.
        let setlistsSegment = app.buttons["segment-setlists"]
        XCTAssertTrue(setlistsSegment.waitForExistence(timeout: 20), "no Set lists segment")
        for _ in 0..<4 where !setlistsSegment.isSelected {
            settle(setlistsSegment, still: 0.5)
            setlistsSegment.tap()
            usleep(400_000)
        }
        XCTAssertTrue(setlistsSegment.isSelected, "the library would not switch to set lists")
        let setlistRow = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "row-")).firstMatch
        XCTAssertTrue(setlistRow.waitForExistence(timeout: 40),
                      "no set list \(setlistName) to look in")
        // the ☰, not the row: 0.8 opens the row's actions there, and "Set
        // list" among them is the screen
        let setlistMenu = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "row-menu-")).firstMatch
        XCTAssertTrue(setlistMenu.waitForExistence(timeout: 20), "no ☰ on the set list")
        let toScreen = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "row-setlist-screen-")).firstMatch
        for _ in 0..<3 where !toScreen.exists {
            settle(setlistMenu, still: 0.6)
            setlistMenu.tap()
            _ = toScreen.waitForExistence(timeout: 5)
        }
        XCTAssertTrue(toScreen.exists, "the set list row's ☰ offers no Set list")
        toScreen.tap()
        XCTAssertTrue(app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "setlist-member-"))
                        .firstMatch.waitForExistence(timeout: 30),
                      "nothing is listed under set list \(setlistName)")

        openPieceSheet()
        XCTAssertTrue(app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Arrangement number 3")).firstMatch.exists,
                      "the arrangement lost its place in the piece when it joined a set list")
        shot("journey-in-setlist")
    }

    /// A drawing belongs to the version it was made on. Switching versions must
    /// not carry someone's pencil marks onto a different engraving.
    func testAnnotationsBelongToTheVersionTheyWereMadeOn() {
        openArrangement(firstArrangement)
        waitForEngraving(of: firstArrangement)
        ensureASecondVersion()
        app.buttons["score-edit"].tap()
        XCTAssertTrue(app.buttons["Draw"].waitForExistence(timeout: 10), "no ink bar")

        let canvas = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "canvas-"))
            .firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 20), "no annotation canvas")
        func strokes() -> Int {
            Int((canvas.value as? String)?
                .replacingOccurrences(of: " strokes", with: "") ?? "-1") ?? -1
        }
        let firstKey = canvas.identifier
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.30, dy: 0.45))
            .press(forDuration: 0.05,
                   thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.70, dy: 0.45)))
        XCTAssertEqual(strokes(), 1, "the stroke did not land")
        app.buttons["score-edit"].tap()   // leave markup mode

        // switch to an earlier version, from the version count -- which is
        // where switching version lives since 0.6.3 #8, and where a reader
        // would do it
        openVersionsBand()
        let rows = versionRows
        guard rows.count > 1 else {
            return XCTFail("need more than one version to switch between")
        }
        rows.element(boundBy: rows.count - 1).tap()
        // the OLD engraving stays up until the new one lands (#44), so this is
        // the identifier changing rather than a canvas existing
        waitForEngraving(replacing: firstKey)

        let other = engravedPage
        XCTAssertTrue(other.waitForExistence(timeout: 60), "the other version never engraved")
        XCTAssertNotEqual(other.identifier, firstKey,
                          "switching versions did not change which canvas is on screen")
        let carried = Int((other.value as? String)?
            .replacingOccurrences(of: " strokes", with: "") ?? "-1") ?? -1
        XCTAssertEqual(carried, 0,
                       "a drawing made on one version showed up on another (\(carried) strokes)")
        shot("journey-annotation-per-version")
    }

    /// A selection is about the engraving it was drawn on: changing version
    /// L35: the chat box's resize grip STAYS. Ali chose it over a two-width
    /// toggle, and it is one of the two sanctioned drags in the app
    /// (NAV_MODAL_FREE_0.4.2 §4B.1) -- so a future "remove every drag" pass
    /// fails here rather than quietly taking it away.
    func testTheChatBoxKeepsItsResizeGrip() {
        openArrangement(firstArrangement)
        XCTAssertTrue(app.scrollViews["score-canvas"].waitForExistence(timeout: 180),
                      "the score never engraved")
        app.buttons["score-ask"].tap()

        let grip = app.descendants(matching: .any)["chat-input-grip"].firstMatch
        XCTAssertTrue(grip.waitForExistence(timeout: 20),
                      "the chat box's resize grip is gone")
        // the grip publishes the size it is set to, which is what it is for
        let before = grip.value as? String ?? ""
        print("GRIP before: \(before)")

        // Drag whichever way has room. The size is remembered between runs,
        // so a test that always drags UP asserts nothing once someone has left
        // it at the 14-line maximum -- which is exactly how this first failed.
        let lines = Int(before.split(separator: " ").first ?? "") ?? 0
        let canvas = app.windows.firstMatch
        let from = grip.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let to = canvas.coordinate(withNormalizedOffset:
                                    CGVector(dx: 0.82, dy: lines >= 8 ? 0.92 : 0.45))
        from.press(forDuration: 0.15, thenDragTo: to)
        // the grip publishes the size it is set to, so the resize IS the fact
        waitUntil("the grip to report a new size", timeout: 20) {
            (grip.value as? String ?? "") != before
        }
        let after = grip.value as? String ?? ""
        print("GRIP after: \(after)")
        XCTAssertNotEqual(after, before,
                          "dragging the grip did not resize the box (\(before))")
        shot("chat-grip-resized")
        app.buttons["Close chat"].tap()
    }

    /// #44: running an op on a selection keeps the selection, and keeps the
    /// page you were on. Every op makes a version, and the render path used to
    /// treat that exactly like opening a different arrangement -- blanking the
    /// canvas, resetting to page 1, and clearing the selection the op had just
    /// been run on.
    ///
    /// And the other half of the same rule: SWITCHING to another version is
    /// not an op on the selection, and must not leave a stale selection
    /// pointing at bars of a different score. It was its own test,
    /// testSwitchingVersionClearsAStaleSelection, after the same relaunch,
    /// lasso and transform. The rule is SelectionCombineTests'
    /// (`testASelectionSurvivesANewVersionOfTheSameScore`); this is its wiring.
    func testATransformKeepsTheSelectionAndThePage() {
        openArrangement(firstArrangement)
        withPencilStandIn()
        openArrangement(firstArrangement)
        let canvas = waitForEngraving(of: firstArrangement)

        var caught = false
        for y in [0.30, 0.20, 0.42] where !caught {
            let start = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.30, dy: y))
            start.press(forDuration: 0.6,
                        thenDragTo: canvas.coordinate(
                            withNormalizedOffset: CGVector(dx: 0.62, dy: y)))
            caught = app.staticTexts["selection-chip"].waitForExistence(timeout: 8)
        }
        guard caught else { return XCTFail("nothing was selected on the page") }
        if app.buttons["Close chat"].exists { app.buttons["Close chat"].tap() }
        let before = app.staticTexts["selection-chip"].label
        let pageBefore = app.staticTexts["counter-pages"].label
        shot("transform-selection-before")

        // a real op through the … menu, which bumps the version
        ensureASecondVersion()

        let chip = app.staticTexts["selection-chip"]
        XCTAssertTrue(chip.waitForExistence(timeout: 40),
                      "the selection was lost by the transform (was \(before))")
        // The page they are ON, not the whole readout: a transform can change
        // how many pages the score HAS -- this one engraves to 8 where it was
        // 9 -- and that is the score changing, not the reader being moved.
        func pageNumber(_ label: String) -> String {
            label.split(separator: "/").first.map {
                $0.trimmingCharacters(in: .whitespaces)
            } ?? label
        }
        XCTAssertEqual(pageNumber(app.staticTexts["counter-pages"].label),
                       pageNumber(pageBefore),
                       "the transform moved the reader off their page "
                       + "(\(pageBefore) -> \(app.staticTexts["counter-pages"].label))")
        XCTAssertTrue(canvas.exists, "the canvas did not come back")
        shot("transform-selection-after")

        // the version count, not the title: they open different columns since
        // 0.6.3 #8. openVersionsBand waits for the band before returning, so
        // the count below is not taken off an empty screen.
        openVersionsBand()
        let rows = versionRows
        guard rows.count > 1 else { return XCTFail("need two versions in the dropdown") }
        rows.element(boundBy: rows.count - 1).tap()
        XCTAssertTrue(waitForDisappearance(of: chip, timeout: 40),
                      "the selection from the previous version is still showing")
        shot("journey-selection-cleared-on-version-switch")
    }

    // MARK: - Version selection

    /// Clicking through an arrangement's versions must light exactly one row.
    /// A prompt group's steps include the group's own face version, so the
    /// group row and a step row both claimed the highlight and it read as two
    /// versions being open at once.
    func testOnlyOneVersionRowIsEverHighlighted() {

        openPieceSheet()
        let arrangement = app.buttons["arrangement-choice-\(firstArrangement)"]
        XCTAssertTrue(arrangement.waitForExistence(timeout: 20),
                      "the arrangement is not listed under its piece")
        arrangement.tap()
        XCTAssertTrue(app.scrollViews["score-canvas"].waitForExistence(timeout: 180),
                      "the score never finished engraving")

        // Make the second version this test needs rather than hoping the seed
        // left one behind: how many versions a freshly seeded arrangement has
        // is incidental, and the run where it had one made this test fail for
        // a reason that had nothing to do with highlighting.
        ensureASecondVersion()

        openArrangementScreen(firstArrangement)
        app.buttons["edit-versions-\(firstArrangement)"].tap()

        func highlighted() -> [String] {
            let rows = app.buttons.matching(
                NSPredicate(format: "identifier BEGINSWITH %@ OR identifier BEGINSWITH %@",
                            "version-\(firstArrangement)", "step-\(firstArrangement)"))
            return (0..<rows.count).map { rows.element(boundBy: $0) }
                .filter { $0.exists && $0.isSelected }
                .map { $0.identifier }
        }

        // exactly one to begin with
        var lit = highlighted()
        XCTAssertEqual(lit.count, 1, "expected one highlighted version row, got \(lit)")
        shot("version-highlight-initial")

        // open a prompt group's steps: the highlight must not double up
        let stepsToggle = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@",
                        "steps-toggle-\(firstArrangement)")).firstMatch
        if stepsToggle.exists {
            stepsToggle.tap()
            lit = highlighted()
            XCTAssertEqual(lit.count, 1,
                           "opening a prompt group's steps lit \(lit.count) rows: \(lit)")
            shot("version-highlight-steps-open")
        }

        // click through every version row; each click moves the single highlight
        let rows = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@ OR identifier BEGINSWITH %@",
                        "version-\(firstArrangement)", "step-\(firstArrangement)"))
        let count = min(rows.count, 4)
        XCTAssertGreaterThan(count, 1, "the fixture needs more than one version to click through")
        for index in 0..<count {
            let row = rows.element(boundBy: index)
            guard row.exists, row.isHittable else { continue }
            let identifier = row.identifier
            row.tap()
            // the highlight MOVING is the fact; a fixed pause was standing in
            // for a round trip through the engine
            let bare = identifier.replacingOccurrences(of: "step-", with: "")
                .replacingOccurrences(of: "version-", with: "")
            waitUntil("the highlight to move to \(identifier)", timeout: 60) {
                let now = highlighted()
                return now.count == 1 && (now.first?.contains(bare) ?? false)
            }
            lit = highlighted()
            XCTAssertEqual(lit.count, 1,
                           "after opening \(identifier), \(lit.count) rows are highlighted: \(lit)")
            XCTAssertTrue(lit.first?.contains(identifier.replacingOccurrences(
                            of: "step-", with: "").replacingOccurrences(
                            of: "version-", with: "")) ?? false,
                          "the highlight is on \(lit) but \(identifier) was opened")
        }
        shot("version-highlight-after-clicks")
    }

    // MARK: - Dragging
    // MARK: - Two pages side by side

    /// The risk in a spread is that the right-hand page selects from its
    /// neighbour: two pages now share a row, and a lasso has to resolve to the
    /// page it was actually drawn on. Bars run forward through the score, so
    /// the right page must give higher bar numbers than the left.
    func testALassoOnTheRightHandPageSelectsFromThatPage() {
        withPencilStandIn()
        setTwoPageSpread(on: true)
        openArrangement(firstArrangement)
        let canvas = waitForEngraving(of: firstArrangement)
        shot("two-page-spread")

        guard let left = lassoBars(on: canvas, from: 0.08, to: 0.34) else {
            return XCTFail("nothing was selected anywhere on the left-hand page")
        }
        // chat opened over the canvas; put it away before drawing again
        if app.buttons["Close chat"].exists { app.buttons["Close chat"].tap() }
        settle(all: [canvas, engravedPage])
        guard let right = lassoBars(on: canvas, from: 0.66, to: 0.92) else {
            return XCTFail("nothing was selected anywhere on the right-hand page")
        }
        XCTAssertGreaterThan(right, left,
                             "the right-hand page selected bar \(right), which is not "
                             + "later than the left-hand page's bar \(left) — the lasso "
                             + "resolved to the wrong page")
        shot("spread-right-page-selected")
    }

    /// Settings offers the same three-way layout the bar does -- one property,
    /// every surface -- and one page is still the default.
    func testTheLayoutIsInSettingsAndOnePageIsTheDefault() {
        app.buttons["Settings"].firstMatch.tap()
        XCTAssertTrue(app.buttons["settings-reading"].waitForExistence(timeout: 10),
                      "settings has no Reading section")
        app.buttons["settings-reading"].tap()
        let onePage = app.switches["One page"]
        XCTAssertTrue(onePage.waitForExistence(timeout: 5), "no layout choice in settings")
        XCTAssertEqual(onePage.value as? String, "1",
                       "one page at a time is the default")
        XCTAssertEqual(app.switches["Two pages"].value as? String, "0")
        XCTAssertTrue(app.switches["Continuous"].exists,
                      "settings cannot say 'continuous' at all if it is a spread toggle")
        closeSettings()
    }

    private func setTwoPageSpread(on: Bool) {
        app.buttons["Settings"].firstMatch.tap()
        let wanted = app.switches[on ? "Two pages" : "One page"]
        XCTAssertTrue(wanted.waitForExistence(timeout: 10),
                      "no layout choice in settings")
        if wanted.value as? String != "1" { wanted.tap() }
        XCTAssertEqual(wanted.value as? String, "1")
        closeSettings()
    }

    /// Drag a lasso across a horizontal band and return the first bar number
    /// of whatever it caught. Which y holds notes depends on where the page
    /// sits, so try a few bands rather than pinning one magic number.
    /// The bar a lasso caught, read from the CHIP rather than from chat.
    ///
    /// The chip says "N elements from bar X" the moment a lasso lands, with no
    /// confirming and no chat -- which matters here because confirming opens
    /// the chat panel, takes 380pt off the canvas, and moves every normalized
    /// offset a second lasso would aim at. Reading the chip leaves the canvas
    /// exactly as it was found.
    private func lassoBars(on canvas: XCUIElement,
                           from dxStart: CGFloat, to dxEnd: CGFloat) -> Int? {
        let chip = app.staticTexts["selection-chip"]
        for dy in [0.30, 0.20, 0.42, 0.55, 0.12] {
            canvas.coordinate(withNormalizedOffset: CGVector(dx: dxStart, dy: dy))
                .press(forDuration: 0.6,
                       thenDragTo: canvas.coordinate(
                        withNormalizedOffset: CGVector(dx: dxEnd, dy: dy)))
            guard chip.waitForExistence(timeout: 8) else { continue }
            if let bar = lastBarNumber(in: chip.label) { return bar }
        }
        return nil
    }

    /// The newest selection reference is the last one in the input, since a
    /// reference is appended rather than replacing what is there.
    private func lastBarNumber(in text: String) -> Int? {
        let pattern = try? NSRegularExpression(pattern: "bars? ([0-9]+)")
        let ns = text as NSString
        guard let match = pattern?.matches(
            in: text, range: NSRange(location: 0, length: ns.length)).last else { return nil }
        return Int(ns.substring(with: match.range(at: 1)))
    }

    // The lasso must never cost the gestures that were already there: pinch
    // zoom under this class's own setUp is testTheZoomedPageUsesTheWholeCanvas,
    // which zooms to at least 1.8 twice and pans to both edges.

    /// The piece is metadata as well, and its name was editable nowhere.
    func testPieceIsRenamedByTappingItsName() {

        openPieceSheet()
        let title = app.buttons["piece-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 20), "no piece name to tap")
        title.tap()
        let field = app.textFields["piece-title-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10),
                      "tapping the name should open it for editing in place")
        XCTAssertFalse(app.buttons["Rename"].exists,
                       "nothing offers a Rename button any more")
        replaceText(field, with: "Paris Revisited")
        field.typeText("\n")           // Done commits, as it does for a file name
        XCTAssertTrue(app.buttons["piece-title"].waitForExistence(timeout: 30),
                      "the name never went back to being a name")
        XCTAssertTrue(element(labelStartingWith: "Paris Revisited")
                        .waitForExistence(timeout: 30),
                      "the piece heading still shows the old name")
        shot("piece-renamed")
    }

    /// Ali's build-125 ask: a set list holds ARRANGEMENTS. Creating one asks
    /// for the name first, then offers arrangements to put in it.
    func testNewSetlistAsksForANameThenOffersArrangements() {

        app.buttons["segment-setlists"].tap()
        // One tap: on Set lists, New makes a set list (0.8.2 item 13).
        app.buttons["library-new"].tap()
        // naming happens in a band at the top of the list, not in an alert
        let field = app.textFields["inline-rename-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "no field to name it in")
        XCTAssertTrue(app.buttons["inline-rename-save"].exists,
                      "no way to commit the name")
        XCTAssertFalse(app.buttons["OK"].exists, "nothing in this app says OK")
        field.tap()
        field.typeText("Gig night")
        shot("setlist-name-first")
        app.buttons["inline-rename-save"].tap()

        // the picker opens on the new set list, listing arrangements
        XCTAssertTrue(app.staticTexts["In this set list"].waitForExistence(timeout: 20),
                      "naming a set list should lead straight to picking its arrangements")
        let add = app.buttons["picker-add-\(firstArrangement)"]
        XCTAssertTrue(add.waitForExistence(timeout: 10),
                      "the picker should offer arrangements, not pieces")
        XCTAssertFalse(app.buttons[piece].exists,
                       "a set list holds arrangements; pieces should not be offered")
        add.tap()
        XCTAssertTrue(app.buttons["picker-remove-\(firstArrangement)"]
                        .waitForExistence(timeout: 20),
                      "the arrangement did not move into the set list")
        shot("setlist-picker")
        goBack()

        // and the set list's own screen, reached by its ☰, lists it
        let gigMenu = app.buttons["row-menu-gig-night"]
        XCTAssertTrue(gigMenu.waitForExistence(timeout: 20),
                      "the new set list is not in the library")
        gigMenu.tap()
        app.buttons["row-setlist-screen-gig-night"].tap()
        XCTAssertTrue(app.buttons["setlist-member-\(firstArrangement)"]
                        .waitForExistence(timeout: 20),
                      "the set list does not list the arrangement")

        // clean up so repeat runs stay deterministic: Edit mode, select, delete
        resetToLibraryRoot()
        app.buttons["segment-setlists"].tap()
        app.buttons["library-edit"].tap()
        let pick = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "row-select-")).firstMatch
        if pick.waitForExistence(timeout: 10) {
            pick.tap()
            if app.buttons["bar-delete"].waitForExistence(timeout: 10) {
                app.buttons["bar-delete"].tap()
            }
        }
    }

    /// The + on an existing set list adds arrangements to it.
    func testAddingAnArrangementToAnExistingSetlist() {
        app.buttons["segment-setlists"].tap()
        // the set list's own ☰ opens its screen; Add arrangements is a row on it
        let menu = app.buttons["row-menu-test-setlist"]
        XCTAssertTrue(menu.waitForExistence(timeout: 20), "no ☰ on the seeded set list")
        menu.tap()
        app.buttons["row-setlist-screen-test-setlist"].tap()
        let add = app.buttons["setlist-add-test-setlist"]
        XCTAssertTrue(add.waitForExistence(timeout: 20),
                      "the set list screen has no way to add arrangements")
        add.tap()
        XCTAssertTrue(app.staticTexts["In this set list"].waitForExistence(timeout: 10),
                      "the add-arrangements screen did not open")
        // the seed puts both arrangements in, so they are all members already
        XCTAssertTrue(app.buttons["picker-remove-\(firstArrangement)"].exists,
                      "the seeded set list should already hold the arrangements")
        shot("setlist-add-arrangements")
        goBack()
    }

    /// And an arrangement can be put in a set list from its own screen.
    ///
    /// Named for the ☰, not a context menu: long-press menus are gone from the
    /// app, and a test whose name says otherwise makes people think they are
    /// still there.
    func testArrangementScreenOffersAddToSetList() {
        openArrangementScreen(firstArrangement)
        let action = app.buttons["arrangement-setlists-\(firstArrangement)"]
        XCTAssertTrue(action.waitForExistence(timeout: 15),
                      "no way to add an arrangement to a set list from its screen")
        action.tap()
        XCTAssertTrue(app.buttons["chooser-test-setlist"].waitForExistence(timeout: 15),
                      "the set list chooser did not open")
        shot("add-to-setlist-chooser")
        goBack()
    }



    /// Settings is a page with an index and one section beside it (0.8
    /// §7.17), reached from the library's gear and left with Close settings.
    func testSettingsIsAPanel() {
        app.buttons["Settings"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["settings-split"].waitForExistence(timeout: 10),
                      "settings did not open")
        XCTAssertTrue(app.buttons["settings-engine"].exists, "no Engine section")
        XCTAssertTrue(app.buttons["settings-model"].exists, "no Model section")
        shot("settings-sheet")
        closeSettings()
    }

    // MARK: - Markup

    func testMarkupModeAndTheInkBar() {
        openArrangement(firstArrangement)
        let markup = app.buttons["score-edit"]
        XCTAssertTrue(markup.waitForExistence(timeout: 60))
        XCTAssertFalse(app.buttons["Draw"].exists, "the ink bar should be hidden")
        markup.tap()
        XCTAssertTrue(app.buttons["Draw"].waitForExistence(timeout: 5), "no ink bar")
        XCTAssertTrue(app.buttons["Erase"].exists)
        XCTAssertTrue(app.buttons["Red pen"].exists)
        XCTAssertFalse(app.buttons["Undo annotation"].isEnabled,
                       "undo should be disabled with nothing drawn")
        shot("ink-bar")
        app.buttons["Finish annotating"].tap()
        XCTAssertTrue(waitForDisappearance(of: app.buttons["Draw"], timeout: 5))
    }

    /// #45: in ink mode a two-finger pinch zoomed the ANNOTATION layer on its
    /// own -- the ink slid and flipped over a score that stayed put. The score
    /// owns zooming; the canvas is only ever told what scale to draw at.
    func testPinchingInInkModeZoomsTheScoreNotTheInk() {
        openArrangement(firstArrangement)
        let score = waitForEngraving(of: firstArrangement)
        func zoom() -> CGFloat {
            CGFloat(Double((score.value as? String)?
                .replacingOccurrences(of: "zoom ", with: "") ?? "0") ?? 0)
        }
        app.buttons["score-edit"].tap()
        XCTAssertTrue(app.buttons["Draw"].waitForExistence(timeout: 20), "no ink bar")
        let before = zoom()
        for _ in 0..<6 where zoom() < before * 1.4 {
            score.pinch(withScale: 3.0, velocity: 2.0)
        }
        // the scroll view publishes its own zoom, so that is what is waited on
        waitUntil("the score to report the new zoom", timeout: 20) {
            zoom() > before * 1.2
        }
        XCTAssertGreaterThan(zoom(), before * 1.2,
                             "pinching in ink mode did not zoom the SCORE "
                             + "(\(before) -> \(zoom())) -- the ink layer took it")
        shot("ink-mode-zoom")
        app.buttons["Finish annotating"].tap()
    }

    /// Ali's #3: the ink tools floated over the middle of the score. They dock
    /// in the footer now, and the handle moves them off whatever they are
    /// covering -- with a tap to put them back, so a bar dragged somewhere
    /// awkward is never stranded.
    func testTheInkToolsDockAndCanBeMovedAndPutBack() {
        openArrangement(firstArrangement)
        let score = waitForEngraving(of: firstArrangement)
        app.buttons["score-edit"].tap()
        XCTAssertTrue(app.buttons["Draw"].waitForExistence(timeout: 20),
                      "the ink bar did not open")

        let handle = app.descendants(matching: .any)["ink-bar-handle"]
        XCTAssertTrue(handle.waitForExistence(timeout: 10), "no move handle")

        // docked: in the bottom of the pane, below the music rather than over it
        let docked = handle.frame
        XCTAssertGreaterThan(docked.midY, score.frame.midY,
                             "the tools should start in the footer, not mid-score")

        // the handle moves them
        handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1,
                   thenDragTo: score.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)))
        settle(handle, still: 0.3)
        let moved = handle.frame
        XCTAssertLessThan(moved.midY, docked.midY - 100,
                          "the handle did not move the tools: \(docked) -> \(moved)")

        // ...and a tap puts them back, which is the way home for anyone who
        // cannot drag
        handle.tap()
        settle(handle, still: 0.3)
        XCTAssertEqual(handle.frame.midY, docked.midY, accuracy: 8,
                       "tapping the handle did not re-dock the tools")

        app.buttons["Finish annotating"].tap()
    }

    /// The build-116 bug: draw, undo, switch colour, draw, undo. The first
    /// stroke must not come back. Stroke counts are read off the canvas.
    func testAnnotationUndoAcrossColourChange() {
        openArrangement(firstArrangement)
        // THE ENGRAVING FIRST. The annotation canvas is a child of a PAGE, so
        // it cannot exist until the pages do, and the pages are an engine
        // round trip away. What stood here was a ten-second wall-clock budget
        // spent across that round trip -- one of the "fifteen places [that]
        // waited twelve seconds for this and hoped" that `waitForEngraving`
        // was written to remove, and the one place that never got converted.
        //
        // Measured 2026-09-17, solo on an idle machine, at this commit AND at
        // 38bd7557 before items 8-10: the wait took 7.2 of its 10 seconds and
        // passed with 2.8 to spare. Under four gate workers it ran out, twice.
        // Nothing about the branch made it slower -- 7.15s at HEAD against
        // 7.23s at the base -- the budget was always this close to the edge.
        //
        // `waitForEngraving` waits for the SIGNAL instead, and for this
        // arrangement's own engraving rather than whatever page happens to be
        // on screen. Every assertion below is unchanged.
        waitForEngraving(of: firstArrangement)
        XCTAssertTrue(app.buttons["score-edit"].waitForExistence(timeout: 90),
                      "the markup toggle never appeared in the pill")
        app.buttons["score-edit"].tap()
        XCTAssertTrue(app.buttons["Draw"].waitForExistence(timeout: 10),
                      "the ink bar did not open")

        let canvas = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "canvas-"))
            .firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 30), "no annotation canvas")

        func strokes() -> Int {
            Int((canvas.value as? String)?
                .replacingOccurrences(of: " strokes", with: "") ?? "-1") ?? -1
        }
        // The canvas exists before the page under it has finished engraving, and
        // a stroke drawn in that window lands nowhere. Wait for the count to be
        // readable, then allow the stroke one retry.
        func draw() {
            let before = strokes()
            for _ in 0..<3 {
                canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.30, dy: 0.45))
                    .press(forDuration: 0.05,
                           thenDragTo: canvas.coordinate(
                            withNormalizedOffset: CGVector(dx: 0.70, dy: 0.45)))
                if waitUntil("the stroke to land", timeout: 10, { strokes() > before }) {
                    return
                }
            }
        }

        XCTAssertTrue(app.scrollViews["score-canvas"].waitForExistence(timeout: 180),
                      "the score never engraved")
        XCTAssertEqual(strokes(), 0, "canvas should start empty")
        draw()
        XCTAssertEqual(strokes(), 1, "the stroke did not land")
        app.buttons["Undo annotation"].tap()
        XCTAssertEqual(strokes(), 0, "undo did not remove the stroke")
        app.buttons["Blue pen"].tap()
        draw()
        XCTAssertEqual(strokes(), 1,
                       "after a colour change there must be exactly one stroke")
        app.buttons["Undo annotation"].tap()
        XCTAssertEqual(strokes(), 0, "undo after a colour change did not work")
        app.buttons["Finish annotating"].tap()
    }

    // testPinchZoomKeepsScoreUsable zoomed and checked the bar survived it;
    // testTheZoomedPageUsesTheWholeCanvas zooms further and checks the same.

    // MARK: - Adding

    func testAddMenuCreatesBlankArrangement() {
        openPieceSheet()
        // Blank-or-import used to be a Menu on one button. Menus are gone
        // (0.4.2 §2), so the choice is two visible rows on the piece screen --
        // which is the same choice, said out loud.
        let blank = app.buttons["piece-new-arrangement-\(pieceSlug)"]
        XCTAssertTrue(blank.waitForExistence(timeout: 20),
                      "the piece screen offers no way to make an arrangement")
        XCTAssertTrue(app.buttons["piece-import-\(pieceSlug)"].exists,
                      "...and no way to import one into the piece")
        blank.tap()
        //
        // Alphabetically first, so this is the suite's cold start: it pays for
        // the app launch, the Python engine's first import, the library reset
        // and re-seed, and the engrave of whatever the app opens by itself —
        // and only then waits for another engine round trip. Which is what the
        // 180 seconds below are for; the fixed six that used to precede them
        // were spent whether the round trip had landed or not.
        XCTAssertTrue(element(labelStartingWith: "Arrangement number 3")
                        .waitForExistence(timeout: 180),
                      "the new arrangement did not appear as #3 of the piece")
    }

    /// Filing and deleting used to be a long press. They are rows on the
    /// arrangement screen now, reached by the row's ☰ -- visible, labelled, and
    /// reachable without knowing a gesture.
    func testTheArrangementScreenOffersFilingAndDeletion() {
        openArrangementScreen(firstArrangement)
        XCTAssertTrue(app.buttons["arrangement-move-\(firstArrangement)"].exists,
                      "no way to file this arrangement")
        XCTAssertTrue(app.buttons["edit-delete-\(firstArrangement)"].exists,
                      "no way to delete this arrangement")
        XCTAssertFalse(app.menuItems["Move to piece"].exists,
                       "a long press should reach nothing at all now")
    }
}

extension ScorangerUITests {

    // testTheTransportIsReachableAndEveryVoiceCanBeSwitchedOff walked the tray
    // to every voice off and back, then played and stopped. Every step of it
    // is in testTheTrayHasAKnobPerStaff, on the same quartet, with the music
    // running: the dropdown gone, a mute, metronome only against silent, All
    // on, Stop back to Play. One open and one timeline instead of two.
}

extension ScorangerUITests {

    /// The tray is on screen, or say so.
    ///
    /// It used to walk three routes -- already there, the bar's toggle, … →
    /// Show transport -- because 0.6 had a switch. 0.8 has none: the tray is
    /// always there while reading (§7.7), so the only thing left to prove is
    /// that it IS. Kept under its old name because every playback test
    /// starts here, and the name still says what the caller wants.
    func revealTransport() {
        XCTAssertTrue(app.otherElements["transport"].waitForExistence(timeout: 30),
                      "the tray is not on screen: there is no switch to put it there any more")
    }

    /// Press play and wait for the play head to actually move.
    ///
    /// It used to wait on the voice button's label leaving "no parts" and then
    /// press once. That button is gone (0.6.6), and the readiness it stood for
    /// -- music21 has finished writing the MIDI on device -- has no readout of
    /// its own, so this presses and presses again until the readout names a
    /// bar. Only a sequencer that is actually running produces that, so it is
    /// a stronger signal than the label it replaces, not a weaker one.
    func startPlaying() {
        let play = app.buttons["transport-play"]
        XCTAssertTrue(play.waitForExistence(timeout: 60), "no transport")
        let bar = app.staticTexts["transport-bar"]
        // BOTH conditions. The readout says "bar 1" as soon as a timeline is
        // loaded -- the play head is at the start, which is a bar -- so the
        // bar alone would be satisfied by a transport that never started.
        XCTAssertTrue(waitUntil("playback to start", timeout: 200) {
            if play.label == "Stop", bar.exists, bar.label.hasPrefix("bar ") {
                return true
            }
            // Only ever pressed while it says Play, so a press that DID take
            // is never pressed back off.
            if play.exists, play.isEnabled, play.label == "Play" { play.tap() }
            return false
        }, "the transport never started: play=\(play.label) "
           + "bar=\(bar.exists ? bar.label : "-")")
    }

    /// The playhead, photographed, and the lasso proved to still work under it.
    ///
    /// Two regressions in one journey, because they share a setup that costs
    /// three minutes. The cursor layer sits directly over the music, where the
    /// lasso and the Pencil live -- if it ever took a touch, selection would
    /// fail wherever the music happened to be playing, and it would fail only
    /// while playing, which is the hardest kind of bug to be told about.
    func testThePlayheadDrawsAndTheLassoStillSelectsUnderIt() {
        withPencilStandIn()
        openArrangement(firstArrangement)
        let canvas = waitForEngraving(of: firstArrangement)

        revealTransport()
        startPlaying()

        // The picture the owner asked for.
        shot("playhead")
        XCTAssertEqual(app.buttons["transport-play"].label, "Stop",
                       "the screenshot must be of a score that is PLAYING")

        // And now a lasso, with the cursor on screen and the transport running.
        let chip = app.staticTexts["selection-chip"]
        var caught = false
        for y in [0.30, 0.20, 0.42, 0.55] where !caught {
            let start = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.30, dy: y))
            let end = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.62, dy: y))
            start.press(forDuration: 0.6, thenDragTo: end)
            caught = chip.waitForExistence(timeout: 8)
        }
        XCTAssertTrue(caught,
                      "nothing was selected while the transport was running: "
                      + "the cursor layer is eating touches")
        shot("playhead-with-selection")

        // A lasso must not have stopped the music either.
        XCTAssertEqual(app.buttons["transport-play"].label, "Stop",
                       "selecting stopped playback")
    }

    /// Pencil still MARKS while the transport runs.
    ///
    /// The lasso test proves SELECTION survives the cursor layer. Ink is the
    /// other thing living under it and it is a different code path -- a
    /// PencilKit canvas, not a gesture recogniser -- so proving one says
    /// nothing about the other. Both would fail the same way and only while
    /// playing, which is the hardest kind of report to act on.
    func testThePencilStillMarksWhileTheTransportRuns() {
        withPencilStandIn()
        openArrangement(firstArrangement)
        let canvas = waitForEngraving(of: firstArrangement)

        revealTransport()
        startPlaying()

        let markup = app.buttons["score-edit"]
        XCTAssertTrue(markup.waitForExistence(timeout: 30), "no markup control")
        markup.tap()
        XCTAssertTrue(app.buttons["Draw"].waitForExistence(timeout: 10),
                      "markup mode did not open while playing")

        let ink = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "canvas-"))
            .firstMatch
        XCTAssertTrue(ink.waitForExistence(timeout: 30), "no annotation canvas")
        let before = strokeCount(ink)

        // A stroke straight through where the cursor is standing.
        let from = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.28))
        let to = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.34))
        from.press(forDuration: 0.05, thenDragTo: to)

        let drew = NSPredicate(format: "value != %@", "\(before) strokes")
        expectation(for: drew, evaluatedWith: ink, handler: nil)
        waitForExpectations(timeout: 20)
        XCTAssertGreaterThan(strokeCount(ink), before,
                             "the Pencil could not mark while the transport ran")
        shot("pencil-while-playing")
    }

    private func strokeCount(_ canvas: XCUIElement) -> Int {
        Int((canvas.value as? String)?
            .replacingOccurrences(of: " strokes", with: "") ?? "-1") ?? -1
    }

    /// The playhead's weight is a size ON SCREEN, at any zoom.
    ///
    /// Every constant in the layer is divided by the scroll view's zoom for
    /// exactly this reason: undivided, the line is a hairline zoomed out and a
    /// slab lying over the noteheads at 3x. Right-by-inspection is not
    /// verification, so this photographs it at two zooms and leaves the pair
    /// in the repo to be looked at.
    ///
    /// The weight it photographs is 1pt since 0.6.6, down from the 2pt §2 drew
    /// -- so the pair should measure about 2 device pixels at BOTH zooms
    /// rather than the 4 the earlier pictures showed. The number itself is
    /// asserted in `PlayheadTests.testTheLineIsAHairline`; what a picture adds
    /// is whether the view divides by the right thing, which arithmetic
    /// cannot see.
    func testThePlayheadKeepsItsWeightAtAnyZoom() {
        openArrangement(firstArrangement)
        let canvas = waitForEngraving(of: firstArrangement)

        revealTransport()
        startPlaying()
        shot("playhead-zoom-1x")

        canvas.pinch(withScale: 3.0, velocity: 1.5)
        // Let the raster settle: the layer divides by the SETTLED zoom, so a
        // shot taken mid-gesture would photograph a weight neither value.
        // `settle` returns false rather than failing if the page never holds
        // still, which under a running playhead is a real possibility -- and
        // what follows is a photograph and a check on the transport, neither
        // of which is worth failing here for.
        settle(engravedPage, still: 0.5, timeout: 10)
        shot("playhead-zoom-3x")
        XCTAssertEqual(app.buttons["transport-play"].label, "Stop",
                       "zooming stopped playback")
    }

    /// The handle at the top of the cursor is DRAGGABLE, and dragging it
    /// scrubs (0.6.6).
    ///
    /// Three claims, and the second two are the reason this is a UI test and
    /// not arithmetic:
    ///
    /// 1. dragging the handle moves the play head -- the transport's bar
    ///    readout changes, which only a moved sequencer position produces;
    /// 2. it does NOT scroll the canvas, which is what a SwiftUI DragGesture
    ///    inside this UIScrollView would have done: the scroll view's own pan
    ///    sees the same touch;
    /// 3. it does NOT start or stop the music. The handle is not the play
    ///    button; a scrub that started the music would make looking at a bar
    ///    an act of performing it.
    ///
    /// Dragged while STOPPED, deliberately: that is the harder case for the
    /// gesture (nothing is moving to mask a failure) and it is the state a
    /// reader is usually in when they want to jump somewhere.
    func testTheHandleScrubsWithoutScrollingTheCanvas() {
        openArrangement(firstArrangement)
        let canvas = waitForEngraving(of: firstArrangement)

        revealTransport()
        startPlaying()
        // Stop, and stay where the music got to: the cursor and its handle
        // are still on the page, which is what makes a scrub from rest
        // possible at all.
        app.buttons["transport-play"].tap()
        XCTAssertEqual(app.buttons["transport-play"].label, "Play",
                       "Stop did not stop it")

        let handle = app.descendants(matching: .any)["playhead-handle"].firstMatch
        XCTAssertTrue(handle.waitForExistence(timeout: 30),
                      "the cursor has no grab handle")
        shot("playhead-handle-before-drag")

        let before = app.staticTexts["transport-bar"].label
        let zoomBefore = canvas.value as? String ?? "?"
        // Where the PAGE is on screen. A drag that scrolled the canvas moves
        // it; a drag that only scrubbed does not.
        settle(engravedPage, still: 0.4, timeout: 10)
        let pageBefore = engravedPage.frame

        // Along the system, well to the right of where the head is standing.
        // From the handle's own centre, which is where its accessibility
        // frame puts it -- the view spans the layer and only reports the
        // 32pt square.
        handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.3,
                   thenDragTo: canvas.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.85, dy: 0.22)))

        XCTAssertTrue(waitUntil("the play head to move", timeout: 15) {
            app.staticTexts["transport-bar"].label != before
        }, "dragging the handle did not move the play head: it still reads "
           + "\(app.staticTexts["transport-bar"].label)")
        shot("playhead-handle-after-drag")

        XCTAssertEqual(canvas.value as? String, zoomBefore,
                       "the drag zoomed the canvas")
        settle(engravedPage, still: 0.4, timeout: 10)
        XCTAssertEqual(engravedPage.frame, pageBefore,
                       "the drag scrolled the canvas: the page moved from "
                       + "\(pageBefore) to \(engravedPage.frame)")
        XCTAssertEqual(app.buttons["transport-play"].label, "Play",
                       "scrubbing started the music, which the handle must not do")
    }

    /// And the lasso still selects where the handle is NOT.
    ///
    /// The cursor layer takes touches now, which is the change
    /// `testThePlayheadDrawsAndTheLassoStillSelectsUnderIt` was written to
    /// catch. It is safe only because the layer's hit test returns nil
    /// everywhere but the handle's own 32pt target -- so this drags a lasso
    /// through the same band of music with the transport running, exactly as
    /// that test does, one build after the touch handling changed underneath
    /// it. Both are kept: one proves the drag works, this proves it costs the
    /// lasso nothing.
    func testTheHandleDoesNotStealTheLassosTouches() {
        withPencilStandIn()
        openArrangement(firstArrangement)
        let canvas = waitForEngraving(of: firstArrangement)

        revealTransport()
        startPlaying()
        XCTAssertTrue(app.descendants(matching: .any)["playhead-handle"]
                        .firstMatch.waitForExistence(timeout: 30),
                      "no handle, so this proves nothing about it")

        let chip = app.staticTexts["selection-chip"]
        var caught = false
        for y in [0.30, 0.20, 0.42, 0.55] where !caught {
            let start = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.30, dy: y))
            let end = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.62, dy: y))
            start.press(forDuration: 0.6, thenDragTo: end)
            caught = chip.waitForExistence(timeout: 8)
        }
        XCTAssertTrue(caught,
                      "nothing was selected with the drag handle on screen: "
                      + "the handle's hit test is claiming the whole layer")
        shot("lasso-with-draggable-handle")
        XCTAssertEqual(app.buttons["transport-play"].label, "Stop",
                       "selecting stopped playback")
    }

    /// The tray's knobs: one per staff, and their controls live (0.8 §7.7).
    func testTheTrayHasAKnobPerStaff() {
        openArrangement(firstArrangement)
        waitForEngraving(of: firstArrangement)
        revealTransport()
        startPlaying()

        // The voice list is GONE (0.6.6), and the mixer window (0.8): the
        // knobs are on the tray and there is nothing to open.
        XCTAssertFalse(app.buttons["transport-voices"].exists,
                       "the voice dropdown is back on the transport")
        XCTAssertFalse(app.buttons["transport-mixer"].exists,
                       "there is a mixer button again: the tray IS the mixer")
        if !app.descendants(matching: .any)["strip-mute-0"].waitForExistence(timeout: 180) {
            shot("tray-without-knobs")
            XCTFail("the tray never grew a knob")
        }

        // A knob per staff -- the seeded quartet has four.
        let strips = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "strip-mute-"))
        XCTAssertEqual(strips.count, 4, "expected one strip per staff")

        // The activity LEDs, which are the reason the engine emits merged
        // sounding intervals at all. This waits for a moment where SOME staves
        // sound and others do not: an all-lit shot proves the lamps can come
        // on and says nothing about them being PER CHANNEL, which is the whole
        // point of driving them from per-part data. The score opens with the
        // top staff resting while the lower three play, so the moment exists.
        func ledStates() -> [String] {
            (0..<4).map {
                app.descendants(matching: .any)["strip-led-\($0)"]
                    .firstMatch.value as? String ?? "?"
            }
        }
        var mixed: [String] = []
        for _ in 0..<40 {
            let states = ledStates()
            if states.contains("yes") && states.contains("no") { mixed = states; break }
            usleep(250_000)
        }
        XCTAssertFalse(mixed.isEmpty,
                       "never a moment where some staves sounded and others did "
                       + "not; LEDs read \(ledStates())")
        shot("mixer")

        // Muted does not go dark. The staff IS playing and the reader simply
        // cannot hear it, which is how they confirm the mute is working -- so
        // the lamp follows the music and the strip dims around it.
        if let lit = ledStates().firstIndex(of: "yes") {
            let mute = app.descendants(matching: .any)["strip-mute-\(lit)"].firstMatch
            mute.tap()
            XCTAssertEqual(mute.value as? String, "on", "the strip did not mute")
            // The lamp follows the MUSIC, and the music keeps moving: reading
            // it one instant after the tap can catch a rest that arrived on
            // its own, and the failure then reads as "muting put the lamp
            // out". Under four simulators it did, once in three runs -- twice
            // now, across two attempts at this branch.
            //
            // The property is that muting does not darken the lamp FOR GOOD,
            // so this waits for the muted staff to light again -- which is a
            // stronger claim than the instant it replaces, not a weaker one.
            let led = app.descendants(matching: .any)["strip-led-\(lit)"].firstMatch
            XCTAssertTrue(waitUntil("the muted staff's lamp to light again",
                                    timeout: 25) {
                (led.value as? String) == "yes"
            }, "muting a channel put its activity lamp out for good")
            shot("mixer-muted-still-lit")
            // and the music did not stop for it (Ali, 2026-09-10: "When I
            // open the mixer transport, playback stops"; was MixerKeepsPlaying)
            XCTAssertEqual(app.buttons["transport-play"].label, "Stop",
                           "muting a part stopped playback")
            mute.tap()
        }

        // The mute is live, and it is the SAME mute the tray's own summary
        // counts. That summary was the transport voice button's label until
        // 0.6.6, the mixer header's until 0.8, and is the all-on/off glyph's
        // value now; the claim is unchanged: a knob and the readout beside it
        // cannot disagree.
        turnEveryVoiceOn(app)
        let firstMute = app.descendants(matching: .any)["strip-mute-0"].firstMatch
        XCTAssertEqual(firstMute.value as? String, "off")
        firstMute.tap()
        XCTAssertEqual(firstMute.value as? String, "on", "the knob's mute did nothing")
        XCTAssertTrue(waitForVoices(app, contains: "3 of 4"),
                      "the knob and the tray's own summary disagree about the "
                      + "mutes: \(voicesSummary(app))")

        // All off, then All on: the two things a row of knobs cannot do
        // between them, and the reason the glyph is there.
        //
        // And every voice off is a destination, not an error. With the
        // metronome ON it is "metronome only", and with it off it says
        // "silent", because claiming a click that is not playing sends a
        // reader hunting for a broken speaker.
        app.buttons["transport-metronome"].tap()
        turnEveryVoiceOff(app)
        XCTAssertTrue(waitForVoices(app, contains: "metronome only"),
                      "every voice off with the click on is metronome only, "
                      + "and the tray said: \(voicesSummary(app))")
        app.buttons["transport-metronome"].tap()
        XCTAssertTrue(waitForVoices(app, contains: "silent"),
                      "every voice off with the click off is silence, "
                      + "and the tray said: \(voicesSummary(app))")
        shot("transport-all-voices-off")
        app.descendants(matching: .any)["voices-all-on"].firstMatch.tap()
        XCTAssertTrue(waitForVoices(app, contains: "all voices"),
                      "All on did not bring them back: \(voicesSummary(app))")

        // The fader is adjustable, which is also the VoiceOver path.
        let fader = app.descendants(matching: .any)["strip-fader-1"].firstMatch
        XCTAssertTrue(fader.exists, "no fader on the second strip")
        XCTAssertEqual(fader.value as? String, "level 7 of 10", "the default is 7")

        // The scrubber seeks. The bar CHIP that rides above the handle can
        // only exist while a finger is down, and XCUITest runs every gesture
        // on the main thread with no hook inside it -- so what the chip SAYS
        // is proven in MixerLayoutTests (it names a bar, never a time) and
        // what the scrubber DOES is proven here.
        let scrubber = app.descendants(matching: .any)["mixer-scrubber"].firstMatch
        XCTAssertTrue(scrubber.waitForExistence(timeout: 10), "no scrubber")
        let before = app.staticTexts["transport-bar"].label
        scrubber.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5))
            .press(forDuration: 0.2,
                   thenDragTo: scrubber.coordinate(
                       withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5)))
        let moved = NSPredicate(format: "label != %@", before)
        expectation(for: moved, evaluatedWith: app.staticTexts["transport-bar"],
                    handler: nil)
        waitForExpectations(timeout: 20)
        XCTAssertTrue(app.staticTexts["transport-bar"].label.hasPrefix("bar "),
                      "scrubbing did not move the play head")
        shot("mixer-scrubbed")

        // And the tray is STILL THERE, where it was: nothing here opened it
        // and nothing closes it. The window's park and close went with the
        // window (0.8 §7.7).
        let tray = app.otherElements["transport"].firstMatch
        XCTAssertTrue(tray.exists, "the tray went away while its knobs were worked")
        XCTAssertFalse(app.descendants(matching: .any)["mixer-close"].exists,
                       "the tray has a close control: there is nothing to close")
        let window = app.windows.firstMatch.frame
        XCTAssertLessThanOrEqual(tray.frame.maxY, window.maxY + 0.5,
                                 "the tray hangs off the bottom of the screen")
        shot("tray-after-its-knobs-were-worked")

        // Still playing after all of it, and Stop stops it.
        let play = app.buttons["transport-play"]
        XCTAssertEqual(play.label, "Stop", "working the tray stopped playback")
        play.tap()
        XCTAssertTrue(waitUntil("the button to say Play", timeout: 10) { play.label == "Play" },
                      "Stop did not stop it")
    }

    /// The sound each channel is played with: guessed, changed, heard at once,
    /// and put back.
    ///
    /// The product ask this proves, in the arranger's words: a dropdown under
    /// each volume slider, auto-set from the staff name, changeable, and *"it's
    /// common for an arranger to for instance just want to hear every voice on
    /// a piano sound."*
    ///
    /// It is PLAYBACK. Nothing here makes a version, and the assertion at the
    /// end says so: `change-instrument` in the engine is the other thing.
    func testTheMixerChoosesTheSoundAChannelIsPlayedWith() {
        openArrangement(firstArrangement)
        XCTAssertTrue(app.scrollViews["score-canvas"].waitForExistence(timeout: 180),
                      "the score never finished engraving")
        // The timeline, rather than twelve seconds of hoping it had arrived.
        _ = app.descendants(matching: .any)["strip-sound-0"].waitForExistence(timeout: 180)
        let versionsBefore = app.buttons["score-versions"].label
        revealTransport()
        startPlaying()

        func chip(_ index: Int) -> XCUIElement {
            app.descendants(matching: .any)["strip-sound-\(index)"].firstMatch
        }
        XCTAssertTrue(chip(0).waitForExistence(timeout: 180),
                      "no sound label under the first knob")

        // Auto-set, and SAYING it is auto-set: a reader who has never touched
        // a channel has to be able to tell that from one they have.
        let guessed = chip(0).value as? String ?? ""
        XCTAssertTrue(guessed.hasSuffix(", automatic"),
                      "an untouched channel should read as automatic: \(guessed)")

        chip(0).tap()
        let picker = app.descendants(matching: .any)["mixer-picker"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 10), "the sound list did not open")
        // The tray is under it, not gone with it: the way back is the ✕.
        XCTAssertTrue(app.descendants(matching: .any)["mixer-picker-close"]
                        .firstMatch.exists, "no way back to the tray")

        // Families, not 128 rows. The piano family, then the plain piano.
        let family = app.descendants(matching: .any)["picker-family-0"].firstMatch
        XCTAssertTrue(family.waitForExistence(timeout: 10), "no family column")
        family.tap()
        let grand = app.descendants(matching: .any)["picker-instrument-melodic-0"]
            .firstMatch
        XCTAssertTrue(grand.waitForExistence(timeout: 10),
                      "the piano family does not list the plain piano")
        // The largest thing the tray puts up, wholly on screen (was
        // TrayVisibility.testTheSoundPickerIsWhollyOnScreen).
        settle(picker)
        assertInside(picker.frame, app.windows.firstMatch.frame, "picker")
        // Open, the music runs on (was MixerKeepsPlaying).
        XCTAssertEqual(app.buttons["transport-play"].label, "Stop",
                       "opening the sound picker stopped playback")
        shot("mixer-sound-picker-open")
        grand.tap()

        // Live: the transport did not restart to change a sound.
        XCTAssertEqual(app.buttons["transport-play"].label, "Stop",
                       "choosing a sound stopped the music")

        // Every voice on a piano, which is the ask this feature came from.
        app.descendants(matching: .any)["picker-all-staves"].firstMatch.tap()
        app.descendants(matching: .any)["mixer-picker-close"].firstMatch.tap()
        XCTAssertTrue(chip(0).waitForExistence(timeout: 10), "the strips did not come back")
        XCTAssertEqual(app.buttons["transport-play"].label, "Stop",
                       "closing the sound picker stopped playback")
        for index in 0..<4 {
            let value = chip(index).value as? String ?? ""
            XCTAssertTrue(value.hasPrefix("Acoustic Grand Piano"),
                          "strip \(index) is not on the piano: \(value)")
            XCTAssertTrue(value.hasSuffix(", chosen"),
                          "strip \(index) does not read as chosen: \(value)")
        }
        shot("mixer-every-voice-on-a-piano")

        // And every staff back again. A control that changes the whole mixer
        // at once and leaves the reader undoing it a strip at a time is not
        // undoable; this is the inverse of the button above it.
        chip(0).tap()
        XCTAssertTrue(app.descendants(matching: .any)["picker-all-guess"]
                        .firstMatch.waitForExistence(timeout: 10), "no way back")
        app.descendants(matching: .any)["picker-all-guess"].firstMatch.tap()
        app.descendants(matching: .any)["mixer-picker-close"].firstMatch.tap()
        XCTAssertTrue(chip(0).waitForExistence(timeout: 10))
        for index in 0..<4 {
            XCTAssertTrue((chip(index).value as? String ?? "")
                            .hasSuffix(", automatic"),
                          "strip \(index) did not go back to its guess: "
                          + "\(chip(index).value as? String ?? "-")")
        }

        // One staff at a time is still one staff: the per-strip AUTO clears
        // the strip it is on and leaves the others where the reader put them.
        chip(1).tap()
        app.descendants(matching: .any)["picker-family-0"].firstMatch.tap()
        app.descendants(matching: .any)["picker-instrument-melodic-0"].firstMatch.tap()
        app.descendants(matching: .any)["mixer-picker-close"].firstMatch.tap()
        XCTAssertTrue(chip(1).waitForExistence(timeout: 10))
        XCTAssertTrue((chip(1).value as? String ?? "").hasSuffix(", chosen"))
        XCTAssertTrue((chip(0).value as? String ?? "").hasSuffix(", automatic"),
                      "choosing on one strip changed another")
        chip(1).tap()
        app.descendants(matching: .any)["picker-guess"].firstMatch.tap()
        app.descendants(matching: .any)["mixer-picker-close"].firstMatch.tap()
        XCTAssertTrue(chip(1).waitForExistence(timeout: 10))
        XCTAssertTrue((chip(1).value as? String ?? "").hasSuffix(", automatic"),
                      "the second strip did not go back to its guess")

        // None of it was notation. The engine's change-instrument rewrites a
        // part and leaves a version behind; this is the speaker, not the page.
        XCTAssertEqual(app.buttons["score-versions"].label, versionsBefore,
                       "choosing a playback sound made a version")
    }

    /// Paging away from the music during playback, and the way back.
    ///
    /// The chip is invisible whenever the playhead is on the page being
    /// looked at, which is most of the time -- so it can only be proven by
    /// deliberately drifting away from it. That is also the behaviour worth
    /// proving: the music KEEPS PLAYING, the page stays where the reader put
    /// it, and nothing moves under them until they ask.
    func testPagingAwayDuringPlaybackOffersTheWayBack() {
        openArrangement(firstArrangement)
        waitForEngraving(of: firstArrangement)
        revealTransport()
        startPlaying()

        let chip = app.buttons["sync-to-playback"]
        XCTAssertFalse(chip.exists,
                       "nothing to sync to: the playhead is on the visible page")

        // Page a long way from the music, the way a reader looking ahead does.
        let far = app.descendants(matching: .any)["thumb-6"].firstMatch
        XCTAssertTrue(far.waitForExistence(timeout: 20), "no page rail")
        far.tap()

        XCTAssertTrue(chip.waitForExistence(timeout: 20),
                      "paged away from the playhead and was offered no way back")
        // The music did not stop, and the page did not snap back.
        XCTAssertEqual(app.buttons["transport-play"].label, "Stop",
                       "turning a page stopped playback")
        XCTAssertTrue(chip.label.hasPrefix("Back to"),
                      "the chip should name where it will take you: \(chip.label)")
        // Let the page settle before photographing it. The rail and the badge
        // update the moment the tap lands while the canvas is still scrolling,
        // so a shot taken immediately shows the OLD page under a new page
        // number -- a picture that would be read as a bug in the canvas.
        settle(engravedPage, still: 0.5, timeout: 10)
        shot("sync-chip")

        // And it stays away. Following does NOT resume on its own -- being
        // yanked back the moment the music wandered into view is the thing
        // this rule exists to stop.
        XCTAssertTrue(chip.exists, "the page moved back without being asked")

        chip.tap()
        XCTAssertTrue(waitForDisappearance(of: chip, timeout: 20),
                      "tapping Sync did not take the reader back to the music")
        shot("sync-chip-after")
    }
}
