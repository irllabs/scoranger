//  DesignerSweep.swift
//
//  The DESIGN side's screenshot sweep. Forked from VisualSweep.swift on
//  2026-08-29 so the two of us stop editing one file: VisualSweep.swift,
//  InkShot.swift and RowShot.swift belong to the engineer; this one is the
//  QA sweep that feeds the defect batches.
//
//  Run it on its own:
//    xcodebuild test -project Scoranger.xcodeproj -scheme Scoranger \
//      -destination "platform=iOS Simulator,id=<udid>" \
//      -only-testing:ScorangerUITests/DesignerSweep \
//      -resultBundlePath out.xcresult
//    xcrun xcresulttool export attachments --path out.xcresult --output-path shots
//
//  Landscape frames come out of the raw portrait framebuffer; rotate with
//    sips -r -90 <file> --out <file>
//
import XCTest

/// A screenshot sweep, not an assertion suite.
///
/// This exists to CATCH VISUAL DEFECTS: overlaps, clipping, misalignment, bad
/// spacing, things running off screen. It therefore asserts almost nothing and
/// never stops early -- every step is defensive, so one missing control cannot
/// cost the rest of the sweep. The output is the attachments, which are
/// exported with:
///
///   xcrun xcresulttool export attachments --path <result>.xcresult \
///        --output-path <dir>
///
/// Untracked scaffolding for the QA loop; delete it or keep it, but it is not
/// part of the shipped test suite's contract.
final class DesignerSweep: XCTestCase {
    /// Put the device back. These sweeps rotate to photograph landscape, and a
    /// device left rotated silently changes the FIT for every geometry test
    /// that runs after them -- in landscape the page is height-bound, so a
    /// zoom test measures a page a third the width it expects and fails for a
    /// reason that has nothing to do with the code under test.
    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }

    var app: XCUIApplication!

    /// Which way up this test sweeps. Set at the top of each test: passing
    /// `TEST_RUNNER_…` on the xcodebuild command line sets a BUILD SETTING, not
    /// the runner's environment, so an env-driven version silently swept
    /// landscape twice.
    private var wanted: UIDeviceOrientation = .landscapeLeft
    private var tag: String { wanted == .portrait ? "P" : "L" }

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    // MARK: - helpers

    private func launch(_ arguments: [String]) {
        app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
        XCUIDevice.shared.orientation = wanted
        Thread.sleep(forTimeInterval: 1.0)
        // §4C: the app opens on My Library and there is no tab bar. Fall back to
        // the old chrome while the merge is in flight, so the sweep runs against
        // either build.
        if !app.textFields["library-search"].waitForExistence(timeout: 120) {
            _ = app.searchFields["library-search"].waitForExistence(timeout: 30)
        }
    }

    private func snap(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "\(tag)-\(name)"
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Tap by identifier if it is there; report what was missing so the sweep
    /// log says why a screenshot is absent.
    /// Typed queries only. `descendants(matching: .any)` walks every element in
    /// a SwiftUI tree; on this app it grew the runner until the system killed
    /// it, which is what "Test crashed with signal kill" was.
    private func candidates(_ id: String) -> [XCUIElement] {
        [app.buttons[id], app.otherElements[id], app.staticTexts[id],
         app.textFields[id], app.images[id], app.scrollViews[id]]
    }

    @discardableResult
    private func tap(_ id: String, wait: TimeInterval = 4) -> Bool {
        for element in candidates(id) where element.exists && element.isHittable {
            element.tap()
            return true
        }
        // not there yet: wait once on the likeliest kind, then retry the rest
        if app.buttons[id].waitForExistence(timeout: wait) {
            for element in candidates(id) where element.exists && element.isHittable {
                element.tap()
                return true
            }
        }
        print("SWEEP: no element \(id)")
        return false
    }

    @discardableResult
    private func tapFirst(beginning prefix: String, wait: TimeInterval = 8) -> String? {
        let predicate = NSPredicate(format: "identifier BEGINSWITH %@", prefix)
        for query in [app.buttons, app.otherElements, app.staticTexts] {
            let match = query.matching(predicate).firstMatch
            if match.waitForExistence(timeout: wait), match.isHittable {
                let id = match.identifier
                match.tap()
                return id
            }
        }
        print("SWEEP: nothing beginning \(prefix)")
        return nil
    }

    private func back() { tap("screen-back", wait: 2) }

    /// Into performance mode by whichever route this width offers: the top
    /// bar's button, or the Options row the bar yields to on a phone (0.6.8).
    @discardableResult
    private func enterPerformanceMode() -> Bool {
        if tap("score-performance", wait: 3) { return true }
        guard tap("score-more", wait: 3) else { return false }
        settle(0.8)
        return tap("more-performance", wait: 3)
    }

    /// Put the keyboard away.
    ///
    /// Tapping the search field raises it, and on iPad it then covers the
    /// control the next step wants — so every screenshot after that was the
    /// same score sitting behind a keyboard (#59).
    private func dismissKeyboard() {
        guard app.keyboards.count > 0 else { return }
        for label in ["Hide keyboard", "dismiss", "Dismiss"] {
            let key = app.keyboards.buttons[label]
            if key.exists && key.isHittable { key.tap(); settle(0.5); return }
        }
        // last resort: the canvas centre, which is the one zone that turns no page
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).tap()
        settle(0.5)
    }

    /// Get back to the library from wherever the last step left us.
    ///
    /// Written because the sweep drifted: a `back()` that missed left it on a
    /// set list screen, the next "first row-menu" tapped a MEMBER's menu, and
    /// every screenshot after that was of the wrong place. This asserts the
    /// destination instead of assuming it.
    private func toLibrary(_ context: String = "") {
        dismissKeyboard()
        for _ in 0..<4 {
            if app.textFields["library-search"].exists { return }
            if app.buttons["score-close"].exists { app.buttons["score-close"].tap() }
            else if app.buttons["screen-back"].exists { app.buttons["screen-back"].tap() }
            settle(0.6)
        }
        if !app.textFields["library-search"].exists {
            print("SWEEP: could not get back to the library \(context)")
        }
    }

    /// A second piece, made through the UI, so the library has both a
    /// multi-arrangement piece and a single-arrangement one -- and so a row tap
    /// is not the only way into a piece screen.
    private func makeSecondPiece(named name: String) {
        toLibrary("before making a piece")
        guard tap("library-new", wait: 4) else { return }
        settle(0.8)
        let field = app.textFields["inline-rename-field"]
        if field.waitForExistence(timeout: 3) {
            field.tap(); field.typeText(name)
            if !tap("inline-rename-save", wait: 2) { app.keyboards.buttons["return"].tap() }
            settle(2.0)
        } else {
            print("SWEEP: no inline-rename-field for the new piece")
        }
        toLibrary("after making a piece")
    }

    /// The seeded import is slow and finishes on the library, which is where
    /// every sweep starts now. Waiting on the ROW is what waits for the seed.
    private func waitForSeed() {
        let row = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "row-")).firstMatch
        if !row.waitForExistence(timeout: 240) {
            print("SWEEP: the seeded library never appeared")
        }
        settle(0.8)
    }

    private func settle(_ seconds: TimeInterval = 0.6) {
        Thread.sleep(forTimeInterval: seconds)
    }

    // MARK: - 1. library, screens, management

    func testSweepLibrary() {
        launch(["-resetLibrary", "-seedTestLibrary"])
        waitForSeed()
        snap("01-library-pieces")
        tap("library-search"); settle(); snap("02-library-search-focused")
        dismissKeyboard()

        tap("library-sort"); settle(); snap("04-library-sort-open")
        tap("library-sort"); settle()
        tap("library-filter"); settle(); snap("05-library-filter-open")
        tap("library-filter"); settle()

        tap("library-add"); settle(); snap("06-library-add-band")
        tap("library-add"); settle()

        tap("library-edit"); settle(); snap("07-library-edit-mode")
        if let sel = tapFirst(beginning: "row-select-") {
            print("SWEEP: selected \(sel)")
            settle(); snap("08-library-edit-selected-actionbar")
        }
        tap("library-edit"); settle()

        tap("segment-setlists"); settle(); snap("09-library-setlists")
        tap("library-edit"); settle(); snap("10-library-setlists-edit")
        tap("library-edit"); settle()

        // a set list screen, its members and a member's expanded row
        if tapFirst(beginning: "row-") != nil {
            settle(1.0); snap("11-setlist-screen")
            tapFirst(beginning: "setlist-member-"); settle(); snap("12-setlist-member-open")
        }
        toLibrary("after the set list")
        tap("segment-pieces"); settle()

        makeSecondPiece(named: "Demo piece for the sweep")
        snap("03-library-two-pieces")

        // piece screen: the ROW opens the music, so management is reached
        // through the row's hamburger -- from the LIBRARY, asserted.
        toLibrary("before the piece screen")
        if let menu = tapFirst(beginning: "row-menu-") {
            print("SWEEP: hamburger \(menu)")
            settle(1.2); snap("13-piece-screen")
            app.swipeUp(); settle(); snap("14-piece-screen-scrolled")
            app.swipeDown(); settle()

            // inline rename on the piece title
            tap("piece-title"); settle(); snap("15-piece-title-editing")
            tap("inline-rename-cancel"); settle()

            // arrangement screen: from the piece screen, its arrangement rows
            // carry their own hamburger
            if tapFirst(beginning: "row-menu-") == nil {
                tapFirst(beginning: "arrangement-choice-")
            }
            settle(1.2); snap("16-arrangement-screen")

            tap("arrangement-title"); settle(); snap("17-arrangement-title-editing")
            tap("inline-rename-cancel"); settle()

            if tapFirst(beginning: "arrangement-move-") != nil {
                settle(); snap("18-move-to-piece"); back(); settle()
            }
            if tapFirst(beginning: "arrangement-setlists-") != nil {
                settle(); snap("19-setlists-for"); back(); settle()
            }
            if tapFirst(beginning: "edit-versions-") != nil {
                settle(); snap("20-versions"); back(); settle()
            }
            if tapFirst(beginning: "arrangement-parts-") != nil {
                settle(); snap("21-parts"); back(); settle()
            }
            // Delete is a swipe to the left now, which uncovers the red trash
            // button; there is no confirm strip after it. The LAST row,
            // because the first one's ☰ is open and an open row does not swipe.
            let rows = app.buttons.matching(
                NSPredicate(format: "identifier BEGINSWITH %@", "arrangement-choice-"))
            if rows.count > 0, rows.element(boundBy: rows.count - 1).isHittable {
                rows.element(boundBy: rows.count - 1).swipeLeft()
                settle(); snap("22-delete-swipe-revealed")
                if tapFirst(beginning: "edit-delete-") != nil {
                    settle(1.0); snap("23-undo-bar")
                    tap("undo-delete"); settle()
                }
            }
            back(); settle()
        }

        // settings, from Home
        toLibrary("before settings")
        if !tap("library-settings", wait: 4) { tap("home-settings") }
        settle(1.4); snap("24-settings")
        // batch-1 #2: with the on-device engine OFF the chip and the LED must
        // say REMOTE, not "on-device"
        let engine = app.switches["Use on-device engine"]
        if engine.waitForExistence(timeout: 3) {
            engine.tap(); settle(1.4); snap("26-settings-remote-engine")
            engine.tap(); settle(0.8)
        } else {
            print("SWEEP: no engine toggle")
        }
        app.swipeUp(); settle(); snap("25-settings-scrolled")
        toLibrary("after settings")
    }

    /// Portrait twin: the same walk, the other size class. The layout defects
    /// that matter (row collisions, band heights, clipping) are exactly the ones
    /// that only show up when the column narrows.
    func testSweepLibraryPortrait() {
        wanted = .portrait
        testSweepLibrary()
    }

    func testSweepScoreViewPortrait() {
        wanted = .portrait
        testSweepScoreView()
    }

    func testSweepEdgeStatesPortrait() {
        wanted = .portrait
        testSweepEdgeStates()
    }

    func testSweepSelectionPortrait() {
        wanted = .portrait
        testSweepSelection()
    }

    // MARK: - 2. the score view

    func testSweepScoreView() {
        launch(["-resetLibrary", "-seedTestLibrary"])
        waitForSeed()
        tapFirst(beginning: "row-"); settle(1.0)
        // a piece with several arrangements lands on the piece screen first
        if app.buttons["score-title"].waitForExistence(timeout: 3) == false {
            tapFirst(beginning: "arrangement-choice-")
        }
        _ = app.buttons["score-title"].waitForExistence(timeout: 60)
        settle(2.5)  // let the engraving arrive
        snap("30-score-reading")

        tap("score-title"); settle(); snap("31-title-switcher-band")
        tap("score-title"); settle()

        tap("score-spread"); settle(2.5); snap("32-score-two-page-spread")

        tap("score-more"); settle(); snap("33-score-options")
        if tapFirst(beginning: "display-") != nil {
            settle(); snap("34-score-options-subscreen"); back(); settle()
        }
        // Performance mode is a TOP BAR button since 0.6.8, so leave Options
        // first. `more-performance` is the phone-width fallback and stays as
        // the second attempt.
        back(); settle(0.6)
        if !tap("score-performance", wait: 3) {
            tap("score-more", wait: 3); settle(0.6); tap("more-performance", wait: 3)
        }
        settle(1.2); snap("35-performance-mode")
        tap("score-close"); settle(0.8)

        tap("score-ask"); settle(1.0); snap("36-chat-open")
        tap("chat-input"); settle(); snap("37-chat-input-focused")
        tap("score-ask"); settle()

        tap("score-edit"); settle(1.0); snap("38-edit-ink-mode")
        tap("score-edit"); settle()

        tap("score-spread"); settle(2.0)
        if app.otherElements["thumbnail-strip"].exists {
            snap("39-thumbnail-strip")
        }
        tapFirst(beginning: "thumb-"); settle(1.2); snap("40-after-thumbnail-jump")
    }

    // MARK: - 3. selection chip and the chord adjust row

    func testSweepSelection() {
        launch(["-resetLibrary", "-seedTestLibrary", "-seedChordChart",
                "-annotateWithFinger", "-uiTestPencil"])
        waitForSeed()
        tapFirst(beginning: "row-"); settle(1.0)
        if app.buttons["score-title"].waitForExistence(timeout: 3) == false {
            tapFirst(beginning: "arrangement-choice-")
        }
        _ = app.buttons["score-title"].waitForExistence(timeout: 60)
        settle(3.0)
        snap("50-chord-chart-reading")

        // a finger stands in for the Pencil: drag a small lasso over the music
        let canvas = app.scrollViews.firstMatch.exists
            ? app.scrollViews.firstMatch : app.windows.firstMatch
        let start = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.34, dy: 0.30))
        let end = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.52, dy: 0.42))
        start.press(forDuration: 0.15, thenDragTo: end)
        settle(1.5)
        snap("51-selection-chip")
        if app.otherElements["adjust-size"].exists || app.buttons["adjust-size"].exists {
            snap("52-selection-adjust-row")
            tapFirst(beginning: "adjust-"); settle(0.8); snap("53-adjust-pending")
        }
    }

    // MARK: - 3b. accessibility of the empty state and the action row

    /// Two fixes to check: a composite view with an identifier was swallowing
    /// its children, and the disabled Ask button reported as enabled while grey.
    func testAccessibilityAudit() {
        launch(["-resetLibrary"])
        settle(1.5)
        snap("70-a11y-empty-library")

        var lines: [String] = []
        // #47 took Ask out of the action row. Reading `.label` off an element
        // that does not exist THROWS and fails the whole audit, so probe first.
        let ask = app.buttons["library-ask"]
        lines.append(ask.exists
            ? "library-ask enabled=\(ask.isEnabled) hittable=\(ask.isHittable) label=\(ask.label)"
            : "library-ask — absent (removed in #47)")
        for id in ["library-import", "library-new",
                   "library-edit", "library-sort", "library-filter",
                   "library-settings", "library-empty", "build-stamp"] {
            let e = app.descendants(matching: .any)[id]
            lines.append(e.exists
                ? "\(id) enabled=\(e.isEnabled) label=\(e.label)"
                : "\(id) — absent")
        }
        // does the empty state expose its own text, or does one identifier
        // swallow the children?
        let texts = app.staticTexts.allElementsBoundByIndex.prefix(12).map {
            "text: \($0.identifier.isEmpty ? "-" : $0.identifier) | \($0.label)"
        }
        lines.append(contentsOf: texts)

        let report = XCTAttachment(string: lines.joined(separator: "\n"))
        report.name = "\(tag)-71-a11y-report"
        report.lifetime = .keepAlways
        add(report)
        print("SWEEP A11Y:\n" + lines.joined(separator: "\n"))
    }

    // MARK: - 3c. whistle fingerings (#8 centring, #43 shared baseline)

    /// The fixture is a MusicXML with `wf` lyric verses, produced by
    /// `scor whistle-fingerings` and dropped into the app's own `Documents/inbox`
    /// before the run. No `-resetLibrary`: that is what would throw the file away.
    func testSweepWhistle() {
        launch(["-seedTestLibrary"])
        waitForSeed()
        toLibrary("before the whistle score")
        // the imported file lands as its own piece
        // The import is named from the NOTATION's title, not the file -- which
        // is L18's guard doing its job -- so the fixture lands as "Demo in G".
        let whistle = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@ AND (label CONTAINS %@ OR label CONTAINS %@)",
                        "row-", "Demo", "Whistle")).firstMatch
        if !whistle.waitForExistence(timeout: 180) {
            print("SWEEP: the whistle fixture never imported")
            snap("80-whistle-missing")
            return
        }
        snap("80-whistle-in-library")
        whistle.tap()
        settle(1.0)
        if app.buttons["score-title"].waitForExistence(timeout: 60) == false {
            tapFirst(beginning: "row-menu-")
            tapFirst(beginning: "arrangement-open")
        }
        _ = app.buttons["score-title"].waitForExistence(timeout: 90)
        settle(3.5)
        snap("81-whistle-score")
        // zoomed in, so the "+" and the circle column can actually be judged
        let canvas = app.scrollViews.firstMatch
        if canvas.exists {
            canvas.pinch(withScale: 3.0, velocity: 1.5)
            settle(2.5)
            snap("82-whistle-zoomed")
        }
    }

    func testSweepWhistlePortrait() {
        wanted = .portrait
        testSweepWhistle()
    }


    // MARK: - 5. the 0.5.0 bundle: layout control, version jump, #60, marks

    /// The three-way page/spread/continuous control, and the close button that
    /// #60 lost on compact width.
    func testSweepLayoutControl() {
        launch(["-resetLibrary", "-seedTestLibrary"])
        waitForSeed()
        openFirstScore()
        settle(2.5)

        // #60 guard, stated as a finding rather than an assertion so the sweep
        // never stops early
        let close = app.buttons["score-close"]
        print("SWEEP #60: score-close exists=\(close.exists) hittable=\(close.exists && close.isHittable)")
        snap("90-score-bar-close-check")

        for option in ["page", "spread", "continuous"] {
            if tap("layout-\(option)", wait: 3) {
                settle(2.5)
                snap("91-layout-\(option)")
            } else if tap("score-layout", wait: 2) {
                settle(0.8)
                _ = tap("layout-\(option)", wait: 2)
                settle(2.5)
                snap("91-layout-\(option)")
            } else {
                print("SWEEP: no layout control for \(option)")
            }
        }
        // continuous is the interesting one: scroll it and see the strip's fate
        if tap("layout-continuous", wait: 2) {
            settle(2.0)
            app.swipeLeft(); settle(1.2); snap("92-continuous-scrolled")
            print("SWEEP: strip present in continuous = \(app.otherElements["thumbnail-strip"].exists)")
        }
        // and it must not survive into performance mode. The switch is a bar
        // button since 0.6.8; the Options row is the phone-width fallback.
        if enterPerformanceMode() {
            settle(1.5); snap("93-performance-no-layout-control")
            print("SWEEP: layout control in performance = \(app.otherElements["score-layout"].exists || app.buttons["layout-page"].exists)")
            tap("score-close", wait: 2)
        }
    }

    /// Version jump from the score bar, then again from performance mode.
    func testSweepVersionJump() {
        launch(["-resetLibrary", "-seedTestLibrary"])
        waitForSeed()
        openFirstScore()
        settle(2.5)
        if tap("score-versions", wait: 4) || tap("more-versions", wait: 2) {
            settle(1.0); snap("94-version-dropdown")
            if tapFirst(beginning: "version-") != nil {
                settle(3.0); snap("95-after-version-jump")
            }
            // no loop: the menu must be gone once a version is chosen
            print("SWEEP: dropdown still open after jump = \(app.buttons["menu-all-versions"].exists)")
        } else {
            print("SWEEP: no version control in the score bar")
        }
        if enterPerformanceMode() {
            settle(1.2)
            if tap("score-versions", wait: 3) { settle(1.0); snap("96-version-dropdown-performance") }
            else { print("SWEEP: no version control in performance mode") }
        }
    }

    /// Rehearsal marks A/B and a coloured accidental, both written by the
    /// engine into a fixture that arrives through the app's own inbox.
    func testSweepMarksAndAccidentals() {
        launch(["-seedTestLibrary"])
        waitForSeed()
        toLibrary("before the bundle fixture")
        let fixture = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@ AND (label CONTAINS %@ OR label CONTAINS %@)",
                        "row-", "QA Bundle", "Demo")).firstMatch
        guard fixture.waitForExistence(timeout: 180) else {
            print("SWEEP: the bundle fixture never imported"); snap("97-fixture-missing"); return
        }
        fixture.tap(); settle(1.0)
        if !app.buttons["score-title"].waitForExistence(timeout: 60) {
            tapFirst(beginning: "row-menu-"); tapFirst(beginning: "arrangement-open")
        }
        _ = app.buttons["score-title"].waitForExistence(timeout: 90)
        settle(3.5)
        snap("97-rehearsal-and-accidental")
        let canvas = app.scrollViews.firstMatch
        if canvas.exists { canvas.pinch(withScale: 3.0, velocity: 1.5); settle(2.5); snap("98-marks-zoomed") }
    }

    /// Open whatever the first library row leads to, score view either way.
    private func openFirstScore() {
        tapFirst(beginning: "row-")
        settle(1.2)
        if !app.buttons["score-title"].waitForExistence(timeout: 5) {
            tapFirst(beginning: "arrangement-open") ?? tapFirst(beginning: "arrangement-choice-")
        }
        _ = app.buttons["score-title"].waitForExistence(timeout: 90)
    }


    // MARK: - 6. characterisation: is the continuous band a flash or a fault?

    /// The engineer could not reproduce the squished continuous strip and needs
    /// one thing above all: does it PERSIST, or settle after a beat? So this
    /// shoots the same state at first render, after settling, after a scroll,
    /// after a rotation, and after a close/reopen -- three times over -- and
    /// prints the geometry each time so the answer is measured, not eyeballed.
    func testCharacteriseContinuous() {
        launch(["-resetLibrary", "-seedTestLibrary"])
        waitForSeed()
        openFirstScore()
        settle(2.5)

        for pass in 1...3 {
            _ = tap("layout-page", wait: 3); settle(1.5)
            _ = tap("layout-continuous", wait: 3)
            snap("A\(pass)-continuous-first-render")     // no settle: catch the flash
            report("pass \(pass) first render")
            settle(3.0)
            snap("A\(pass)-continuous-settled")
            report("pass \(pass) after 3s")
            app.swipeLeft(); settle(1.5)
            snap("A\(pass)-continuous-after-scroll")
            report("pass \(pass) after scroll")
        }

        // rotation
        wanted = (wanted == .portrait) ? .landscapeLeft : .portrait
        XCUIDevice.shared.orientation = wanted; settle(3.0)
        snap("A4-continuous-after-rotate")
        report("after rotate")

        // close and reopen
        _ = tap("score-close", wait: 3); settle(1.5)
        openFirstScore(); settle(2.5)
        _ = tap("layout-continuous", wait: 3); settle(3.0)
        snap("A5-continuous-after-reopen")
        report("after reopen")
    }

    /// #62, the engineer's way: the compact route is `…` -> Versions, not a bar
    /// control. Walk it and see whether a version can actually be switched.
    func testVersionsViaMoreMenu() {
        launch(["-resetLibrary", "-seedTestLibrary"])
        waitForSeed()
        openFirstScore()
        settle(2.5)
        snap("B1-score-bar")
        guard tap("score-more", wait: 4) else {
            print("SWEEP: no score-more button"); return
        }
        settle(1.2); snap("B2-options-screen")
        guard tap("more-versions", wait: 3) else {
            print("SWEEP: no Versions row in the options screen"); snap("B3-no-versions-row"); return
        }
        settle(1.5); snap("B3-versions-list")
        let before = app.buttons["score-title"].label
        if let picked = tapFirst(beginning: "version-") {
            settle(3.5); snap("B4-after-version-switch")
            print("SWEEP #62: picked \(picked); title before=\(before) after=\(app.buttons["score-title"].label)")
        } else {
            print("SWEEP #62: versions list held no version- rows")
        }
    }

    /// Canvas geometry, printed: what is drawn, and how much of the canvas it uses.
    private func report(_ label: String) {
        let win = app.windows.firstMatch.frame
        let scroll = app.scrollViews.firstMatch
        var line = "SWEEP GEOM [\(label)] window=\(Int(win.width))x\(Int(win.height))"
        if scroll.exists {
            let f = scroll.frame
            line += " scroll=\(Int(f.width))x\(Int(f.height))@\(Int(f.minY))"
        }
        let images = app.images.allElementsBoundByIndex.prefix(4).map {
            "\(Int($0.frame.width))x\(Int($0.frame.height))@\(Int($0.frame.minY))"
        }
        line += " images=[\(images.joined(separator: ", "))]"
        print(line)
    }

    // MARK: - 4. empty and long-content states

    func testSweepEdgeStates() {
        launch(["-resetLibrary"])
        settle(1.5)
        snap("60-home-empty")
        settle(1.0); snap("61-library-empty")
        tap("segment-setlists"); settle(); snap("62-setlists-empty")
        tap("segment-pieces"); settle()

        // long content: seed, then give something a very long name
        app.terminate()
        launch(["-seedTestLibrary"])
        waitForSeed()
        tapFirst(beginning: "row-"); settle(1.2)
        if tap("piece-title", wait: 3) {
            let field = app.textFields["inline-rename-field"]
            if field.waitForExistence(timeout: 3) {
                field.tap()
                field.typeText(" — Concerto grosso in D minor for two violins, "
                             + "strings and continuo, arranged for accordion duo")
                settle(); snap("63-long-title-editing")
                tap("inline-rename-save"); settle(1.5)
                snap("64-long-title-piece-screen")
                tap("screen-back"); settle(1.0)
                snap("65-long-title-library-row")
            }
        }
    }
}
