import XCTest

/// Untracked QA scaffolding for the 0.6.3 reorganisation: photograph the
/// things the owner judges by eye -- the halved mixer with its tempo slider,
/// and the PDF / MusicXML tags in the library and on the score.
final class ReorgShot: XCTestCase {

    /// The page on the canvas -- the element that says an engraving has landed
    /// rather than that a canvas exists.
    private func engravedPage(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "canvas-"))
            .firstMatch
    }

    private func snap(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// `named` picks a particular row -- the mixer needs an arrangement that can
    /// actually PLAY, and the seeded library's first row is a scan.
    private func openFirstScore(_ app: XCUIApplication, named: String? = nil) -> Bool {
        var row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "row-")).firstMatch
        if let named {
            let wanted = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS[c] %@",
                                      "row-", named)).firstMatch
            if wanted.waitForExistence(timeout: 60) { row = wanted }
        }
        guard row.waitForExistence(timeout: 60) else { return false }
        row.tap()
        if app.buttons["score-title"].waitForExistence(timeout: 5) == false {
            let choice = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@",
                                      "arrangement-choice-")).firstMatch
            if choice.waitForExistence(timeout: 30) {
                settle(choice)
                snap("piece-screen-arrangement-tags")
                choice.tap()
            }
        }
        return app.buttons["score-title"].waitForExistence(timeout: 240)
    }

    func testTheLibraryAndTheScoreSayWhatTheyHold() {
        let app = XCUIApplication()
        app.launchArguments = ["-resetViewPreferences", "-seedTestLibrary"]
        app.launch()
        _ = app.descendants(matching: .any)["library-search"].waitForExistence(timeout: 90)
        // The library fills in as the seed imports; photograph it once the rows
        // have stopped arriving rather than three seconds in.
        settle(app.descendants(matching: .any)["library-search"], still: 0.8)
        snap("library-format-tags-and-build-stamp")
        guard openFirstScore(app) else { return XCTFail("the score never engraved") }
        _ = engravedPage(app).waitForExistence(timeout: 180)
        settle(engravedPage(app), still: 0.6)
        snap("score-artifact-marker")
    }

    /// The tray with its tempo knob (0.8 §7.7): photographed at rest, then
    /// with the tempo turned up, for the owner to judge the knob by eye.
    func testTheTrayAndItsTempoKnob() {
        let app = XCUIApplication()
        app.launchArguments = ["-resetViewPreferences", "-seedTestLibrary"]
        app.launch()
        var step = ""
        guard let tray = openTray(app, step: &step) else { return XCTFail(step) }
        snap("score-with-the-tray")
        print("TRAY frame: \(tray.frame)")
        let tempo = app.descendants(matching: .any)["transport-tempo"].firstMatch
        guard tempo.exists else { return XCTFail("the tempo knob is not on the tray") }
        print("TEMPO frame: \(tempo.frame), value: \(tempo.value ?? "-")")
        let was = tempo.value as? String ?? ""
        // Up is faster (§7.8): 14pt a unit, two BPM a unit.
        let from = tempo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
        from.press(forDuration: 0.2, thenDragTo: from.withOffset(CGVector(dx: 0, dy: -70)),
                   withVelocity: .slow, thenHoldForDuration: 0.3)
        XCTAssertTrue(waitUntil("the tempo to move", timeout: 15) {
            (tempo.value as? String ?? "") != was
        }, "dragging the tempo knob did not change the tempo: \(was)")
        snap("tray-tempo-turned")
        print("TEMPO now: \(tempo.value ?? "-")")
    }

    /// The sound picker, from a knob's label, for the 0.6.5 dropdown's 0.8
    /// home: a popover over the tray. Photographed rather than asserted; the
    /// behaviour is in `testTheMixerChoosesTheSoundAChannelIsPlayedWith`.
    func testTheMixerSoundPicker() {
        let app = XCUIApplication()
        app.launchArguments = ["-resetViewPreferences", "-seedTestLibrary"]
        app.launch()
        var step = ""
        guard openTray(app, step: &step) != nil else { return XCTFail(step) }
        snap("tray-with-the-sound-labels")

        let chip = app.descendants(matching: .any)["strip-sound-0"].firstMatch
        guard chip.waitForExistence(timeout: 20) else {
            snap("no-sound-label")
            return XCTFail("the knob has no sound label")
        }
        print("SOUND label: \(chip.frame), value: \(chip.value as? String ?? "-")")
        chip.tap()
        let picker = app.descendants(matching: .any)["mixer-picker"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 20), "the picker did not open")
        settle(picker, still: 0.5)
        print("PICKER frame: \(picker.frame)")
        snap("tray-sound-picker-open")

        // A family further down the list, so the shot shows the two columns
        // doing what they are for rather than the one the channel opened on.
        let brass = app.descendants(matching: .any)["picker-family-7"].firstMatch
        if brass.exists {
            brass.tap()
            settle(picker, still: 0.4)
            snap("tray-sound-picker-brass")
        }
    }

    /// The Options screen, flattened: no "Score display", no "Versions",
    /// chord symbols one level up.
    func testTheOptionsScreen() {
        let app = XCUIApplication()
        app.launchArguments = ["-resetViewPreferences", "-seedTestLibrary"]
        app.launch()
        _ = app.descendants(matching: .any)["library-search"].waitForExistence(timeout: 90)
        guard openFirstScore(app) else { return XCTFail("the score never engraved") }
        _ = engravedPage(app).waitForExistence(timeout: 180)
        app.buttons["score-more"].tap()
        let root = app.descendants(matching: .any)["more-chords"].firstMatch
        _ = root.waitForExistence(timeout: 20)
        settle(root)
        snap("options-root")
        if root.exists {
            root.tap()
            settle(app.windows.firstMatch, still: 0.5)
            snap("options-chord-symbols")
        }
    }

    /// The versions dropdown shows versions and nothing else.
    func testTheVersionsDropdown() {
        let app = XCUIApplication()
        app.launchArguments = ["-resetViewPreferences", "-seedTestLibrary"]
        app.launch()
        _ = app.descendants(matching: .any)["library-search"].waitForExistence(timeout: 90)
        guard openFirstScore(app) else { return XCTFail("the score never engraved") }
        _ = engravedPage(app).waitForExistence(timeout: 180)
        let rows = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "menu-version-")).firstMatch
        if app.buttons["score-versions"].exists {
            app.buttons["score-versions"].tap()
            _ = rows.waitForExistence(timeout: 20)
            snap("dropdown-versions-only")
            app.buttons["score-versions"].tap()
        }
        app.buttons["score-title"].tap()
        let arrangements = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "menu-arrangement-")).firstMatch
        _ = arrangements.waitForExistence(timeout: 20)
        settle(app.windows.firstMatch, still: 0.5)
        snap("dropdown-arrangements")
    }
}
