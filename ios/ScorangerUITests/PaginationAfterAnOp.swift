import XCTest

/// Pagination survives an op that ADDS material to the score.
///
/// Ali: after a chat op that changes the score -- adding a staff, a tab,
/// chords -- "the layout collapses to one long squished illegible system".
///
/// "One long squished system" is exactly what `breaks: "none"` produces, and
/// that was the obvious suspect: `VerovioRenderer` keeps ONE toolkit,
/// Verovio's `setOptions` MERGES, and a continuous engrave leaking its
/// `breaks` into every paged one afterwards is a fault this app has had and
/// fixed once (`EngravingOptions`). It is NOT this one. Replaying the whole
/// sequence against the same Verovio with the iOS option sets verbatim --
/// paged, paged with an MEI reload, a continuous visit, paged again -- gives
/// 9 pages every single time. The engine's own renderer paginates through an
/// op too: 8 pages before a tab, 12 after, which is a tab adding height and
/// not a collapse.
///
/// What is left is the part Python never exercises: the SWIFT MEI transforms
/// in `engrave` -- `FingeringDiagrams.meiWithFingeringsAbove`,
/// `ChordPlacement.meiWithChartStyling`, `ChordAdjustments`,
/// `ChordDiagrams.meiWithDiagrams`, `RehearsalMarks`. Each rewrites the MEI
/// as text and sets `reload`, and the document is then re-read from what they
/// produced. Ali's three examples are exactly the three that trigger them,
/// and a score with none of them never takes that path -- which is why every
/// pagination test in this suite has passed.
///
/// So the fixtures here are scores that HAVE those elements, seeded through
/// the real engine rather than from a canned file, and the assertion is the
/// page counter the existing pagination guard already uses.
final class PaginationAfterAnOp: XCTestCase {

    private var app: XCUIApplication!

    private func snap(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// A plain wait, alongside the shared element-based `settle`. RenderShot
    /// carries the same private helper for the same reason: waiting on a page
    /// COUNT is waiting on a number, not on an element appearing.
    private func settle(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    /// "pages=8 systems=3,3,3,4,3,3,3,3" -- the per-page SYSTEM count, under
    /// `-geometryProbe`. The page count alone cannot tell a collapse from a
    /// short piece; the system count can.
    private var probe: String {
        let element = app.descendants(matching: .any)["geometry-probe"]
        return element.exists ? element.label : ""
    }

    private func systems(in probe: String) -> [Int] { field("systems=", in: probe) }

    /// What the ENGRAVER drew, as opposed to what the app inferred.
    private func drawn(in probe: String) -> [Int] { field("drawn=", in: probe) }

    private func field(_ name: String, in probe: String) -> [Int] {
        guard let part = probe.split(separator: " ")
            .first(where: { $0.hasPrefix(name) })?
            .dropFirst(name.count) else { return [] }
        return part.split(separator: ",").compactMap { Int($0) }
    }

    private func waitForProbe(timeout: TimeInterval = 120) -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let now = probe
            if !systems(in: now).isEmpty { settle(0.8); return probe }
            settle(0.5)
        }
        return probe
    }

    private var counter: String {
        let chip = app.staticTexts["counter-pages"]
        return chip.exists ? chip.label : ""
    }

    /// The total in "p. 3 / 9", or 0 when the counter is absent.
    private func pages(in label: String) -> Int {
        guard let slash = label.lastIndex(of: "/") else { return 0 }
        return Int(label[label.index(after: slash)...]
            .trimmingCharacters(in: .whitespaces)) ?? 0
    }

    private func waitForPages(_ want: (Int) -> Bool,
                              timeout: TimeInterval = 120) -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if want(pages(in: counter)) { settle(0.8); return counter }
            settle(0.5)
        }
        return counter
    }

    /// The arrangement `-seedChordChart` and `-seedGuitarTab` write to: the
    /// first by slug.
    private static let quartet = "sous-le-ciel-quartet"

    /// The arrangement `-seedCombinedOp` writes to, by name. Ali's score is a
    /// folk tune on two staves, and on a score that short "p. 1 / 1" may be
    /// CORRECT -- the music fits. The quartet is 4 staves and 136 bars and
    /// would paginate no matter what, so it cannot show his fault.
    private static let accordion = "under-paris-skies-accordion-solo"

    /// Open the arrangement the seed put the fixture on.
    ///
    /// Once the seed has filed BOTH samples, and by the arrangement's own
    /// choice. Through 0.23.2 this tapped the piece row as soon as it existed,
    /// while it held only the quartet, so the row opened the quartet directly
    /// and the accordion choice expired after 60 s: every test here measured
    /// the quartet, whichever fixture it named. The chord and tab tests were
    /// right by accident -- those seeds write to the quartet.
    private func openTheFixture(_ slug: String) -> Bool {
        _ = app.descendants(matching: .any)["library-search"].waitForExistence(timeout: 240)
        let row = waitForTheSeededPiece(app)
        guard row.exists else { return false }
        row.tap()
        let choice = app.descendants(matching: .any)["arrangement-choice-\(slug)"]
        guard choice.waitForExistence(timeout: 60) else { return false }
        settle(choice)
        choice.tap()
        guard app.buttons["score-title"].waitForExistence(timeout: 300) else { return false }
        let page = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "canvas-")).firstMatch
        _ = page.waitForExistence(timeout: 240)
        settle(page, still: 0.8)
        return true
    }

    /// The score paginates when it carries CHORD SYMBOLS, which is the
    /// `ChordPlacement` transform's reload path.
    func testPaginationSurvivesChordSymbols() {
        app = XCUIApplication()
        app.launchArguments = ["-resetLibrary", "-seedTestLibrary", "-seedChordChart"]
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        guard openTheFixture(Self.quartet) else { return XCTFail("the fixture never opened") }
        let seen = waitForPages { $0 > 0 }
        snap("pagination-with-chord-symbols")
        print("PAGINATION chords: counter = \"\(seen)\"")
        XCTAssertGreaterThan(pages(in: seen), 1,
                             "a score carrying chord symbols engraved to "
                             + "\(pages(in: seen)) page(s): \"\(seen)\"")
    }

    /// And when it carries a GUITAR TAB, which is the `FingeringDiagrams`
    /// reload path -- lyric verses moved above the staff on the MEI.
    func testPaginationSurvivesAGuitarTab() {
        app = XCUIApplication()
        app.launchArguments = ["-resetLibrary", "-seedTestLibrary", "-seedGuitarTab"]
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        guard openTheFixture(Self.quartet) else { return XCTFail("the fixture never opened") }
        let seen = waitForPages { $0 > 0 }
        snap("pagination-with-a-guitar-tab")
        print("PAGINATION tab: counter = \"\(seen)\"")
        XCTAssertGreaterThan(pages(in: seen), 1,
                             "a score carrying a guitar tab engraved to "
                             + "\(pages(in: seen)) page(s): \"\(seen)\"")
    }

    // The CONTROL for the two above -- the same quartet with none of those
    // elements paginates -- is RenderShot.testPaginationSurvivesAVisitToContinuous,
    // which opens the plain quartet and asserts more than one page on the way
    // in and back. It was also a test of its own here, a whole launch and
    // engrave to assert the same counter.
    //
    // The combined op's page counter (a staff, then a tab, then chords) is
    // asserted inside testTheCombinedOpThroughTheAppKeepsItsSystems below,
    // which already opened that score to measure its systems.

    // MARK: - The observable, validated

    /// The app's inference of where systems fall must agree with the
    /// ENGRAVING THAT DREW THEM, or every number below it is a number about
    /// the inference rather than about the score.
    ///
    /// ## What this used to compare, and why it could not work
    ///
    /// It asserted the app's total against a hard-coded 25 that the ENGINE
    /// reports. The engine engraves with `render.page_options()` and the app
    /// with `EngravingOptions`, and those differ in margins, scale, breaks
    /// and lyric size. Same file, same Verovio, one process:
    ///
    ///     render.page_options()   ->  5 pages, 5,6,6,5,3  = 25
    ///     EngravingOptions (4.5)  ->  5 pages, 5,6,6,6,3  = 26
    ///
    /// Different margins and scale mean different horizontal room, so a
    /// different number of bars per line, so a different number of LINES.
    /// 25 was never a number the app could produce: every red was correct and
    /// every green was a coincidence, which is why running it alone failed
    /// 3 times of 3 and running it in the gate passed. The full measurement,
    /// including the `lyricSize` range that ruled that lead out, is in
    /// BACKLOG.md.
    ///
    /// ## What it compares now
    ///
    /// Both numbers come from ONE drawing: `drawn=` counts the
    /// `<g class="system">` groups Verovio put in the SVG the app just
    /// rendered, and `systems=` is `BarPosition.systems(of:)` inferring the
    /// same thing from bar frames. No constant, nothing to drift with the
    /// fixture, and no second engraving to disagree with. If they part, the
    /// inference is broken -- which is exactly the hazard
    /// `check_bar_frames.py` records: Verovio nests a slur inside the measure
    /// it starts in, so one over-wide bar frame straddling two rows splits
    /// one system into two and over-counts by exactly one.
    func testTheSystemCountAgreesWithTheEngraving() {
        app = XCUIApplication()
        app.launchArguments = ["-resetLibrary", "-seedTestLibrary", "-geometryProbe"]
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        guard openTheFixture(Self.accordion) else { return XCTFail("the fixture never opened") }
        let seen = waitForProbe()
        print("PROBE as-imported: \(seen)  counter=\"\(counter)\"")

        let inferred = systems(in: seen)
        let engraved = drawn(in: seen)
        XCTAssertFalse(engraved.isEmpty,
                       "the probe carries no drawn= count: \"\(seen)\"")
        XCTAssertEqual(inferred.count, engraved.count,
                       "the app and the engraving disagree about the PAGE "
                       + "count: \"\(seen)\"")
        XCTAssertEqual(inferred, engraved,
                       "the app's inference of where systems fall does not "
                       + "match the engraving it drew them from: \"\(seen)\"")
        XCTAssertEqual(inferred.reduce(0, +), engraved.reduce(0, +),
                       "totals differ: \"\(seen)\"")
        XCTAssertGreaterThan(engraved.reduce(0, +), 0,
                             "nothing was engraved at all: \"\(seen)\"")
    }

    /// And #4 itself: the combined op, through the iOS engrave path.
    ///
    /// Ali's prompt in one version -- a second staff, a tab on it, chords,
    /// diagrams -- on a two-staff folk tune, in PAGE view. His screenshot is
    /// one long system and "p. 1 / 1". The engine does not reproduce it: 25
    /// systems at every step of the same sequence, pages growing 5 -> 8 -> 9
    /// as the added material makes systems taller.
    ///
    /// THE CONTROL IS THE PRECONDITION, and two weaker ones failed first. A
    /// bare "did it collapse" passed on geometry byte-identical to the
    /// untouched score -- the ops had not run. Asserting "more than one
    /// version" passed too, because the seeded library already has three. The
    /// only precondition that cannot be satisfied by an op that did nothing
    /// is the geometry CHANGING: if adding a staff, a tab and chords leaves
    /// the drawing identical, the fixture is broken and this test must say so
    /// rather than report "no collapse" about a score nothing happened to.
    func testTheCombinedOpThroughTheAppKeepsItsSystems() {
        /// The probe once it has held still for two seconds: the combined op
        /// lands a version AFTER the seed's imports, and the canvas engraves
        /// v001 first and the op's version when it arrives.
        func stableProbe() -> String {
            var last = waitForProbe()
            let deadline = Date().addingTimeInterval(120)
            while Date() < deadline {
                settle(2)
                let now = probe
                if now == last, !systems(in: now).isEmpty { return now }
                last = now
            }
            return last
        }
        /// The geometry alone, without the `seed[...]` outcome the probe
        /// carries after it.
        func geometry(_ probe: String) -> String {
            probe.split(separator: " ").filter { !$0.hasPrefix("seed[") }
                .joined(separator: " ")
        }
        func measure(_ arguments: [String]) -> (probe: String, counter: String) {
            app = XCUIApplication()
            app.launchArguments = ["-resetLibrary", "-seedTestLibrary",
                                   "-geometryProbe"] + arguments
            app.launch()
            XCUIDevice.shared.orientation = .portrait
            guard openTheFixture(Self.accordion) else { return ("", "") }
            if arguments.contains("-seedCombinedOp") {
                _ = waitUntil("the combined op's outcome", timeout: 240) {
                    probe.contains("seed[")
                }
            }
            let seen = stableProbe()
            let pages = waitForPages { $0 > 0 }
            app.terminate()
            return (seen, pages)
        }

        let (control, _) = measure([])
        let (combined, combinedPages) = measure(["-seedCombinedOp"])
        print("PROBE control:  \(control)")
        print("PROBE combined: \(combined)  counter=\"\(combinedPages)\"")
        snap("combined-op-through-the-app")

        XCTAssertFalse(systems(in: control).isEmpty, "no control geometry")
        XCTAssertFalse(systems(in: combined).isEmpty, "no combined geometry")
        XCTAssertTrue(combined.contains("chord-diagrams=ok"),
                      "the combined op did not run to the end: \(combined)")
        // The GEOMETRY, not the probe string: the string carries the seed's
        // outcome after the combined op and not after the control, so the two
        // always differed and this precondition could never fail.
        XCTAssertNotEqual(geometry(combined), geometry(control),
                          "adding a staff, a tab and chords changed the "
                          + "drawing not at all (\(combined)) -- the fixture "
                          + "did not run, so this test can say nothing about #4")
        XCTAssertGreaterThan(pages(in: combinedPages), 1,
                             "after a staff, a tab, chords and diagrams the "
                             + "score engraved to \(pages(in: combinedPages)) page(s): "
                             + "\"\(combinedPages)\" -- which is Ali's p. 1 / 1")

        let lines = systems(in: combined).reduce(0, +)
        XCTAssertGreaterThan(lines, 1,
                             "the whole score is on ONE system -- Ali's "
                             + "collapse: \(combined)")
    }
}
