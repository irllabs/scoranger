import CoreGraphics
import XCTest

/// The display list the direct-vector path draws from, pinned against a real
/// Verovio engraving.
///
/// What these assert is deliberately not "the page looks right" -- a page
/// looking right is a person's judgement and is what `ios/tools/vector-compare`
/// exists to put in front of one. What they assert is the set of things that
/// were WRONG in the first pass and were found by looking at the difference
/// image: a `<use>` that resolved to nothing, two text runs stacked on top of
/// each other instead of flowing, a stylesheet rule ignored. Each of those is
/// cheap to reintroduce and invisible in a count of items.
final class VectorPageTests: XCTestCase {

    private func fixture(_ name: String, _ ext: String) throws -> String {
        let bundle = Bundle(for: Self.self)
        guard let url = bundle.url(forResource: name, withExtension: ext,
                                   subdirectory: "Fixtures") else {
            XCTFail("missing fixture \(name).\(ext)")
            throw CocoaError(.fileNoSuchFile)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - The page

    func testARealEngravingBecomesADisplayListInPagePoints() throws {
        let page = try VectorPageParser.parse(fixture("fixture-a", "svg"))
        // The root <svg> carries px width/height and no viewBox, so the page's
        // own units ARE its points. The nested definition-scale element's
        // 21000x29700 grid must not become the page size.
        XCTAssertEqual(page.size.width, 2100, accuracy: 0.5)
        XCTAssertEqual(page.size.height, 2970, accuracy: 0.5)
        XCTAssertGreaterThan(page.items.count, 100)

        // Everything drawn is inside the page, which is the cheapest possible
        // check that the nested viewport was applied at all: without it the
        // content lands ten times off the sheet.
        let bounds = page.contentBounds
        XCTAssertFalse(bounds.isNull)
        XCTAssertGreaterThanOrEqual(bounds.minX, -1)
        XCTAssertGreaterThanOrEqual(bounds.minY, -1)
        XCTAssertLessThanOrEqual(bounds.maxX, page.size.width + 1)
        XCTAssertLessThanOrEqual(bounds.maxY, page.size.height + 1)
    }

    /// Every glyph on a page is defined on that page.
    ///
    /// This is the finding the whole approach rests on -- Verovio embeds the
    /// outline of each glyph a page uses in that page's own `<defs>`, so no
    /// font is read at draw time. If it ever stops being true the renderer
    /// loses noteheads silently, so it is asserted rather than remembered.
    func testEveryGlyphReferenceResolvesWithinItsOwnPage() throws {
        let page = try VectorPageParser.parse(fixture("fixture-a", "svg"))
        let unresolved = page.undrawn.filter { $0.reason.contains("glyph reference") }
        XCTAssertEqual(unresolved, [], "a <use> found no definition on its page")
    }

    func testTheOwningClassIsKeptSoADifferenceCanBeNamed() throws {
        let page = try VectorPageParser.parse(fixture("fixture-a", "svg"))
        let owners = Set(page.items.map(\.owner))
        XCTAssertTrue(owners.contains("staff"))
        XCTAssertTrue(owners.contains("notehead"))
        XCTAssertTrue(owners.contains("stem"))
    }

    /// Staff lines are stroked and noteheads are filled, and a renderer that
    /// only filled would draw a page with no staff on it.
    func testPaintFollowsTheAttributesVerovioWrites() throws {
        let page = try VectorPageParser.parse(fixture("fixture-a", "svg"))
        let staff = page.items.filter { $0.owner == "staff" }
        XCTAssertFalse(staff.isEmpty)
        for item in staff {
            switch item.paint {
            case .stroke, .fillAndStroke: break
            case .fill: XCTFail("a staff line was not stroked")
            }
        }
        let noteheads = page.items.filter { $0.owner == "notehead" }
        XCTAssertFalse(noteheads.isEmpty)
        for item in noteheads {
            XCTAssertEqual(item.paint, .fill, "a notehead was stroked")
        }
    }

    // MARK: - Path data

    /// `S` continues the previous curve, which means reflecting its second
    /// control point through the current point. Verovio's glyph outlines are
    /// full of them, and getting it wrong dents every notehead slightly --
    /// which no count of items would show.
    func testSmoothCubicReflectsThePreviousControlPoint() throws {
        // One curve, then an S that mirrors it: the result must be the same
        // as writing that mirrored control point out by hand.
        let smooth = try XCTUnwrap(SVGPathData.path(
            from: "M0 0 C10 10 20 10 30 0 S50 -10 60 0"))
        let explicit = try XCTUnwrap(SVGPathData.path(
            from: "M0 0 C10 10 20 10 30 0 C40 -10 50 -10 60 0"))
        XCTAssertEqual(smooth.path.boundingBoxOfPath,
                       explicit.path.boundingBoxOfPath)
        XCTAssertEqual(smooth.unsupported, [])
    }

    /// A moveto with more than one pair is a moveto and then LINES. Reading
    /// them as moves breaks every filled glyph into disconnected points.
    func testExtraPairsAfterAMoveAreLines() throws {
        let implicit = try XCTUnwrap(SVGPathData.path(from: "M0 0 10 0 10 10 Z"))
        let explicit = try XCTUnwrap(SVGPathData.path(from: "M0 0 L10 0 L10 10 Z"))
        XCTAssertEqual(implicit.path, explicit.path)
    }

    /// "c-5-5 5-5 10 0" is six numbers with the SIGN doing the separating,
    /// every one of them relative to the current point. Verovio's glyph
    /// outlines are written this way throughout, so a minus read as a
    /// subtraction would deform every notehead on the page.
    ///
    /// Asserted against the absolute spelling of the same curve rather than
    /// against a bounding box: `CGPath.boundingBox` is measured, not
    /// control-point inclusive, so a box says less than it looks like it does.
    func testRelativeCommandsAndSignAsSeparator() throws {
        let relative = try XCTUnwrap(SVGPathData.path(from: "M10 10c-5-5 5-5 10 0z"))
        let absolute = try XCTUnwrap(SVGPathData.path(from: "M10 10C5 5 15 5 20 10Z"))
        XCTAssertEqual(relative.path, absolute.path)
    }

    func testAnArcIsReportedRatherThanPretended() throws {
        let built = try XCTUnwrap(SVGPathData.path(from: "M0 0 A5 5 0 0 1 10 0"))
        XCTAssertEqual(built.unsupported, [.arc])
    }

    // MARK: - Text

    /// Two sibling runs with no x of their own are one line, and the second
    /// starts where the first ended. Drawing both at the <text> element's x
    /// stacked the composer on top of the arranger, which is exactly what the
    /// first side-by-side showed.
    func testSiblingTextRunsFlowRatherThanStack() throws {
        let svg = """
        <svg width="400px" height="100px">
          <g class="dir"><text x="10" y="50" font-size="0px">\
        <tspan class="text"><tspan font-size="20px">Hubert</tspan></tspan>\
        <tspan class="text"><tspan font-size="20px">Giraud</tspan></tspan>\
        </text></g>
        </svg>
        """
        let page = try VectorPageParser.parse(svg)
        XCTAssertEqual(page.items.count, 2, "one item per run")
        let first = page.items[0].path.boundingBoxOfPath
        let second = page.items[1].path.boundingBoxOfPath
        XCTAssertGreaterThanOrEqual(second.minX, first.maxX - 1,
                                    "the second run started inside the first")
    }

    /// A character the chosen face has no glyph for is NAMED, not drawn as a
    /// last-resort box. U+ECA5 is the metronome note Verovio writes as text in
    /// its own music font, and it is the one real gap on these scores.
    func testACharacterWithNoGlyphIsReportedAndNotDrawn() throws {
        let svg = """
        <svg width="400px" height="100px">
          <g class="tempo"><text x="10" y="50" font-size="0px">\
        <tspan class="text"><tspan font-family="Leipzig" font-size="40px">\u{ECA5}</tspan></tspan>\
        </text></g>
        </svg>
        """
        let page = try VectorPageParser.parse(svg)
        XCTAssertEqual(page.items.count, 0, "a box was drawn where a note belongs")
        XCTAssertTrue(page.undrawn.contains { $0.reason.contains("ECA5") },
                      "the missing glyph went unreported: \(page.undrawn)")
    }

    /// `<title>` is a tooltip that lives INSIDE `<text>`. Verovio puts one on
    /// every page number, and drawing its characters prints the word "page"
    /// across the foot of the sheet.
    func testTitleTextIsNotDrawn() throws {
        let svg = """
        <svg width="400px" height="100px">
          <text x="10" y="50" font-size="0px">\
        <tspan class="num"><title class="labelAttr">page</title>\
        <tspan class="text"><tspan font-size="20px">2</tspan></tspan></tspan>\
        </text>
        </svg>
        """
        let page = try VectorPageParser.parse(svg)
        XCTAssertEqual(page.items.count, 1)
        XCTAssertEqual(page.undrawn, [], "the tooltip was treated as notation")
    }

    // MARK: - The flag

    /// OFF unless somebody turned it on. The default is the whole safety
    /// property of this build.
    func testTheRendererIsOffByDefault() {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: VectorRendering.defaultsKey)
        defaults.removeObject(forKey: VectorRendering.defaultsKey)
        XCTAssertFalse(VectorRendering.isOn)
        if let previous { defaults.set(previous, forKey: VectorRendering.defaultsKey) }
    }
}
