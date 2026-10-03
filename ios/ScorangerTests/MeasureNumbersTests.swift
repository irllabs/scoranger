import XCTest

/// Which bars the iPad numbers (0.17.0). The engine half, and the count of
/// numbers Verovio actually draws in each mode, is
/// engine/scripts/check_measure_numbers.py; this holds the Swift reader to the
/// same field and the same rewrite.
final class MeasureNumbersTests: XCTestCase {

    private func xml(_ value: String) -> String {
        "<identification><miscellaneous><miscellaneous-field name=\"scoranger-measure-numbers\">"
            + value + "</miscellaneous-field></miscellaneous></identification>"
    }

    func testTheFieldReadsAsTheEngineWritesIt() {
        XCTAssertEqual(MeasureNumbers.mode(inMusicXML: xml("every=1")), .every(1))
        XCTAssertEqual(MeasureNumbers.mode(inMusicXML: xml("every=3")), .every(3))
        XCTAssertEqual(MeasureNumbers.mode(inMusicXML: xml("none")), .none)
        XCTAssertEqual(MeasureNumbers.mode(inMusicXML: "<score-partwise/>"), .system,
                       "a score nobody numbered is numbered the engraver's way")
    }

    /// Lenient: a field this build cannot read draws the default, never no page.
    func testAnUnreadableFieldIsTheDefault() {
        XCTAssertEqual(MeasureNumbers.mode(field: "every=0"), .system)
        XCTAssertEqual(MeasureNumbers.mode(field: "every=65"), .system)
        XCTAssertEqual(MeasureNumbers.mode(field: "every=three"), .system)
        XCTAssertEqual(MeasureNumbers.mode(field: "sometimes"), .system)
    }

    func testTheIntervalIsVerovios() {
        XCTAssertEqual(MeasureNumbers.interval(.every(3)), 3)
        XCTAssertEqual(MeasureNumbers.interval(.system), 0,
                       "0 is Verovio's own: the first bar of each line")
        XCTAssertEqual(MeasureNumbers.interval(.none), 0,
                       "none is the MEI rewrite, not an interval")
    }

    /// setOptions MERGES, so one score's numbering would be the next score's
    /// unless the interval is named every time -- defaults included.
    func testEveryOptionSetNamesTheInterval() {
        for continuous in [false, true] {
            let plain = EngravingOptions.json(lyricSize: 1, continuous: continuous)
            XCTAssertTrue(plain.contains("\"mnumInterval\": 0"), plain)
            let every = EngravingOptions.json(lyricSize: 1, continuous: continuous,
                                              measureNumbers: .every(2))
            XCTAssertTrue(every.contains("\"mnumInterval\": 2"), every)
        }
        XCTAssertTrue(EngravingOptions.scoreDependentKeys.contains("mnumInterval"))
    }

    func testNoneHidesThemOnTheScoreDefinition() {
        let mei = "<mei><scoreDef xml:id=\"s1\" meter.count=\"4\"><staffGrp/></scoreDef></mei>"
        let hidden = MeasureNumbers.meiHidingNumbers(mei)
        XCTAssertEqual(hidden, "<mei><scoreDef xml:id=\"s1\" meter.count=\"4\" mnum.visible=\"false\"><staffGrp/></scoreDef></mei>")
        XCTAssertNil(MeasureNumbers.meiHidingNumbers(hidden ?? ""), "already hidden: nothing to change")
        let shown = "<scoreDef mnum.visible=\"true\"/>"
        XCTAssertEqual(MeasureNumbers.meiHidingNumbers(shown), "<scoreDef mnum.visible=\"false\"/>",
                       "an explicit true is replaced, not left beside the false")
    }
}
