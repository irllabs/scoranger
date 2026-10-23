import XCTest

/// The arithmetic behind the diagnostics panel.
///
/// Kept pure and separate from the recording, because the interesting question
/// is not "how long did one thing take" but "of the second the reader waited,
/// what was the app doing" -- which is attribution over a window, and is the
/// part that can be got wrong silently.
final class PerfLedgerTests: XCTestCase {

    // MARK: - Recording

    func testAnEmptyLedgerSummarisesToNothing() {
        XCTAssertTrue(PerfLedger().summaries().isEmpty)
    }

    func testSamplesGroupByName() {
        var l = PerfLedger()
        l.record("engrave", start: 0, duration: 0.1)
        l.record("engrave", start: 1, duration: 0.3)
        l.record("bridge.info", start: 2, duration: 0.05)
        let s = l.summaries()
        XCTAssertEqual(s.count, 2)
        XCTAssertEqual(s.first(where: { $0.name == "engrave" })?.count, 2)
    }

    func testSummariesAreOrderedByWhereTheTimeWent() {
        var l = PerfLedger()
        l.record("cheap", start: 0, duration: 0.01)
        l.record("cheap", start: 1, duration: 0.01)
        l.record("dear", start: 2, duration: 0.9)
        XCTAssertEqual(l.summaries().map(\.name), ["dear", "cheap"])
    }

    func testTheLedgerIsBoundedSoALongSessionCannotGrowForever() {
        var l = PerfLedger()
        for i in 0..<(PerfLedger.keepPerName + 50) {
            l.record("tile", start: Double(i), duration: 0.001)
        }
        XCTAssertEqual(l.summaries().first?.count, PerfLedger.keepPerName)
    }

    func testTheOLDESTSamplesAreTheOnesDropped() {
        var l = PerfLedger()
        l.record("tile", start: 0, duration: 9.0)          // the one to lose
        for i in 1...PerfLedger.keepPerName {
            l.record("tile", start: Double(i), duration: 0.001)
        }
        XCTAssertEqual(l.summaries().first?.max ?? 0, 0.001, accuracy: 1e-9)
    }

    // MARK: - The numbers

    func testSummaryReportsTheSpreadAndNotOnlyTheMean() {
        var l = PerfLedger()
        for (i, d) in [0.1, 0.2, 0.3, 0.4, 1.0].enumerated() {
            l.record("open", start: Double(i), duration: d)
        }
        let s = l.summaries()[0]
        XCTAssertEqual(s.count, 5)
        XCTAssertEqual(s.total, 2.0, accuracy: 1e-9)
        XCTAssertEqual(s.min, 0.1, accuracy: 1e-9)
        XCTAssertEqual(s.median, 0.3, accuracy: 1e-9)
        XCTAssertEqual(s.max, 1.0, accuracy: 1e-9)
        // the slow one is what the reader feels, and a mean of 0.4 hides it
        XCTAssertEqual(s.p95, 1.0, accuracy: 1e-9)
    }

    func testMedianOfAnEvenCountTakesTheMiddlePair() {
        var l = PerfLedger()
        for (i, d) in [0.1, 0.2, 0.3, 0.4].enumerated() {
            l.record("x", start: Double(i), duration: d)
        }
        XCTAssertEqual(l.summaries()[0].median, 0.25, accuracy: 1e-9)
    }

    func testASingleSampleIsItsOwnEveryStatistic() {
        var l = PerfLedger()
        l.record("x", start: 0, duration: 0.42)
        let s = l.summaries()[0]
        XCTAssertEqual(s.min, 0.42, accuracy: 1e-9)
        XCTAssertEqual(s.median, 0.42, accuracy: 1e-9)
        XCTAssertEqual(s.p95, 0.42, accuracy: 1e-9)
        XCTAssertEqual(s.max, 0.42, accuracy: 1e-9)
    }

    // MARK: - Attribution: what was the app doing while the reader waited

    func testWorkInsideTheWindowIsAttributedToIt() {
        var l = PerfLedger()
        l.record("bridge.info", start: 10.1, duration: 0.2)
        l.record("engrave", start: 10.4, duration: 0.5)
        l.record("engrave", start: 99.0, duration: 5.0)     // another era
        let acc = l.accounted(from: 10.0, to: 11.0)
        XCTAssertEqual(acc.count, 2)
        XCTAssertEqual(acc.first(where: { $0.name == "engrave" })?.total ?? 0,
                       0.5, accuracy: 1e-9)
    }

    func testWorkOverLAPPINGTheWindowCountsOnlyTheOverlap() {
        var l = PerfLedger()
        // began before the window opened and ran past its close
        l.record("engrave", start: 9.5, duration: 2.0)      // 9.5 -> 11.5
        let acc = l.accounted(from: 10.0, to: 11.0)
        XCTAssertEqual(acc[0].total, 1.0, accuracy: 1e-9)
    }

    func testAWindowWithNoRecordedWorkAccountsForNothing() {
        var l = PerfLedger()
        l.record("engrave", start: 1.0, duration: 0.5)
        XCTAssertTrue(l.accounted(from: 10.0, to: 11.0).isEmpty)
    }

    /// A timed open's timeline (`OpenTiming`): every sample touching the
    /// window, whole and in the order it began, whatever its name.
    func testTheSamplesOfAWindowAreEveryOneTouchingItEarliestFirst() {
        var l = PerfLedger()
        l.record("render", start: 10.2, duration: 0.6)        // inside
        l.record("engrave: load", start: 9.5, duration: 1.0)  // straddles the start
        l.record("manifest", start: 5.0, duration: 0.1)       // before
        l.record("render", start: 11.5, duration: 0.1)        // after
        let s = l.samples(from: 10.0, to: 11.0)
        XCTAssertEqual(s.map(\.name), ["engrave: load", "render"])
        XCTAssertEqual(s[0].duration, 1.0, accuracy: 1e-9)   // not clipped
    }

    /// The finding this whole panel exists to make sayable: the reader waited
    /// a second and the app was measurably doing NOTHING it knows how to name.
    func testUnaccountedTimeIsTheAnswerWhenNothingWasMeasured() {
        var l = PerfLedger()
        l.record("bridge.info", start: 10.1, duration: 0.05)
        XCTAssertEqual(l.unaccounted(from: 10.0, to: 11.0), 0.95, accuracy: 1e-9)
    }

    func testUnaccountedTimeNeverGoesNegativeWhenWorkOverlapsItself() {
        var l = PerfLedger()
        // two tiles rasterised in parallel: 0.8s of work inside a 1.0s window,
        // but wall-clock cannot go below zero however many threads ran
        l.record("tile", start: 10.0, duration: 0.8)
        l.record("tile", start: 10.0, duration: 0.8)
        XCTAssertGreaterThanOrEqual(l.unaccounted(from: 10.0, to: 11.0), 0)
    }

    // MARK: - Reading it back

    func testDurationsReadInMilliseconds() {
        XCTAssertEqual(PerfLedger.ms(0.9812), "981 ms")
        XCTAssertEqual(PerfLedger.ms(0.0004), "0.4 ms")
        XCTAssertEqual(PerfLedger.ms(0.0156), "15.6 ms")
        XCTAssertEqual(PerfLedger.ms(2.5), "2500 ms")
    }
}

/// The text a reader pastes back into a report.
final class PerfReportTests: XCTestCase {

    func testAnEmptyLedgerSaysSoRatherThanShowingAnEmptyTable() {
        let text = PerfReport.text(PerfLedger())
        XCTAssertTrue(text.contains("No measurements yet"), text)
    }

    func testTheBuildStampLeadsSoAQuotedNumberNamesItsBuild() {
        var l = PerfLedger()
        l.record("render", start: 0, duration: 0.4)
        XCTAssertTrue(PerfReport.text(l, buildStamp: "0.6.3 (161) abc1234")
                        .hasPrefix("0.6.3 (161) abc1234"))
    }

    func testEveryRowCarriesItsSampleCountAndUnits() {
        var l = PerfLedger()
        l.record("menu.versions open", start: 0, duration: 0.98)
        l.record("menu.versions open", start: 2, duration: 1.02)
        let text = PerfReport.text(l)
        XCTAssertTrue(text.contains("menu.versions open"), text)
        XCTAssertTrue(text.contains("ms"), text)
        // n = 2: a single reading is an anecdote
        XCTAssertTrue(text.contains(" 2 "), text)
    }

    func testALongNameIsTruncatedRatherThanBreakingTheColumns() {
        var l = PerfLedger()
        l.record(String(repeating: "z", count: 60), start: 0, duration: 0.1)
        let lines = PerfReport.text(l).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines[1].count, lines[0].count, "columns drifted:\n" + lines.joined(separator: "\n"))
    }

    func testTheDearestRowComesFirst() {
        var l = PerfLedger()
        l.record("cheap", start: 0, duration: 0.01)
        l.record("dear", start: 1, duration: 1.5)
        let lines = PerfReport.text(l).split(separator: "\n").map(String.init)
        XCTAssertTrue(lines[1].hasPrefix("dear"), lines[1])
    }
}

/// Attribution, as the dump prints it.
final class PerfAttributionReportTests: XCTestCase {

    func testAWaitNothingExplainsSaysSo() {
        var l = PerfLedger()
        l.record("menu.versions open", start: 10.0, duration: 0.6)
        let text = PerfReport.attribution(l, name: "menu.versions open")
        XCTAssertTrue(text.contains("nothing else measured was running"), text)
        XCTAssertTrue(text.contains("unaccounted: 600 ms"), text)
    }

    func testWorkInsideTheWaitIsNamedAndTheRemainderIsLeftOver() {
        var l = PerfLedger()
        l.record("menu.versions open", start: 10.0, duration: 1.0)
        l.record("bridge.manifest", start: 10.2, duration: 0.1)
        let text = PerfReport.attribution(l, name: "menu.versions open")
        // The name and its count, not an exact duration: 10.3 - 10.2 is
        // 99.99999... in binary floating point, and asserting "100 ms" would
        // be asserting that arithmetic is exact rather than that the report is
        // right.
        XCTAssertTrue(text.contains("bridge.manifest ×1:"), text)
        XCTAssertTrue(text.contains("unaccounted: 900 ms"), text)
    }

    func testTheSpanItselfIsNotListedAsItsOwnCause() {
        var l = PerfLedger()
        l.record("menu.versions open", start: 10.0, duration: 0.6)
        let lines = PerfReport.attribution(l, name: "menu.versions open")
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.filter { $0.contains("menu.versions open") }.count, 1, lines.joined())
    }

    func testAnUnmeasuredNameSaysSoRatherThanReportingZero() {
        XCTAssertTrue(PerfReport.attribution(PerfLedger(), name: "nope")
                        .contains("never measured"))
    }
}

/// The gate. A diagnostic that costs anything measurable when off is one that
/// gets left off and rots -- so this asserts the off path, not the on path.
final class PerfMetricsGateTests: XCTestCase {

    override func setUp() {
        super.setUp()
        PerfMetrics.shared.setOn(false)
    }

    func testOffIsTheDefaultAndRecordsNothing() {
        XCTAssertFalse(PerfMetrics.shared.isOn)
        PerfMetrics.shared.record("x", start: 0, duration: 1.0)
        XCTAssertTrue(PerfMetrics.shared.snapshot().isEmpty)
    }

    func testASpanIsNotEvenALLOCATEDWhenOff() {
        XCTAssertNil(PerfMetrics.shared.begin("x"),
                     "begin() must return nil when off, so the caller's ?.end() "
                     + "is one nil test and no object is made")
    }

    func testMeasureStillRunsTheWorkWhenOff() {
        var ran = false
        PerfMetrics.shared.measure("x") { ran = true }
        XCTAssertTrue(ran)
        XCTAssertTrue(PerfMetrics.shared.snapshot().isEmpty)
    }

    func testSwitchingOnRecordsAndSwitchingOffStops() {
        PerfMetrics.shared.setOn(true)
        PerfMetrics.shared.record("x", start: 0, duration: 0.1)
        XCTAssertFalse(PerfMetrics.shared.snapshot().isEmpty)
        PerfMetrics.shared.setOn(false)
        PerfMetrics.shared.record("y", start: 0, duration: 0.1)
        XCTAssertNil(PerfMetrics.shared.snapshot().latest("y"))
    }

    /// Turning it on starts a fresh reading, so what the panel shows is the
    /// session the reader is about to take.
    func testSwitchingOnClearsWhatWasThere() {
        PerfMetrics.shared.setOn(true)
        PerfMetrics.shared.record("old", start: 0, duration: 0.1)
        PerfMetrics.shared.setOn(false)
        PerfMetrics.shared.setOn(true)
        XCTAssertTrue(PerfMetrics.shared.snapshot().isEmpty)
        PerfMetrics.shared.setOn(false)
    }
}
