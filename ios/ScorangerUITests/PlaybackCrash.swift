import XCTest

/// Ali, on 0.6.14 build 173: "App crashes in playback of Sous le ciel de
/// Paris."
///
/// A reproduction first, and deliberately a crude one: open the arrangement,
/// press play, and let it play. Nothing is asserted about the sound -- the
/// only claim is that the app is still running afterwards, which is the whole
/// of the report.
///
/// It plays for SECONDS rather than pressing play and looking immediately. A
/// crash in playback can be at the start (the graph being built, a part with
/// no notes, a program that will not load) or later (the play head reaching a
/// bar the map does not describe, a repeat being played out), and a test that
/// only checks the first frame after the tap would miss the second kind
/// entirely.
final class PlaybackCrash: XCTestCase {

    private func snap(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testPlayingSousLeCielDoesNotCrash() {
        let app = XCUIApplication()
        app.launchArguments = ["-resetLibrary", "-seedTestLibrary"]
        app.launch()
        _ = app.descendants(matching: .any)["library-search"].waitForExistence(timeout: 240)
        let row = waitForTheSeededPiece(app, timeout: 180)
        guard row.exists else { return XCTFail("no piece") }
        row.tap()
        openWhicheverArrives(app)
        guard app.buttons["score-title"].waitForExistence(timeout: 300) else {
            return XCTFail("the score never opened")
        }
        settle(app.buttons["score-title"], still: 0.8)

        // The transport reveals itself on the first playable arrangement, so
        // it may need a moment -- and if it never appears, that is a different
        // bug and this test should say so rather than time out silently.
        let play = app.buttons["transport-play"]
        if !play.waitForExistence(timeout: 60) {
            snap(app, "no-transport")
            return XCTFail("no play button: the transport never appeared")
        }
        snap(app, "before-play")
        play.tap()

        // Let it actually play. `expectation` rather than a bare wait so the
        // failure reads as "the app went away" instead of a mysterious query
        // timeout further down.
        let gone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: play)
        let result = XCTWaiter().wait(for: [gone], timeout: 25)
        snap(app, "after-playing")

        XCTAssertEqual(app.state, .runningForeground,
                       "the app is no longer in the foreground: state "
                       + "\(app.state.rawValue) -- it crashed during playback")
        XCTAssertNotEqual(result, .completed,
                          "the transport disappeared while playing, which is "
                          + "what a crash looks like from out here")

        // STAGE 2: TOUCH THE MUSIC WHILE IT PLAYS.
        //
        // This is new in 0.6.14 and it is the interaction most likely to be
        // what Ali hit. Before this release a finger tap on the canvas did
        // nothing AT ALL -- the recogniser failed itself at the end of every
        // touch -- so selecting while the music played was not possible with a
        // finger on any device. It is now, and following a performance by
        // tapping the note you are listening to is about the first thing
        // anyone would try.
        let canvas = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "canvas-"))
            .firstMatch
        guard canvas.waitForExistence(timeout: 60) else {
            return XCTFail("no canvas to tap")
        }
        for dy in [0.3, 0.45, 0.6, 0.75] {
            guard app.state == .runningForeground else {
                snap(app, "crashed-tapping-while-playing")
                return XCTFail("the app died on a tap at dy=\(dy) while playing")
            }
            canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: dy)).tap()
        }
        snap(app, "tapped-while-playing")
        XCTAssertEqual(app.state, .runningForeground,
                       "the app crashed while the score was tapped during "
                       + "playback -- the interaction 0.6.14 made possible")

        // STAGE 3: and a PRESS while it plays, which raises the loupe over a
        // canvas that is being redrawn under it by the play head.
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 2.0)
        snap(app, "pressed-while-playing")
        XCTAssertEqual(app.state, .runningForeground,
                       "the app crashed while a press held the loupe open "
                       + "during playback")

        // STAGE 4: THE TRAY'S KNOBS, WORKED, WHILE IT PLAYS.
        //
        // Every channel muted and unmuted under the running performance, and
        // the sound picker opened on one of them -- which reloads a patch into
        // a sampler the sequencer is feeding. The knobs are on the tray (0.8);
        // there is nothing to open first.
        if app.descendants(matching: .any)["strip-mute-0"].waitForExistence(timeout: 60) {
            let strips = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@", "strip-"))
            snap(app, "mixer-open-while-playing")
            for round in 0..<3 {
                for index in 0..<min(strips.count, 6) {
                    guard app.state == .runningForeground else {
                        snap(app, "crashed-working-the-mixer")
                        return XCTFail("the app died working strip \(index) "
                                       + "on round \(round) while playing")
                    }
                    let mute = app.descendants(matching: .any)["strip-mute-\(index)"]
                    if mute.exists, mute.isHittable { mute.tap() }
                }
            }
            // the instrument picker, which swaps a patch mid-performance
            let chip = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@",
                                      "strip-sound-")).firstMatch
            if chip.exists, chip.isHittable {
                chip.tap()
                snap(app, "sound-picker-while-playing")
                // The picker's rows are `picker-family-N` and
                // `picker-instrument-…`; this looked for "sound-", which
                // matches nothing, waited 10 s and never swapped a patch.
                let family = app.descendants(matching: .any)["picker-family-0"].firstMatch
                XCTAssertTrue(family.waitForExistence(timeout: 10), "the sound list did not open")
                family.tap()
                let choice = app.descendants(matching: .any)["picker-instrument-melodic-0"]
                    .firstMatch
                XCTAssertTrue(choice.waitForExistence(timeout: 10),
                              "the piano family does not list the plain piano")
                choice.tap()
            }
            // The picker is a popover; put it away before the scrubbing.
            let close = app.descendants(matching: .any)["mixer-picker-close"].firstMatch
            if close.exists { close.tap() }
            XCTAssertEqual(app.state, .runningForeground,
                           "the app crashed with the tray's knobs worked "
                           + "during playback")
        }

        // STAGE 5: SCRUBBING WHILE IT PLAYS, with the mixer still up.
        //
        // The scrubber moves the PAGE while the play head is moving the music,
        // so the two are competing to say what the canvas shows -- and page
        // follow is watching both.
        //
        // The scrubber is the COMPACT-width control (PageScrubber); a regular
        // width has the thumbnail rail down the left instead, which jumps the
        // page the same way. This stage waited 20 s for the scrubber on the
        // gate's iPads, found none, and skipped itself without a word -- so it
        // now scrubs with whichever the width has, and fails if neither is up.
        let scrubber = app.descendants(matching: .any)["page-scrubber"].firstMatch
        let rail = app.descendants(matching: .any)["thumbnail-rail"].firstMatch
        XCTAssertTrue(waitUntil("a page scrubber or the thumbnail rail", timeout: 20) {
            scrubber.exists || rail.exists
        }, "neither the page scrubber nor the thumbnail rail is on screen")
        let horizontal = scrubber.exists
        let mover = horizontal ? scrubber : rail
        func scrub(_ at: Double) {
            let point = horizontal ? CGVector(dx: at, dy: 0.5) : CGVector(dx: 0.5, dy: at)
            mover.coordinate(withNormalizedOffset: point).tap()
        }
        for at in [0.9, 0.1, 0.55, 0.99, 0.01] {
            guard app.state == .runningForeground else {
                snap(app, "crashed-scrubbing")
                return XCTFail("the app died scrubbing to \(at) while playing")
            }
            scrub(at)
        }
        snap(app, "scrubbed-while-playing")

        // STAGE 6: all of it at once -- tap the music, hold the loupe, scrub,
        // with the mixer open and the performance still running.
        for round in 0..<3 {
            canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.4)).tap()
            if mover.exists { scrub(0.3 + 0.2 * Double(round)) }
            canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.6))
                .press(forDuration: 1.0)
            guard app.state == .runningForeground else {
                snap(app, "crashed-everything-at-once")
                return XCTFail("the app died on round \(round) of tap + scrub "
                               + "+ loupe with the mixer open, while playing")
            }
        }
        snap(app, "everything-at-once")
        XCTAssertEqual(app.state, .runningForeground,
                       "the app crashed under the whole interaction set during "
                       + "playback")
    }
}
