import XCTest

/// Search (0.20.0): a tune looked up by name on thesession.org, its settings
/// read, one imported. Driven against the site's captured answers
/// (`-stubTheSession`), so the gate never asks the live site.
final class SearchTunes: XCTestCase {

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

    private func openSearch() {
        app = XCUIApplication()
        app.launchArguments = ["-resetLibrary", "-seedTestLibrary", "-stubTheSession"]
        app.launch()
        let importVerb = element("library-import")
        XCTAssertTrue(importVerb.waitForExistence(timeout: 240), "the library never appeared")
        importVerb.tap()
        let search = element("library-import-search")
        XCTAssertTrue(search.waitForExistence(timeout: 20), "Search is not in the Import band")
        search.tap()
        XCTAssertTrue(element("search-field").waitForExistence(timeout: 20),
                      "the Search screen did not open")
    }

    func testATuneIsFoundReadAndImported() {
        openSearch()
        XCTAssertTrue(element("search-empty").exists)
        // both sources ticked by default
        XCTAssertTrue(element("search-source-thesession").isSelected)
        XCTAssertTrue(element("search-source-musescore").isSelected)
        snap("search-empty")

        element("search-field").tap()
        element("search-field").typeText("drowsy maggie")
        element("search-go").tap()
        let count = element("search-count")
        XCTAssertTrue(count.waitForExistence(timeout: 30), "no results came back")
        XCTAssertEqual(count.label, "51 tunes")
        XCTAssertTrue(element("search-hit-1").exists)
        XCTAssertTrue(element("search-musescore-open").exists, "MuseScore's door is missing")
        XCTAssertTrue(element("search-more").exists, "six pages, so More")
        snap("search-results")

        element("search-hit-1").tap()
        let tune = element("search-tune")
        XCTAssertTrue(tune.waitForExistence(timeout: 30), "the tune did not open")
        XCTAssertTrue(app.staticTexts["Drowsy Maggie"].firstMatch.exists)
        XCTAssertTrue(element("search-setting-1").exists)
        XCTAssertTrue(app.staticTexts["Setting 1 · E dorian"].exists)
        XCTAssertEqual(element("search-import-all").label, "Import all 38")
        snap("search-tune")

        element("search-import-1").tap()
        let open = element("search-open-1")
        XCTAssertTrue(open.waitForExistence(timeout: 120), "the setting did not import")
        snap("search-imported")
        open.tap()
        XCTAssertTrue(app.buttons["score-title"].waitForExistence(timeout: 120),
                      "the imported tune did not open")
        XCTAssertTrue(app.staticTexts["Drowsy Maggie"].firstMatch.waitForExistence(timeout: 60))
        snap("search-opened")
    }

    func testNothingFoundSaysSo() {
        openSearch()
        element("search-field").tap()
        element("search-field").typeText("zzzqqqxxx")
        element("search-go").tap()
        XCTAssertTrue(element("search-none").waitForExistence(timeout: 30))
        XCTAssertEqual(element("search-count").label, "No tunes")
        snap("search-none")
    }

    /// Untick a source and it is left out; the choice survives a relaunch.
    func testTheSourcesAreTickBoxesThatAreRemembered() {
        openSearch()
        element("search-source-musescore").tap()
        XCTAssertFalse(element("search-source-musescore").isSelected)
        element("search-field").tap()
        element("search-field").typeText("drowsy")
        element("search-go").tap()
        XCTAssertTrue(element("search-count").waitForExistence(timeout: 30))
        XCTAssertFalse(element("search-musescore-open").exists, "MuseScore was unticked")

        app.terminate()
        app.launchArguments = ["-seedTestLibrary", "-stubTheSession"]
        app.launch()
        element("library-import").tap()
        element("library-import-search").tap()
        XCTAssertTrue(element("search-source-musescore").waitForExistence(timeout: 20))
        XCTAssertFalse(element("search-source-musescore").isSelected, "the untick was forgotten")
        XCTAssertTrue(element("search-source-thesession").isSelected)
        // tick it back for whoever runs next
        element("search-source-musescore").tap()
    }
}
