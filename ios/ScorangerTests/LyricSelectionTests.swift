import XCTest

/// Words on the page are selectable, drawn at their own size and style, and
/// named to the chat model in the engine's own terms (0.21.0).
final class LyricSelectionTests: XCTestCase {

    /// One bar, built to hold every case the ordinal has to survive: verses
    /// written out of order on a note, a whistle column (`wf`) beside a word, a
    /// chord carrying a word, a second layer, and a tab verse on another staff.
    private let mei = """
    <mei><music><body><mdiv><score><section>
    <measure n="3">
     <staff n="1">
      <layer n="1">
       <note xml:id="n1"><verse xml:id="v1b" n="2" label="2"><syl>deux</syl></verse>\
    <verse xml:id="v1a" n="1" label="1"><syl>one</syl></verse></note>
       <note xml:id="n2"><verse xml:id="w1" n="1" label="wf"><syl>X</syl></verse>\
    <verse xml:id="v2" n="8" label="8"><syl>two</syl></verse></note>
       <chord xml:id="c1"><note xml:id="c1a"/><note xml:id="c1b"/>\
    <verse xml:id="v3" n="1" label="ly@1.5~i"><syl>three</syl></verse></chord>
      </layer>
      <layer n="2"><note xml:id="n4"><verse xml:id="v4" n="1" label="1"><syl>four</syl></verse></note></layer>
     </staff>
     <staff n="2"><layer n="1"><note xml:id="n5"><verse xml:id="t1" n="1" label="gt"><syl>3</syl></verse></note></layer></staff>
    </measure>
    </section></score></mdiv></body></music></mei>
    """

    /// ops._elements_in_measure(kind="lyric"): the bar's notes in order across
    /// voices, a chord counted once, each note's words in VERSE order.
    func testAWordsOrdinalIsTheEnginesNotTheLayers() throws {
        let addresses = try MEISemanticsParser.parse(mei)
        func ordinal(_ id: String) -> Int? { addresses[id]?.ordinal }
        XCTAssertEqual(ordinal("v1a"), 0, "verse 1 before verse 2, whatever order the MEI wrote")
        XCTAssertEqual(ordinal("v1b"), 1)
        XCTAssertEqual(ordinal("v2"), 2, "the whistle hole on the same note is not counted")
        XCTAssertEqual(ordinal("v3"), 3, "a chord is one note")
        XCTAssertEqual(ordinal("v4"), 4, "the second layer follows the first, as music21's voices do")
        XCTAssertNil(addresses["w1"], "a fingering is not a word")
        XCTAssertNil(addresses["t1"], "nor is a tab fret")
        XCTAssertEqual(addresses["v3"]?.kind, .verse)
        XCTAssertEqual(addresses["v3"]?.measure, 3)
        XCTAssertEqual(addresses["v3"]?.staff, 1)
        // and the notes keep the per-layer ordinals they always had
        XCTAssertEqual(addresses["n4"]?.ordinal, 0)
        XCTAssertEqual(addresses["n2"]?.ordinal, 1)
    }

    func testAWordIsANoteAttachedMarkWithNoPosition() {
        XCTAssertEqual(AddedMark.engineKind(.verse), "lyric")
        XCTAssertEqual(AddedMark.noun(.verse), "word")
        XCTAssertTrue(AddedMark.isNoteAttached(.verse))
        XCTAssertFalse(AddedMark.takesOffset(.verse))
        XCTAssertTrue(AddedMark.takesOffset(.harm))
        XCTAssertTrue(ScoreSelection(addresses: [
            ScoreAddress(staff: 1, measure: 3, layer: 1, kind: .verse, ordinal: 0),
            ScoreAddress(staff: 1, measure: 3, layer: 1, kind: .verse, ordinal: 2),
        ]).isAdjustable)
    }

    func testAVerseNameSaysHowItsWordIsSet() {
        XCTAssertNil(LyricLooks.look(label: "1"))
        XCTAssertNil(LyricLooks.look(label: "wf"))
        XCTAssertNil(LyricLooks.look(label: "gt@1.5"))
        XCTAssertNil(LyricLooks.look(label: "ly"))
        XCTAssertEqual(LyricLooks.look(label: "ly@1.5"), LyricLooks.Look(scale: 1.5))
        XCTAssertEqual(LyricLooks.look(label: "ly~i"), LyricLooks.Look(scale: nil, italic: true))
        XCTAssertEqual(LyricLooks.look(label: "ly@0.8~bi"),
                       LyricLooks.Look(scale: 0.8, italic: true, bold: true))
    }

    /// The SVG shape Verovio draws a word in, measured from a real engraving.
    func testAWordIsDrawnAtItsSizeAndInItsStyle() {
        let page = """
        <g id="n" class="note"><g id="kb08uz9" class="verse">
        <title class="labelAttr">ly@1.5~i</title>
        <g id="s" class="syl"><text x="4039" y="2478" font-size="0px">\
        <tspan id="t" class="text"><tspan font-size="405px">Ban</tspan></tspan></text></g>
        </g></g>
        <g id="m" class="note"><g id="plain" class="verse">
        <title class="labelAttr">1</title>
        <g id="s2" class="syl"><text x="5000" y="2478" font-size="0px">\
        <tspan id="t2" class="text"><tspan font-size="405px">bridge</tspan></tspan></text></g>
        </g></g>
        """
        let drawn = LyricLooks.apply(to: page)
        XCTAssertTrue(drawn.contains(#"<tspan font-size="607.5px">Ban"#), drawn)
        XCTAssertTrue(drawn.contains(#"font-size="0px" font-style="italic">"#), drawn)
        XCTAssertTrue(drawn.contains(#"<tspan font-size="405px">bridge"#),
                      "a word nobody changed is left exactly as drawn")
        XCTAssertEqual(LyricLooks.apply(to: "<svg/>"), "<svg/>")
    }

    func testTheAdjustRowStartsFromTheWordsOwnSize() {
        let scales = LyricLooks.scales(inMEI: mei)
        XCTAssertEqual(scales, ["v3": 1.5])
    }

    func testSelectedMarksAreNamedTheWayTheToolsTakeThem() {
        let addresses = [
            ScoreAddress(staff: 1, measure: 3, layer: 1, kind: .verse, ordinal: 2),
            ScoreAddress(staff: 2, measure: 5, layer: 1, kind: .harm, ordinal: 0),
            ScoreAddress(staff: 1, measure: 3, layer: 1, kind: .note, ordinal: 1),
        ]
        let names = ["Voice", "Voice"]
        let said = SelectionMarks.describe(addresses, part: {
            SelectionMarks.partReference(staff: $0, names: names)
        })
        XCTAssertEqual(said, [
            ##"part "#0", measure 3, kind lyric, ordinal 2"##,
            ##"part "#1", measure 5, kind harm, ordinal 0"##,
        ], "two parts named Voice are told apart by index, and a note is not a mark")
        XCTAssertEqual(SelectionMarks.partReference(staff: 1, names: ["Violin", "Cello"]), "Violin")
        XCTAssertNil(SelectionMarks.partReference(staff: 3, names: ["Violin", "Cello"]))
    }

    /// The whistle column goes above the staff; the words stay below it, and
    /// on a staff with a column they are numbered from the first line again.
    func testWordsStayBelowALiftedColumnOnTheFirstLines() throws {
        let holes = ["X", "X", "X", "O", "O", "O"].enumerated().map { index, hole in
            #"<verse xml:id="h\#(index)" n="\#(index + 1)" label="wf"><syl>\#(hole)</syl></verse>"#
        }.joined()
        let mei = """
        <measure n="1"><staff n="1"><layer n="1">\
        <note xml:id="a">\(holes)<verse xml:id="w" n="8" label="8"><syl>la</syl></verse></note>\
        <note xml:id="b"><verse xml:id="x" n="8" label="8"><syl>lo</syl></verse></note>\
        </layer></staff><staff n="2"><layer n="1">\
        <note xml:id="c"><verse xml:id="y" n="8" label="8"><syl>other</syl></verse></note>\
        </layer></staff></measure>
        """
        let lifted = try XCTUnwrap(FingeringDiagrams.meiWithFingeringsAbove(mei, rows: 6))
        XCTAssertTrue(lifted.contains(#"<verse xml:id="w" n="1" label="8">"#),
                      "the word under the column is drawn on the first line: \(lifted)")
        XCTAssertTrue(lifted.contains(#"<verse xml:id="x" n="1" label="8">"#),
                      "and so is its neighbour with no column, on the same staff")
        XCTAssertTrue(lifted.contains(#"<verse xml:id="y" n="8" label="8">"#),
                      "a staff with no column keeps its numbering")
        XCTAssertFalse(lifted.contains(#"place="above" xml:id="w""#)
                       || lifted.contains(#"<verse place="above" xml:id="w""#),
                       "the word is not lifted with the holes")
        XCTAssertTrue(lifted.contains(#"<verse place="above" xml:id="h0""#))
    }

    /// A TAP on a word selects that word, on a real Verovio page: two verses
    /// written out of order, a whistle column lifted above the staff, the MEI
    /// it was drawn from (check_lyrics.py --write-fixture). The smallest frame
    /// under a point wins, and a word's frame is smaller than its note's,
    /// which runs down over it.
    func testATapOnAWordSelectsThatWord() throws {
        let bundle = Bundle(for: Self.self)
        let svg = try String(contentsOf: XCTUnwrap(bundle.url(
            forResource: "words-page", withExtension: "svg", subdirectory: "Fixtures")),
                             encoding: .utf8)
        let mei = try String(contentsOf: XCTUnwrap(bundle.url(
            forResource: "words-page", withExtension: "mei", subdirectory: "Fixtures")),
                             encoding: .utf8)
        let geometry = try ScoreModelBuilder.build(svgPages: [svg], mei: mei)
        let page = try XCTUnwrap(geometry.pages.first)
        let words = page.elements.filter { $0.kind == .verse }
        let addressed = words.compactMap(\.address)
        let labels = try NSRegularExpression(pattern: #"<verse\b[^>]*label="(\d+)""#)
        let sung = labels.numberOfMatches(in: mei, range: NSRange(location: 0, length: (mei as NSString).length))
        XCTAssertGreaterThan(sung, 10)
        XCTAssertEqual(addressed.count, sung, "every word has an address; no hole of the column has one")
        XCTAssertEqual(Set(addressed).count, addressed.count, "and no two share one")
        for bar in Set(addressed.map(\.measure)) {
            XCTAssertEqual(addressed.filter { $0.measure == bar }.map(\.ordinal).sorted(),
                           Array(0..<addressed.filter { $0.measure == bar }.count),
                           "bar \(bar)'s words are numbered 0, 1, 2... as the engine numbers them")
        }
        for word in words {
            let hit = page.element(at: CGPoint(x: word.frame.midX, y: word.frame.midY))
            XCTAssertEqual(hit?.kind, .verse, "a tap on \(word.address?.description ?? "?") caught \(hit?.kind.rawValue ?? "nothing")")
            XCTAssertEqual(hit?.address, word.address)
        }
    }
}

