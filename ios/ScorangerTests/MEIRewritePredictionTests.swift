import XCTest

/// `MEIRewritePrediction` decides only whether the first Verovio load of an
/// engrave is laid out; the pages are the same either way (see the type).
/// These hold it to the scores it exists for -- a wrong "no" costs the saving,
/// a wrong "yes" costs one extra load -- and to the score with nothing to
/// rewrite, which must not pay for a load it does not need.
final class MEIRewritePredictionTests: XCTestCase {

    private func likely(_ xml: String,
                        adjustments: [ChordAdjustments.Kind: [ChordAdjustments.Adjustment]] = [:],
                        chordsOnStaff: [Bool] = [],
                        diagrams: [ChordDiagrams.Adjustment] = [],
                        numbering: MeasureNumbers.Mode = .system) -> Bool {
        MEIRewritePrediction.likely(inMusicXML: xml, adjustments: adjustments,
                                    chordsOnStaff: chordsOnStaff, diagrams: diagrams,
                                    numbering: numbering)
    }

    private let plain = """
        <score-partwise><part id="P1"><measure number="1">
        <note><pitch><step>D</step><octave>4</octave></pitch><duration>1</duration></note>
        <harmony><root><root-step>D</root-step></root></harmony>
        </measure></part></score-partwise>
        """

    func testATuneWithNothingToRewriteIsLaidOutOnItsFirstLoad() {
        XCTAssertFalse(likely(plain))
    }

    func testAWhistleColumnIsPredicted() {
        let fingered = plain.replacingOccurrences(
            of: "</note>",
            with: "<lyric name=\"wf\" number=\"1\"><syllabic>single</syllabic><text>X</text></lyric></note>")
        XCTAssertTrue(likely(fingered))
    }

    func testSungWordsAloneAreNotAColumn() {
        let sung = plain.replacingOccurrences(
            of: "</note>",
            with: "<lyric number=\"1\"><syllabic>single</syllabic><text>Love</text></lyric></note>")
        XCTAssertFalse(likely(sung))
    }

    func testAnOffsetMarkIsPredicted() {
        XCTAssertTrue(likely(plain, adjustments: [.dynamic: [ChordAdjustments.Adjustment(dx: 4)]]))
        // a size alone is applied to the drawn SVG, not to the MEI
        XCTAssertFalse(likely(plain, adjustments: [.dynamic: [ChordAdjustments.Adjustment(size: 12)]]))
    }

    func testTheOtherRewritesArePredicted() {
        XCTAssertTrue(likely(plain, chordsOnStaff: [false, true]))
        XCTAssertTrue(likely(plain, diagrams: [ChordDiagrams.Adjustment()]))
        XCTAssertTrue(likely(plain, numbering: .none))
        let one = plain.replacingOccurrences(of: "<harmony>",
                                             with: "<direction><direction-type><rehearsal>A</rehearsal></direction-type></direction><harmony>")
        XCTAssertFalse(likely(one), "one rehearsal mark has nothing to dedupe")
        let two = one.replacingOccurrences(of: "</part>",
                                           with: "</part><part id=\"P2\"><measure number=\"1\"><direction><direction-type><rehearsal>A</rehearsal></direction-type></direction></measure></part>")
        XCTAssertTrue(likely(two))
    }
}
