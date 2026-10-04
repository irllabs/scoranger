import Foundation
import XCTest

// No import of the app module: this bundle compiles ChordDiagrams.swift in.

/// The on-device half of the chord-diagram contract.
///
/// The golden fragment is cut by engine/scripts/check_chord_diagrams.py from
/// what render.py draws for the PDF. Asserting Swift against the same file is
/// what "the two renderers must stay in step" means here: a change made in one
/// and not the other fails this test or that check, rather than showing up as
/// a page that looks different on the iPad than in the export.
final class ChordDiagramsTests: XCTestCase {

    private func golden() throws -> [(String, Double, Double, Double, Double, String)] {
        let bundle = Bundle(for: Self.self)
        guard let url = bundle.url(forResource: "chord-diagrams-golden",
                                   withExtension: "txt", subdirectory: "Fixtures") else {
            XCTFail("the golden fragment is not in the test bundle")
            return []
        }
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
            .map { line in
                let halves = line.split(separator: "\t", maxSplits: 1)
                let head = halves[0].split(separator: "|").map(String.init)
                return (head[0], Double(head[1])!, Double(head[2])!,
                        Double(head[3])!, Double(head[4])!, String(halves[1]))
            }
    }

    func testDrawsWhatThePDFDraws() throws {
        let cases = try golden()
        XCTAssertFalse(cases.isEmpty)
        for (shapeText, x, top, pitch, scale, expected) in cases {
            let shape = try XCTUnwrap(ChordDiagrams.parseShape(shapeText))
            let drawn = ChordDiagrams.diagramSVG(shape: shape, x: x, topY: top,
                                                 rowPitch: pitch, scale: scale,
                                                 fingers: ChordDiagrams.parseFingering(shapeText))
            XCTAssertEqual(drawn, expected, "\(shapeText) is drawn differently here")
        }
    }

    func testShapeReadsTheNotation() {
        XCTAssertEqual(ChordDiagrams.parseShape("[x,3,2,0,1,0]"), [nil, 3, 2, 0, 1, 0])
        // two digits, which is why the shorthand is comma-separated
        XCTAssertEqual(ChordDiagrams.parseShape("[x,10,12,12,12,10]"),
                       [nil, 10, 12, 12, 12, 10])
        XCTAssertNil(ChordDiagrams.parseShape("a tempo"))
        XCTAssertNil(ChordDiagrams.parseShape("[x,3,2]"))
    }

    func testFingeringReadsTheNotationAndNothingElse() {
        // a G: the frets are 320003 and the hand is 320004 — ring and middle
        // low, PINKY on the top E. Nothing in the six frets says that, so it
        // is carried in the notation and never worked out here.
        XCTAssertEqual(ChordDiagrams.parseShape("[3,2,0,0,0,3](3,2,0,0,0,4)"),
                       [3, 2, 0, 0, 0, 3])
        XCTAssertEqual(ChordDiagrams.parseFingering("[3,2,0,0,0,3](3,2,0,0,0,4)"),
                       [3, 2, 0, 0, 0, 4])
        XCTAssertEqual(ChordDiagrams.parseFingering("[x,5,7,5,6,5](x,1,3,1,2,1)"),
                       [nil, 1, 3, 1, 2, 1])
        // a marker with no fingering names none, and the row shows the frets
        XCTAssertNil(ChordDiagrams.parseFingering("[x,3,2,0,1,0]"))
        XCTAssertNil(ChordDiagrams.parseFingering("a tempo"))
    }

    func testTheMarksRowShowsTheHand() {
        func row(_ svg: String) -> [String] {
            let re = try! NSRegularExpression(pattern: "<tspan font-size=\"[\\d.]+px\">([x\\d]+)</tspan>")
            let ns = svg as NSString
            return re.matches(in: svg, range: NSRange(location: 0, length: ns.length))
                .map { ns.substring(with: $0.range(at: 1)) }
        }
        let g: [Int?] = [3, 2, 0, 0, 0, 3]
        XCTAssertEqual(row(ChordDiagrams.diagramSVG(shape: g, x: 0, topY: 0, rowPitch: 100,
                                                    scale: 1, fingers: [3, 2, 0, 0, 0, 4])),
                       ["3", "2", "0", "0", "0", "4"])
        // and with no fingering the frets stand, which is what the row always was
        XCTAssertEqual(row(ChordDiagrams.diagramSVG(shape: g, x: 0, topY: 0, rowPitch: 100)),
                       ["3", "2", "0", "0", "0", "3"])
    }

    func testTheNutIsTheWindow() {
        // inside the first five frets: drawn against the nut
        XCTAssertEqual(ChordDiagrams.window([nil, 3, 2, 0, 1, 0]).base, 1)
        XCTAssertTrue(ChordDiagrams.window([nil, 3, 2, 0, 1, 0]).nut)
        XCTAssertTrue(ChordDiagrams.window([nil, nil, 0, 5, 5, 5]).nut)
        // higher up: a window, labelled with the fret it starts at
        XCTAssertEqual(ChordDiagrams.window([4, 6, 4, 4, 4, 4]).base, 4)
        XCTAssertFalse(ChordDiagrams.window([4, 6, 4, 4, 4, 4]).nut)
    }

    func testABarreIsOneFingerAcrossTheNeck() {
        let f = ChordDiagrams.barre([1, 3, 3, 2, 1, 1])
        XCTAssertEqual(f?.fret, 1)
        XCTAssertEqual(f?.first, 0)
        XCTAssertEqual(f?.last, 5)
        // one finger, one fret: two fingers that share a fret with nothing
        // above them between are not a barre
        XCTAssertNil(ChordDiagrams.barre([nil, 3, 2, 0, 1, 0]))
        XCTAssertNil(ChordDiagrams.barre([nil, nil, 0, 2, 1, 1]))
        // a finger lying across the neck stops every string it crosses
        XCTAssertNil(ChordDiagrams.barre([4, 6, 4, 4, 0, 4]))
    }

    func testTheBlockIsReservedAndPinnedToOneLevel() {
        let mei = "<measure><dir place=\"above\" tstamp=\"1\" vgrp=\"40\">"
            + "[x,3,2,0,1,0]</dir><dir place=\"above\" tstamp=\"3\">[1,3,3,2,1,1]</dir>"
            + "</measure>"
        let out = try? XCTUnwrap(ChordDiagrams.meiWithDiagrams(mei))
        let text = try! XCTUnwrap(out)
        // one level for every diagram: without this Verovio gives each
        // direction a level of its own and they climb the page in steps
        XCTAssertEqual(text.components(separatedBy: "vgrp=\"1\"").count - 1, 2)
        XCTAssertFalse(text.contains("vgrp=\"40\""))
        // seven rows reserved, and the shape moved into the label
        XCTAssertEqual(text.components(separatedBy: "<lb/>").count - 1,
                       (ChordDiagrams.rows - 1) * 2)
        // and the block grows with the diagram, or an enlarged one draws
        // straight down through the staff underneath it
        let bigger = try! XCTUnwrap(ChordDiagrams.meiWithDiagrams(
            "<measure><dir place=\"above\">[x,3,2,0,1,0]</dir></measure>",
            adjustments: [ChordDiagrams.Adjustment(size: 24)]))
        XCTAssertEqual(bigger.components(separatedBy: "<lb/>").count - 1,
                       ChordDiagrams.rows * 2 - 1)
        XCTAssertTrue(text.contains("label=\"[x,3,2,0,1,0]\""))
        XCTAssertNil(ChordDiagrams.meiWithDiagrams("<measure><dir>a tempo</dir></measure>"))
    }

    func testTheReadersOwnNudgeIsCarried() {
        let xml = """
        <direction><direction-type><words font-size="18" relative-x="20" \
        relative-y="-30">[x,3,2,0,1,0]</words></direction-type></direction>
        <direction><direction-type><words>rit.</words></direction-type></direction>
        """
        let found = ChordDiagrams.adjustments(inMusicXML: xml)
        XCTAssertEqual(found.count, 1, "only the diagrams are counted")
        XCTAssertEqual(found[0], ChordDiagrams.Adjustment(size: 18, dx: 20, dy: -30))

        let mei = "<measure><dir place=\"above\">[x,3,2,0,1,0]</dir></measure>"
        let out = try! XCTUnwrap(ChordDiagrams.meiWithDiagrams(mei, adjustments: found))
        // size rides in the label as a ratio of the drawn size, because
        // Verovio has no per-element text size to ask for
        XCTAssertTrue(out.contains("label=\"[x,3,2,0,1,0]@1.5\""), out)
        // MusicXML measures in tenths and upwards; MEI in half-spaces and down
        XCTAssertTrue(out.contains("ho=\"4\""), out)
        XCTAssertTrue(out.contains("vo=\"-6\""), out)
    }

    func testDrawingReplacesTheReservedBlock() {
        let svg = """
        <g id="a" class="dir"><title class="labelAttr">[x,3,2,0,1,0]</title>\
        <text x="638" y="1443" font-size="0px"><tspan class="text" x="638" y="1443">\
        </tspan><tspan class="text" x="638" y="1833"></tspan></text></g>
        """
        let drawn = ChordDiagrams.draw(in: svg)
        XCTAssertTrue(drawn.contains("chord-diagram"))
        XCTAssertFalse(drawn.contains("labelAttr"), "the marker itself is not drawn")
        XCTAssertTrue(drawn.contains("<path"), "the grid is drawn, not written")
        // a page with no diagram comes back untouched
        XCTAssertEqual(ChordDiagrams.draw(in: "<g class=\"dir\">rit.</g>"),
                       "<g class=\"dir\">rit.</g>")
    }

    /// Diagrams that would meet are drawn smaller (0.18.2), by the rule
    /// render.diagram_fit applies -- check_chord_diagrams.py asserts the same
    /// five numbers on the Python side.
    func testFitMatchesRenderPy() {
        let fits = ChordDiagrams.fit([
            (x: 0, top: 100, pitch: 100, scale: 1),     // 600 wanted, 300 room
            (x: 300, top: 100, pitch: 100, scale: 1),   // 600 wanted, 1000 room
            (x: 1300, top: 100, pitch: 100, scale: 1),  // 100 room: the floor
            (x: 1400, top: 100, pitch: 100, scale: 1),  // last on its line
            (x: 10, top: 900, pitch: 100, scale: 1),    // another line
        ])
        XCTAssertEqual(fits, [0.5, 1.0, 0.5, 1.0, 1.0])
    }

}
