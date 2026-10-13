import XCTest

/// The library's action row, on a phone.
///
/// Ali on 0.6.14 b173: the row is clipped at BOTH edges. The import arrow is
/// half off the left, and "Sort: name", the filter icon and the Edit tick run
/// off the right. It is the same class of failure §6.1 and §6.3 fixed on the
/// score screen -- a row that is told how wide it may be, does not fit, and
/// spills over both edges rather than yielding -- in the one place that work
/// did not touch.
///
/// `LibraryActionRow` has no yield order at all. Its only concession to width
/// is `isCompact`, which turns labels into icons below 700pt; below that there
/// is nothing left to give, and 393pt is far below it.
///
/// Asked with `assertFitsOnScreen`, the same window-relative check the
/// selection chip and the Dynamic Type sweep use.
final class LibraryToolbarFits: XCTestCase {

    /// The row as it is drawn now: two verbs, then the list's own controls.
    private static let row = [
        "library-import", "library-new",
        "library-sort", "library-filter", "library-edit",
    ]

    private func snap(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func openLibrary(_ app: XCUIApplication) -> Bool {
        let search = app.descendants(matching: .any)["library-search"]
        guard search.waitForExistence(timeout: 240) else { return false }
        settle(search, still: 0.8)
        return true
    }

    /// 1. NOTHING LEAVES THE WINDOW (§14.5).
    ///
    /// The reported bug as one assertion, asked with the same window-relative
    /// check the selection chip and the Dynamic Type sweep use. It failed
    /// before the fix with the import icon 8.0pt off the left and the Edit
    /// tick 8.0pt off the right of a 402pt screen.
    func testTheActionRowFitsThePhone() {
        let app = XCUIApplication()
        app.launchArguments = ["-resetLibrary", "-seedTestLibrary"]
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        guard openLibrary(app) else { return XCTFail("the library never appeared") }
        snap("library-action-row")

        // Printed whether it passes or fails: a row 42pt too wide and a row
        // 2pt too wide are the same assertion and very different problems.
        let window = app.windows.firstMatch.frame
        var report = ["window \(Int(window.width))pt"]
        for id in Self.row {
            let element = app.descendants(matching: .any)[id].firstMatch
            guard element.exists else { report.append("\(id) MISSING"); continue }
            let f = element.frame
            report.append(String(format: "%@ x=%.1f…%.1f w=%.1f", id,
                                 f.minX, f.maxX, f.width))
        }
        let text = XCTAttachment(string: report.joined(separator: "\n"))
        text.name = "library-row-frames"
        text.lifetime = .keepAlways
        add(text)
        print("LIBROW\n" + report.joined(separator: "\n") + "\nENDLIBROW")

        assertFitsOnScreen(Self.row, in: app, context: "library action row")
        assertNotTruncated(Self.row, in: app, context: "library action row")

        // And under the LONGEST sort, which §14.1 measured at 138pt over. The
        // row overflowed under one sort and not another, so a fix that held
        // only for the sort that happens to be selected would be no fix.
        app.descendants(matching: .any)["library-sort"].firstMatch.tap()
        let longest = app.descendants(matching: .any)["sort-arrangements"].firstMatch
        guard longest.waitForExistence(timeout: 20) else {
            return XCTFail("the sort band did not open")
        }
        longest.tap()
        settle(app.descendants(matching: .any)["library-sort"].firstMatch, still: 0.6)
        snap("library-action-row-longest-sort")
        assertFitsOnScreen(Self.row, in: app,
                           context: "library row, arrangement-count sort")
    }

    /// 2. EVERY ACTION SURVIVES (§14.5).
    ///
    /// Five actions became two buttons and NONE was removed -- §14.3 is
    /// explicit. Each is one tap further in, inside its verb's band, and this
    /// follows that tap rather than assuming it.
    func testEveryActionIsStillReachable() {
        let app = XCUIApplication()
        app.launchArguments = ["-resetLibrary", "-seedTestLibrary"]
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        guard openLibrary(app) else { return XCTFail("the library never appeared") }

        app.descendants(matching: .any)["library-import"].firstMatch.tap()
        for id in ["library-import-score", "library-import-photos",
                   "library-import-folder", "library-import-book",
                   "library-import-search"] {
            let element = app.descendants(matching: .any)[id].firstMatch
            XCTAssertTrue(element.waitForExistence(timeout: 20),
                          "\(id) is not in the Import band")
            XCTAssertTrue(element.isHittable, "\(id) is present but not tappable")
        }
        snap("library-import-band")
        assertFitsOnScreen(["library-import-score", "library-import-photos",
                            "library-import-folder", "library-import-book",
                            "library-import-search"],
                           in: app, context: "import band")

        // New CLOSES Import: it creates rather than offering (0.8.2 item 13),
        // and the band it used to open is gone, but one panel state at a time
        // still holds.
        app.descendants(matching: .any)["library-new"].firstMatch.tap()
        let field = app.textFields["inline-rename-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 20),
                      "New did not raise the naming row")
        XCTAssertFalse(app.descendants(matching: .any)["library-import-book"]
                        .firstMatch.exists,
                       "the Import band stayed open when New created")
        snap("library-new-naming-row")
        assertFitsOnScreen(["inline-rename-field", "inline-rename-cancel",
                            "inline-rename-save"], in: app, context: "naming row")
    }
}
