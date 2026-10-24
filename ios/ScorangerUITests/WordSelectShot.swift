import XCTest

/// A WORD is selectable like any other mark, resizes on the iPad's own page,
/// and moves to another note (0.21.0).
///
/// Built on MarkAdjustShot's pattern, for MarkAdjustShot's reason: which bars a
/// synthetic pinch leaves on screen is not the same twice, so the taps search
/// rather than aim. What it ASSERTS is what is true once a word is caught: the
/// row offers a size and no position -- a word sits under its note, and the
/// engine refuses an offset on one -- and the place row offers Move. A chord
/// symbol on the same page has a position row, which is how a word is told
/// from it here.
final class WordSelectShot: XCTestCase {

    private var app: XCUIApplication!

    private func snap(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func settle(_ seconds: TimeInterval = 0.6) {
        Thread.sleep(forTimeInterval: seconds)
    }

    private func openTheScore() -> Bool {
        _ = app.descendants(matching: .any)["library-search"].waitForExistence(timeout: 240)
        let row = waitForTheSeededPiece(app, timeout: 300)
        guard row.exists else { return false }
        row.tap()
        openWhicheverArrives(app)
        return app.buttons["score-title"].waitForExistence(timeout: 300)
    }

    private func zoomIn() {
        func read() -> Double {
            Double((app.scrollViews["score-canvas"].value as? String ?? "")
                .replacingOccurrences(of: "zoom ", with: "")) ?? 0
        }
        var zoom = 0.0
        for _ in 1...4 {
            app.scrollViews["score-canvas"].pinch(withScale: 12, velocity: 5)
            settle(1.2)
            zoom = read()
            if zoom >= 2.2 { break }
        }
        for _ in 1...6 where zoom > 2.9 {
            app.scrollViews["score-canvas"].pinch(withScale: 0.7, velocity: -3)
            settle(1.0)
            let now = read()
            if now < 2.2 { break }
            zoom = now
        }
    }

    private func clearSelection() {
        let clear = app.buttons["Clear selection"].firstMatch
        if clear.exists { clear.tap(); settle(0.3) }
    }

    /// Tap about the page until one tap catches a word: a mark with a size
    /// row and no position row.
    private func selectAWord() -> Bool {
        let size = app.descendants(matching: .any)["adjust-size"]
        let up = app.descendants(matching: .any)["adjust-up"]
        // Rows fine and columns coarse: a word is a short, wide target set
        // in a line, and every tap costs a second. LyricSelectionTests proves
        // a tap on a word selects it; this only has to find one to photograph.
        for row in stride(from: 0.30, through: 0.90, by: 0.015) {
            for column in [0.55, 0.74, 0.93] {
                app.windows.firstMatch.coordinate(
                    withNormalizedOffset: CGVector(dx: column, dy: row)).tap()
                settle(0.3)
                if size.exists && !up.exists {
                    print("WORD-SHOT caught a word at \(column),\(row)")
                    return true
                }
                clearSelection()
            }
        }
        return false
    }

    func testAWordIsSelectedResizedAndMoved() {
        app = XCUIApplication()
        app.launchArguments = ["-resetLibrary", "-seedTestLibrary", "-seedWordChart",
                               "-geometryProbe"]
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        guard openTheScore() else { return XCTFail("the score never opened") }
        let canvas = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "canvas-"))
            .firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 300), "no engraved canvas")
        settle(3.0)
        let seeded = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "seed[words:")).firstMatch
        if seeded.waitForExistence(timeout: 30) {
            XCTAssertTrue(seeded.label.contains("seed[words:ok]"), seeded.label)
        }
        snap("00-the-word-chart")
        zoomIn()
        for _ in 1...4 { app.scrollViews["score-canvas"].swipeRight(); settle(0.4) }
        for _ in 1...4 { app.scrollViews["score-canvas"].swipeDown(); settle(0.4) }
        settle(1.0)
        snap("01-zoomed")

        XCTAssertTrue(selectAWord(), "no tap on the page caught a word")
        snap("02-a-word-selected")
        XCTAssertFalse(app.descendants(matching: .any)["adjust-up"].exists,
                       "a word has no position row")
        XCTAssertTrue(app.descendants(matching: .any)["adjust-move"].firstMatch.exists,
                      "a word can be moved to another note")

        app.descendants(matching: .any)["adjust-bigger"].firstMatch.tap()
        settle(0.6)
        app.descendants(matching: .any)["adjust-bigger"].firstMatch.tap()
        // the row commits after three seconds idle, then the page re-engraves
        settle(9.0)
        snap("03-the-word-bigger-on-the-ipads-own-page")

        let move = app.descendants(matching: .any)["adjust-move"].firstMatch
        guard move.exists else { return snap("04-no-place-row") }
        move.tap(); settle(0.6)
        snap("04-move-asks-for-a-bar")
        // The next bar along, where the seeded words leave the note free; its
        // note starts on beat two, so the offset is stepped there (0.5 a step)
        app.windows.firstMatch.coordinate(
            withNormalizedOffset: CGVector(dx: 0.72, dy: 0.5)).tap()
        settle(0.8)
        let later = app.buttons["An eighth note later"].firstMatch
        if later.exists { later.tap(); settle(0.4); later.tap(); settle(0.6) }
        snap("05-a-bar-is-tapped")
        let confirm = app.descendants(matching: .any)["place-confirm"].firstMatch
        if confirm.exists { confirm.tap(); settle(10.0) }
        snap("06-after-the-move")
    }
}
