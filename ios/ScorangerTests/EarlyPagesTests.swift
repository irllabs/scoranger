import XCTest

/// The cut a score's first pages are laid out from, and the questions asked
/// of it before they are shown (`EarlyPages`).
///
/// Whether the first page of a cut IS the whole score's first page needs
/// Verovio, which this bundle does not link; that was measured on the six
/// open-speed scores and is held, in the app, against the whole engraving
/// every time (`VerovioRenderer.engrave`). What is tested here is the part
/// that is ours: the cut is a well-formed document holding exactly the first
/// bars, and nothing reaching past it gets through.
final class EarlyPagesTests: XCTestCase {

    /// An MEI document of `bars` bars of `notes` notes each, with whatever
    /// `extra(bar)` adds inside a bar (control events), and a volta around
    /// bars `ending`.
    private func mei(bars: Int, notes: Int = 8, ending: ClosedRange<Int>? = nil,
                     extra: (Int) -> String = { _ in "" }) -> String {
        var body = ""
        for bar in 1...bars {
            if bar == ending?.lowerBound { body += "<ending xml:id=\"e1\" n=\"1\">\n" }
            body += "<measure xml:id=\"m\(bar)\" n=\"\(bar)\">\n<staff xml:id=\"s\(bar)\" n=\"1\"><layer n=\"1\">\n"
            for n in 1...notes {
                body += "<note xml:id=\"n\(bar)_\(n)\" pname=\"c\" oct=\"4\" dur=\"8\" />\n"
            }
            body += "</layer></staff>\n\(extra(bar))</measure>\n"
            if bar == ending?.upperBound { body += "</ending>\n" }
            if bar == 3 { body += "<sb xml:id=\"sb1\" />\n" }
        }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <?xml-model href="https://music-encoding.org/schema/5.1/mei-all.rng" type="application/xml"?>
        <mei xmlns="http://www.music-encoding.org/ns/mei" meiversion="5.1">
        <meiHead><fileDesc><titleStmt><title>Cut</title></titleStmt></fileDesc></meiHead>
        <music><body><mdiv xml:id="d1"><score xml:id="sc1">
        <scoreDef xml:id="sd1"><staffGrp><staffDef n="1" lines="5" /></staffGrp></scoreDef>
        <section xml:id="sec1">
        \(body)</section>
        </score></mdiv></body></music>
        </mei>
        """
    }

    private func parses(_ xml: String) -> Bool {
        XMLParser(data: Data(xml.utf8)).parse()
    }

    private func bars(in xml: String) -> Int {
        xml.components(separatedBy: "<measure ").count - 1
    }

    // MARK: - The cut

    func testTheCutKeepsTheFirstBarsAndClosesWhatWasOpen() throws {
        // 8 notes a bar; one page shown aims at two pages of notes
        let source = mei(bars: 200)
        XCTAssertTrue(parses(source))
        let cut = try XCTUnwrap(EarlyPages.cut(mei: source, pages: 1))
        let target = EarlyPages.notesPerPage * 2
        XCTAssertEqual(cut.keptMeasures, (target + 7) / 8)
        XCTAssertEqual(cut.totalMeasures, 200)
        XCTAssertEqual(bars(in: cut.mei), cut.keptMeasures)
        XCTAssertTrue(parses(cut.mei), "the cut is a document of its own")
        XCTAssertTrue(cut.mei.hasSuffix("</section></score></mdiv></body></music></mei>"))
        // everything before the last kept bar is the source, byte for byte
        let end = try XCTUnwrap(cut.mei.range(of: "</measure>", options: .backwards))
        XCTAssertTrue(source.hasPrefix(String(cut.mei[..<end.upperBound])))
    }

    func testAShowingOfTwoPagesCutsLater() throws {
        let one = try XCTUnwrap(EarlyPages.cut(mei: mei(bars: 300), pages: 1))
        let two = try XCTUnwrap(EarlyPages.cut(mei: mei(bars: 300), pages: 2))
        XCTAssertGreaterThan(two.keptMeasures, one.keptMeasures)
    }

    func testAVoltaOpenAtTheCutIsClosed() throws {
        let kept = (EarlyPages.notesPerPage * 2 + 7) / 8
        let source = mei(bars: 200, ending: (kept - 1)...(kept + 2))
        let cut = try XCTUnwrap(EarlyPages.cut(mei: source, pages: 1))
        XCTAssertTrue(parses(cut.mei))
        XCTAssertTrue(cut.mei.hasSuffix("</ending></section></score></mdiv></body></music></mei>"))
    }

    /// A score whose first pages are most of it gains nothing from a cut.
    func testAShortScoreIsNotCut() {
        XCTAssertNil(EarlyPages.cut(mei: mei(bars: 60), pages: 1))
        XCTAssertNil(EarlyPages.cut(mei: mei(bars: 10), pages: 1))
        XCTAssertNil(EarlyPages.cut(mei: "<mei></mei>", pages: 1))
    }

    /// Tags that do not balance are not guessed at.
    func testUnbalancedMarkupIsNotCut() {
        let broken = mei(bars: 200).replacingOccurrences(of: "<section xml:id=\"sec1\">",
                                                         with: "<section xml:id=\"sec1\"><div>")
            .replacingOccurrences(of: "<sb xml:id=\"sb1\" />", with: "</section>")
        XCTAssertNil(EarlyPages.cut(mei: broken, pages: 1))
    }

    // MARK: - What reaches past it

    func testReferencesInsideTheCutPass() throws {
        let source = mei(bars: 200) { bar in
            "<slur xml:id=\"sl\(bar)\" startid=\"#n\(bar)_1\" endid=\"#n\(bar + 1)_2\" />"
            + "<hairpin xml:id=\"h\(bar)\" tstamp=\"1\" tstamp2=\"1m+2\" form=\"cres\" />"
        }
        let cut = try XCTUnwrap(EarlyPages.cut(mei: source, pages: 1))
        // the last kept bar's slur ends past the cut, but that bar is the
        // cut's last system, which is never shown
        XCTAssertNil(EarlyPages.reachPastCut(cut, throughBar: cut.keptMeasures - 1))
        XCTAssertNil(EarlyPages.reachPastCut(cut, throughMeasure: "m\(cut.keptMeasures - 1)"))
        XCTAssertNotNil(EarlyPages.reachPastCut(cut, throughBar: cut.keptMeasures))
    }

    func testAnEndPastTheCutIsCaught() throws {
        let source = mei(bars: 200) { bar in
            bar == 3 ? "<tie xml:id=\"t3\" startid=\"#n3_8\" endid=\"#n150_1\" />" : ""
        }
        let cut = try XCTUnwrap(EarlyPages.cut(mei: source, pages: 1))
        XCTAssertEqual(EarlyPages.reachPastCut(cut, throughBar: 3), "#n150_1 from bar 3")
        XCTAssertNil(EarlyPages.reachPastCut(cut, throughBar: 2))
    }

    /// The OMR hairpin on the quartet: `98m+2`, from bar 6 to the end.
    func testATimestampPastTheCutIsCaught() throws {
        let source = mei(bars: 200) { bar in
            bar == 6 ? "<hairpin xml:id=\"h6\" tstamp=\"2\" tstamp2=\"98m+2\" form=\"dim\" />" : ""
        }
        let cut = try XCTUnwrap(EarlyPages.cut(mei: source, pages: 1))
        XCTAssertEqual(EarlyPages.reachPastCut(cut, throughMeasure: "m10"), "tstamp2 98m from bar 6")
    }

    func testAPlistIsReadWhole() throws {
        let source = mei(bars: 200) { bar in
            bar == 2 ? "<beamSpan xml:id=\"b2\" plist=\"#n2_1 #n2_2 #n180_1\" />" : ""
        }
        let cut = try XCTUnwrap(EarlyPages.cut(mei: source, pages: 1))
        XCTAssertEqual(EarlyPages.reachPastCut(cut, throughBar: 2), "#n180_1 from bar 2")
    }

    func testABarNotInTheCutIsAnsweredNo() throws {
        let cut = try XCTUnwrap(EarlyPages.cut(mei: mei(bars: 200), pages: 1))
        XCTAssertNotNil(EarlyPages.reachPastCut(cut, throughMeasure: "m199"))
        XCTAssertNotNil(EarlyPages.reachPastCut(cut, throughMeasure: "nowhere"))
    }

    // MARK: - A cut rewritten

    /// The renderer rewrites a cut of the exported MEI on its own; the cut it
    /// lays out is then that text, holding the same bars.
    func testACutRewrittenKeepsItsBars() throws {
        let cut = try XCTUnwrap(EarlyPages.cut(mei: mei(bars: 200), pages: 1))
        let moved = cut.mei.replacingOccurrences(of: "oct=\"4\"", with: "oct=\"5\"")
        let rewritten = try XCTUnwrap(EarlyPages.rewritten(cut, as: moved))
        XCTAssertEqual(rewritten.mei, moved)
        XCTAssertEqual(rewritten.keptMeasures, cut.keptMeasures)
        XCTAssertNil(EarlyPages.reachPastCut(rewritten, throughBar: cut.keptMeasures - 1))
        // a text holding other bars is not that cut
        let shorter = cut.mei.replacingOccurrences(of: "<measure xml:id=\"m2\" n=\"2\">",
                                                   with: "<other xml:id=\"m2\" n=\"2\">")
        XCTAssertNil(EarlyPages.rewritten(cut, as: shorter))
    }

    // MARK: - Marks made to end inside the cut

    /// The quartet's two OMR marks, a tie from bar 15 to bar 90 and a hairpin
    /// from bar 6 to the end: both end in the cut's last bar afterwards, on
    /// the staff the tie starts on, and nothing reaches past the cut.
    func testWhatEndsPastTheCutEndsInItsLastBar() throws {
        let source = mei(bars: 200) { bar in
            switch bar {
            case 6: return "<hairpin xml:id=\"h6\" tstamp=\"2\" tstamp2=\"98m+2\" form=\"dim\" />"
            case 15: return "<tie xml:id=\"t15\" startid=\"#n15_8\" endid=\"#n90_1\" />"
            default: return ""
            }
        }
        let cut = try XCTUnwrap(EarlyPages.cut(mei: source, pages: 1))
        XCTAssertNotNil(EarlyPages.reachPastCut(cut, throughBar: 15))
        let inside = EarlyPages.endingInside(cut)
        XCTAssertEqual(inside.moved, 2)
        let kept = cut.keptMeasures
        XCTAssertTrue(inside.cut.mei.contains(
            "<tie xml:id=\"t15\" startid=\"#n15_8\" endid=\"#n\(kept)_8\" />"),
            "the tie ends on the last note of its staff in the last bar")
        XCTAssertTrue(inside.cut.mei.contains("tstamp2=\"\(kept - 6)m+2\""),
                      "the hairpin ends in the last bar")
        XCTAssertNil(EarlyPages.reachPastCut(inside.cut, throughBar: kept))
        XCTAssertEqual(inside.cut.keptMeasures, kept)
        XCTAssertTrue(parses(inside.cut.mei))
    }

    func testACutWithNothingReachingPastIsLeftAsItIs() throws {
        let source = mei(bars: 200) { bar in
            "<slur xml:id=\"sl\(bar)\" startid=\"#n\(bar)_1\" endid=\"#n\(bar)_2\" />"
        }
        let cut = try XCTUnwrap(EarlyPages.cut(mei: source, pages: 1))
        let inside = EarlyPages.endingInside(cut)
        XCTAssertEqual(inside.moved, 0)
        XCTAssertEqual(inside.cut.mei, cut.mei)
    }

    /// Only an END is moved: a list of references is not something whose
    /// drawing on the shown page is known not to depend on what it names.
    func testAPlistPastTheCutStillRefuses() throws {
        let source = mei(bars: 200) { bar in
            bar == 2 ? "<beamSpan xml:id=\"b2\" plist=\"#n2_1 #n2_2 #n180_1\" />" : ""
        }
        let cut = try XCTUnwrap(EarlyPages.cut(mei: source, pages: 1))
        let inside = EarlyPages.endingInside(cut)
        XCTAssertEqual(inside.moved, 0)
        XCTAssertEqual(EarlyPages.reachPastCut(inside.cut, throughBar: 2), "#n180_1 from bar 2")
    }

    /// An end whose start cannot be found is left, and refused.
    func testAnEndWithNoStartToReadIsLeft() throws {
        let source = mei(bars: 200) { bar in
            bar == 3 ? "<tie xml:id=\"t3\" startid=\"#gone\" endid=\"#n150_1\" />" : ""
        }
        let cut = try XCTUnwrap(EarlyPages.cut(mei: source, pages: 1))
        XCTAssertEqual(EarlyPages.endingInside(cut).moved, 0)
    }

    // MARK: - Systems on a page

    func testTheBarsOfEachSystemAreReadOffThePage() {
        let svg = """
        <svg><g id="pg" class="page-margin">
        <g id="sy1" class="system"><g id="a1" class="measure"><g id="st" class="staff"/></g>
        <g id="a2" class="measure"></g></g>
        <g id="sy2" class="system"><g id="a3" class="measure"></g><g id="mn" class="mNum"></g></g>
        <g id="sm" class="systemMilestone"></g>
        </g></svg>
        """
        XCTAssertEqual(EarlyPages.systemsOnPage(svg: svg), [["a1", "a2"], ["a3"]])
        XCTAssertEqual(EarlyPages.systemsOnPage(svg: "<svg></svg>"), [])
    }
}
