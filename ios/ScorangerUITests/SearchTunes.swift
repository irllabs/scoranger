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
        XCTAssertTrue(element("search-setting-1").label.hasPrefix("Setting 1, E dorian"),
                      element("search-setting-1").label)
        // 0.22.0: the first setting is drawn beside the list as the tune opens
        XCTAssertTrue(element("search-preview").waitForExistence(timeout: 60),
                      "the setting in focus was not drawn")
        XCTAssertFalse(element("search-import-ticked").isEnabled, "nothing is ticked yet")
        snap("search-tune")

        // another setting in focus is drawn in its turn
        element("search-setting-2").tap()
        XCTAssertTrue(element("search-setting-2").label.hasSuffix("shown"))
        XCTAssertTrue(element("search-preview").waitForExistence(timeout: 60))
        snap("search-tune-setting-2")

        // tick two and import them: two arrangements of ONE piece
        element("search-tick-1").tap()
        element("search-tick-3").tap()
        XCTAssertEqual(element("search-import-ticked").label, "Import 2 settings")
        element("search-import-ticked").tap()
        let said = element("search-imported")
        XCTAssertTrue(said.waitForExistence(timeout: 120), "the settings did not import")
        XCTAssertEqual(said.label, "Imported 2 settings as the piece Drowsy Maggie.")
        snap("search-imported")

        // one more joins that piece, and the sentence says so -- "I imported
        // one and it imported all of them" was a piece that already held them
        element("search-tick-5").tap()
        element("search-import-ticked").tap()
        let joined = NSPredicate(format: "label == %@",
                                 "Added 1 setting to Drowsy Maggie, which now has 3 arrangements.")
        expectation(for: joined, evaluatedWith: element("search-imported"))
        waitForExpectations(timeout: 120)
        snap("search-imported-joined")

        let open = element("search-open")
        XCTAssertTrue(open.exists)
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
