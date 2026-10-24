import XCTest

/// Opening a playable score and waiting for its tray to carry the knobs.
///
/// 0.8: the tray IS the mixer (design/DESIGN_SYSTEM.md §7.7). There is no
/// button that opens it and nothing to reveal; what a test waits for is the
/// first knob, because the knobs come from the playback timeline, which is an
/// engine call, and a tray with no knobs is a tray still preparing.
extension XCTestCase {

    /// Wait for the seeded library to STOP GROWING rather than spending a
    /// wall-clock budget across an engine call -- gate.sh's own hazard note.
    func waitForTheLibraryToSettle(_ app: XCUIApplication,
                                   timeout: TimeInterval = 300) {
        let rows = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "row-"))
        let deadline = Date().addingTimeInterval(timeout)
        var last = -1
        var stableSince = Date()
        while Date() < deadline {
            let now = rows.count
            if now != last { last = now; stableSince = Date() }
            else if now > 0, Date().timeIntervalSince(stableSince) > 2.5 { return }
            Thread.sleep(forTimeInterval: 0.5)
        }
    }

    /// The seeded piece's row, once BOTH samples are filed under it.
    ///
    /// The row appears when the FIRST import lands, and a piece holding one
    /// arrangement opens it on a tap instead of pushing the piece screen. So a
    /// test that tapped the row as soon as it existed opened the quartet
    /// (imported first, alphabetically) and then waited 60 s for a choice
    /// screen that never came -- five times in the 0.23.2 gate -- and a test
    /// that meant the accordion solo measured the quartet instead.
    /// `ScorangerUITests.waitForTheSeedToFinish` is the same wait.
    @discardableResult
    func waitForTheSeededPiece(_ app: XCUIApplication, timeout: TimeInterval = 240,
                               file: StaticString = #filePath,
                               line: UInt = #line) -> XCUIElement {
        let row = app.descendants(matching: .any)["row-sous-le-ciel-de-paris"]
        XCTAssertTrue(row.waitForExistence(timeout: timeout),
                      "the seeded library never listed its piece", file: file, line: line)
        expect("both samples filed under the piece", timeout: timeout,
               file: file, line: line) { row.label.contains("2 arrangements") }
        return row
    }

    /// After a piece row is tapped: either the score opened, or the piece
    /// screen asks which arrangement. One wait on whichever comes first; the
    /// suite used to spend 5 s probing for the score before looking for the
    /// choice, and the choice is the usual answer.
    func openWhicheverArrives(_ app: XCUIApplication, timeout: TimeInterval = 60) {
        let title = app.buttons["score-title"]
        let choice = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@",
                                  "arrangement-choice-")).firstMatch
        waitUntil("the score or the piece screen", timeout: timeout) {
            title.exists || choice.exists
        }
        if !title.exists, choice.exists { settle(choice); choice.tap() }
    }

    /// The tray, with its first knob on it, or nil with `step` naming where
    /// the open failed. `nil` arrangement opens whichever the library offers
    /// first (the quartet); a slug opens that one.
    func openTray(_ app: XCUIApplication, arrangement: String? = nil,
                  step: inout String) -> XCUIElement? {
        _ = app.descendants(matching: .any)["library-search"].waitForExistence(timeout: 90)
        let row = waitForTheSeededPiece(app)
        guard row.exists else { step = "the piece row never appeared"; return nil }
        row.tap()
        let choice = arrangement.map { app.descendants(matching: .any)["arrangement-choice-\($0)"] }
            ?? app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@",
                                      "arrangement-choice-")).firstMatch
        if choice.waitForExistence(timeout: 60) { settle(choice); choice.tap() }
        guard app.buttons["score-title"].waitForExistence(timeout: 240) else {
            step = "the score never opened"; return nil
        }
        let page = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "canvas-")).firstMatch
        // Asserted, not waited on and passed over. A launch that inherited the
        // continuous layout has no page canvas at all, and this sat out its
        // whole 180 s and carried on to measure a strip: five times, 900 s,
        // in the 0.23.2 gate, and the test measured whichever layout the
        // shard's previous test had left.
        guard page.waitForExistence(timeout: 180) else {
            step = "no engraved page: the score is not in page layout"; return nil
        }
        settle(page, still: 0.6)
        let tray = app.otherElements["transport"].firstMatch
        guard tray.waitForExistence(timeout: 60) else {
            step = "there is no tray: playback is unavailable"; return nil
        }
        guard app.descendants(matching: .any)["strip-mute-0"].waitForExistence(timeout: 180) else {
            step = "the tray never grew a knob: the timeline did not arrive"; return nil
        }
        settle(tray)
        return tray
    }

    /// How many knobs the tray carries.
    func knobCount(_ app: XCUIApplication) -> Int {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "strip-mute-")).count
    }

    /// Every edge of `box` is inside `screen`, reported as the overhang in
    /// points rather than as "an assertion failed".
    func assertInside(_ box: CGRect, _ screen: CGRect, _ label: String,
                      file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThanOrEqual(box.maxX - screen.maxX, 0.5,
                                 "[\(label)] \(box.maxX - screen.maxX)pt off the right",
                                 file: file, line: line)
        XCTAssertLessThanOrEqual(box.maxY - screen.maxY, 0.5,
                                 "[\(label)] \(box.maxY - screen.maxY)pt off the bottom",
                                 file: file, line: line)
        XCTAssertGreaterThanOrEqual(box.minX - screen.minX, -0.5,
                                    "[\(label)] off the left", file: file, line: line)
        XCTAssertGreaterThanOrEqual(box.minY - screen.minY, -0.5,
                                    "[\(label)] off the top", file: file, line: line)
    }

    /// What the tray says will be heard: "all voices", "3 of 4 voices",
    /// "silent" or "metronome only". It was the mixer header's summary and is
    /// now the value of the all-on/all-off glyph, whichever it currently is.
    func voicesSummary(_ app: XCUIApplication) -> String {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "voices-all-"))
            .firstMatch.value as? String ?? ""
    }

    func waitForVoices(_ app: XCUIApplication, contains text: String,
                       timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if voicesSummary(app).contains(text) { return true }
            usleep(200_000)
        }
        return voicesSummary(app).contains(text)
    }

    /// Tap the all-on glyph if it is offered; when every voice is already on
    /// the glyph is all-off and there is nothing to do.
    func turnEveryVoiceOn(_ app: XCUIApplication) {
        let on = app.buttons["voices-all-on"]
        if on.exists { on.tap() }
    }

    /// Every voice off. The glyph offers all-OFF only while every voice is
    /// on (§7.7: one glyph, saying what it will do), so from a mixed state
    /// this is two taps: all on, then all off.
    func turnEveryVoiceOff(_ app: XCUIApplication) {
        turnEveryVoiceOn(app)
        let off = app.buttons["voices-all-off"]
        XCTAssertTrue(off.waitForExistence(timeout: 5), "the glyph never offered all-off")
        off.tap()
    }
}
