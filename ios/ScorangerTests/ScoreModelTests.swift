import CoreGraphics
import XCTest

/// Phase A of the selectable vector score: does the model actually know where
/// every element is, and can it name one durably?
///
/// Fixtures come from engine/scripts/make_test_fixture.py: a synthetic
/// four-staff score with chord symbols and ties, rendered twice from
/// independent Verovio loads. Synthetic because the repository is public and
/// committed fixtures must not carry copyrighted music; a pair because the ids
/// differ between the two, so a test that passes on both cannot be leaning on
/// them.
final class ScoreModelTests: XCTestCase {

    private func fixture(_ name: String, _ ext: String) throws -> String {
        let bundle = Bundle(for: Self.self)
        guard let url = bundle.url(forResource: name, withExtension: ext,
                                   subdirectory: "Fixtures") else {
            XCTFail("missing fixture \(name).\(ext)")
            throw CocoaError(.fileNoSuchFile)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func geometry(_ tag: String) throws -> ScoreGeometry {
        try ScoreModelBuilder.build(svgPages: [try fixture("fixture-\(tag)", "svg")],
                                    mei: try fixture("fixture-\(tag)", "mei"))
    }

    // MARK: geometry

    func testParsesPageSizeAndElements() throws {
        let model = try geometry("a")
        let page = try XCTUnwrap(model.page(0))
        XCTAssertGreaterThan(page.size.width, 0)
        XCTAssertGreaterThan(page.size.height, 0)
        // exact counts: the fixture is generated, so these are known quantities
        // (4 bars x 4 beats x 4 staves = 64 notes, 4 bars, 4 chord symbols)
        XCTAssertEqual(page.elements.filter { $0.kind == .note }.count, 64)
        XCTAssertEqual(page.elements.filter { $0.kind == .measure }.count, 4)
        XCTAssertEqual(page.elements.filter { $0.kind == .harm }.count, 4)
    }

    func testEveryElementHasFiniteNonEmptyGeometry() throws {
        let page = try XCTUnwrap(try geometry("a").page(0))
        for element in page.elements {
            XCTAssertTrue(element.frame.width.isFinite && element.frame.height.isFinite,
                          "\(element.kind) \(element.sessionID) has non-finite bounds")
            XCTAssertFalse(element.frame.isNull, "\(element.sessionID) has null bounds")
            XCTAssertGreaterThan(element.frame.width * element.frame.height, 0,
                                 "\(element.kind) \(element.sessionID) has zero area")
        }
    }

    func testElementsSitInsideTheirMeasure() throws {
        let page = try XCTUnwrap(try geometry("a").page(0))
        let measures = page.elements.filter { $0.kind == .measure }
        let notes = page.elements.filter { $0.kind == .note }
        XCTAssertFalse(measures.isEmpty)
        XCTAssertFalse(notes.isEmpty)
        // every note should fall within some measure's box, which is the
        // clearest single check that transforms were composed correctly
        let orphans = notes.filter { note in
            !measures.contains { $0.frame.insetBy(dx: -2, dy: -2).contains(note.frame.origin) }
        }
        XCTAssertTrue(orphans.isEmpty,
                      "\(orphans.count) notes fell outside every measure box")
    }

    // MARK: semantics

    func testNotesCarryMusicalAddresses() throws {
        let page = try XCTUnwrap(try geometry("a").page(0))
        let notes = page.elements.filter { $0.kind == .note }
        let addressed = notes.filter { $0.address != nil }
        XCTAssertEqual(addressed.count, notes.count,
                       "every note in the MEI should resolve to an address")
        let address = try XCTUnwrap(addressed.first?.address)
        XCTAssertGreaterThan(address.measure, 0)
        XCTAssertGreaterThan(address.staff, 0)
        XCTAssertEqual(address.kind, .note)
    }

    func testAddressesAreUniquePerElement() throws {
        let model = try geometry("a")
        let addresses = model.pages.flatMap { $0.elements.compactMap(\.address) }
        XCTAssertEqual(Set(addresses).count, addresses.count,
                       "two elements share an address, so ordinal disambiguation is wrong")
    }

    func testAddressRoundTripsThroughLookup() throws {
        let model = try geometry("a")
        let note = try XCTUnwrap(model.pages.first?.elements.first { $0.kind == .note })
        let address = try XCTUnwrap(note.address)
        XCTAssertEqual(model.element(at: address)?.sessionID, note.sessionID)
    }

    // MARK: the durability claim

    /// Verovio regenerates ids on every load. The whole design rests on
    /// addresses surviving that, so prove both halves: ids differ, addresses
    /// do not.
    func testAddressesSurviveAReRenderThatChangesEveryID() throws {
        let a = try geometry("a")
        let b = try geometry("b")

        let idsA = Set(a.pages.flatMap { $0.elements.map(\.sessionID) })
        let idsB = Set(b.pages.flatMap { $0.elements.map(\.sessionID) })
        XCTAssertTrue(idsA.isDisjoint(with: idsB),
                      "fixtures must come from independent loads with distinct ids")

        let addressesA = Set(a.pages.flatMap { $0.elements.compactMap(\.address) })
        let addressesB = Set(b.pages.flatMap { $0.elements.compactMap(\.address) })
        XCTAssertEqual(addressesA, addressesB,
                       "addresses must be identical across renders — this is what "
                       + "makes a selection persistable")

        // and a selection made in one session resolves in the other
        let noteA = try XCTUnwrap(a.pages.first?.elements.first { $0.kind == .note })
        let address = try XCTUnwrap(noteA.address)
        let resolved = try XCTUnwrap(b.element(at: address),
                                     "an address from session A did not resolve in session B")
        XCTAssertNotEqual(resolved.sessionID, noteA.sessionID, "ids should differ")
        XCTAssertEqual(resolved.address, noteA.address)
    }

    func testGeometryIsStableAcrossRenders() throws {
        let a = try XCTUnwrap(try geometry("a").page(0))
        let b = try XCTUnwrap(try geometry("b").page(0))
        XCTAssertEqual(a.size, b.size)
        XCTAssertEqual(a.elements.count, b.elements.count)
    }

    // MARK: hit-testing

    func testPointHitTestPrefersTheSmallestElement() throws {
        let page = try XCTUnwrap(try geometry("a").page(0))
        let note = try XCTUnwrap(page.elements.first { $0.kind == .note })
        let hit = try XCTUnwrap(page.element(at: CGPoint(x: note.frame.midX,
                                                        y: note.frame.midY)))
        // a measure encloses the note, so without the smallest-wins rule this
        // would return the bar
        XCTAssertNotEqual(hit.kind, .measure,
                          "point hit-testing returned the enclosing measure")
    }

    func testKindFilterRestrictsResults() throws {
        let page = try XCTUnwrap(try geometry("a").page(0))
        let whole = CGRect(origin: .zero, size: page.size)
        let onlyNotes = page.elements(in: whole, kinds: ScoreElementKind.noteLike)
        XCTAssertFalse(onlyNotes.isEmpty)
        XCTAssertTrue(onlyNotes.allSatisfy { ScoreElementKind.noteLike.contains($0.kind) })

        let onlyBars = page.elements(in: whole, kinds: ScoreElementKind.barLike)
        XCTAssertFalse(onlyBars.isEmpty)
        XCTAssertTrue(onlyBars.allSatisfy { $0.kind == .measure })
    }

    func testRectQueryFindsAKnownElement() throws {
        let page = try XCTUnwrap(try geometry("a").page(0))
        let note = try XCTUnwrap(page.elements.first { $0.kind == .note })
        let found = page.elements(in: note.frame.insetBy(dx: -1, dy: -1))
        XCTAssertTrue(found.contains { $0.sessionID == note.sessionID })
    }

    func testLassoSelectsWhatItEnclosesAndNothingElse() throws {
        let page = try XCTUnwrap(try geometry("a").page(0))
        let note = try XCTUnwrap(page.elements.first { $0.kind == .note })

        // a loop drawn snugly around one notehead
        let box = note.frame.insetBy(dx: -note.frame.width, dy: -note.frame.height)
        let lasso = [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                     CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)]
        let caught = page.elements(inLasso: lasso, kinds: ScoreElementKind.noteLike)
        XCTAssertTrue(caught.contains { $0.sessionID == note.sessionID },
                      "the lasso missed the note it was drawn around")

        // and a loop off in empty space catches nothing
        let empty = [CGPoint(x: -500, y: -500), CGPoint(x: -400, y: -500),
                     CGPoint(x: -400, y: -400), CGPoint(x: -500, y: -400)]
        XCTAssertTrue(page.elements(inLasso: empty).isEmpty)
    }

    func testDegenerateLassoSelectsNothing() throws {
        let page = try XCTUnwrap(try geometry("a").page(0))
        XCTAssertTrue(page.elements(inLasso: []).isEmpty)
        XCTAssertTrue(page.elements(inLasso: [.zero, CGPoint(x: 10, y: 10)]).isEmpty,
                      "two points are not a polygon")
    }

    // MARK: selection -> chat

    func testSelectionDescribesItselfInBarsAndStaves() throws {
        let page = try XCTUnwrap(try geometry("a").page(0))
        let notes = Array(page.elements.filter { $0.kind == .note }.prefix(6))
        let selection = ScoreSelection(notes)
        XCTAssertFalse(selection.isEmpty)
        XCTAssertFalse(selection.bars.isEmpty)
        let described = try XCTUnwrap(selection.chatDescription)
        XCTAssertTrue(described.contains("bar"), described)
        XCTAssertTrue(described.contains("staff") || described.contains("staves"), described)
        // no pixels, no estimates: this is what replaces "≈ bars 12–15"
        XCTAssertFalse(described.contains("≈"))
    }

    func testEmptySelectionHasNoChatDescription() {
        XCTAssertNil(ScoreSelection([]).chatDescription)
        XCTAssertTrue(ScoreSelection([]).isEmpty)
    }

    // MARK: the model built beside the drawing

    /// The renderer parses each page as Verovio writes it and the MEI once,
    /// on other threads, and joins them at the end. That has to be the model
    /// `build` makes, page for page and element for element -- started out of
    /// order here, as the threads may finish.
    func testConcurrentModelIsTheBuiltModel() throws {
        let pages = [try fixture("fixture-a", "svg"), try fixture("words-page", "svg"),
                     try fixture("fixture-b", "svg")]
        let mei = try fixture("fixture-a", "mei")
        let built = try ScoreModelBuilder.build(svgPages: pages, mei: mei)
        let concurrent = ScoreModelBuilder.Concurrent()
        concurrent.start(page: 2, svg: pages[2])
        concurrent.start(page: 0, svg: pages[0])
        concurrent.start(mei: mei)
        concurrent.start(page: 1, svg: pages[1])
        let joined = try concurrent.finish(pageCount: pages.count)
        XCTAssertEqual(joined.pages.count, 3)
        XCTAssertEqual(OpenTiming.canonicalJSON(joined), OpenTiming.canonicalJSON(built))
    }

    /// A parse that fails fails the model, as it does in `build`.
    func testConcurrentModelFailsWhereBuildFails() throws {
        let concurrent = ScoreModelBuilder.Concurrent()
        concurrent.start(mei: try fixture("fixture-a", "mei"))
        concurrent.start(page: 0, svg: "<svg")
        XCTAssertThrowsError(try ScoreModelBuilder.build(
            svgPages: ["<svg"], mei: try fixture("fixture-a", "mei")))
        XCTAssertThrowsError(try concurrent.finish(pageCount: 1))
    }

    // MARK: a harder score

    /// The fixture is four staves with chord symbols and ties: the material
    /// the "other" picker will need, and a real test of transform composition
    /// across staves.
    func testComplexScoreIndexesChordSymbolsAndMultipleStaves() throws {
        let model = try ScoreModelBuilder.build(
            svgPages: [try fixture("fixture-a", "svg")],
            mei: try fixture("fixture-a", "mei"))
        let page = try XCTUnwrap(model.page(0))

        let harm = page.elements.filter { $0.kind == .harm }
        XCTAssertFalse(harm.isEmpty, "chord symbols were not indexed")
        XCTAssertTrue(harm.allSatisfy { $0.address != nil },
                      "chord symbols should carry addresses even though MEI puts "
                      + "them under the measure rather than inside a layer")

        let staves = Set(page.elements.compactMap { $0.address?.staff })
        XCTAssertGreaterThanOrEqual(staves.count, 4,
                                    "a quartet page should span at least four staves, saw \(staves)")

        // bars must come out as real numbers, ascending across the page
        let bars = model.bars(of: page.elements)
        XCTAssertGreaterThan(bars.count, 1)
        XCTAssertEqual(bars, bars.sorted())
        XCTAssertGreaterThan(bars.first ?? 0, 0)
    }

    func testComplexScoreLassoAcrossOneStaffStaysOnThatStaff() throws {
        let model = try ScoreModelBuilder.build(
            svgPages: [try fixture("fixture-a", "svg")],
            mei: try fixture("fixture-a", "mei"))
        let page = try XCTUnwrap(model.page(0))
        let topStaff = try XCTUnwrap(page.elements
            .filter { $0.kind == .note && $0.address?.staff == 1 }
            .min { $0.frame.minY < $1.frame.minY })

        // a wide, shallow loop along that staff only
        let band = CGRect(x: 0, y: topStaff.frame.midY - topStaff.frame.height,
                          width: page.size.width,
                          height: topStaff.frame.height * 2)
        let lasso = [CGPoint(x: band.minX, y: band.minY), CGPoint(x: band.maxX, y: band.minY),
                     CGPoint(x: band.maxX, y: band.maxY), CGPoint(x: band.minX, y: band.maxY)]
        let caught = page.elements(inLasso: lasso, kinds: ScoreElementKind.noteLike)
        XCTAssertFalse(caught.isEmpty, "the band caught nothing")
        let hitStaves = Set(caught.compactMap { $0.address?.staff })
        XCTAssertEqual(hitStaves, [1],
                       "a band over one staff pulled in others: \(hitStaves)")
    }

    // MARK: path bounds, the fiddliest part of the parser

    func testPathBoundsHandlesAbsoluteAndRelativeCommands() throws {
        let absolute = try XCTUnwrap(SVGPathBounds.bounds(of: "M0 0 L100 50 Z"))
        XCTAssertEqual(absolute, CGRect(x: 0, y: 0, width: 100, height: 50))

        let relative = try XCTUnwrap(SVGPathBounds.bounds(of: "m10 10 l20 20 z"))
        XCTAssertEqual(relative, CGRect(x: 10, y: 10, width: 20, height: 20))

        let shorthand = try XCTUnwrap(SVGPathBounds.bounds(of: "M0 0 H50 V25"))
        XCTAssertEqual(shorthand, CGRect(x: 0, y: 0, width: 50, height: 25))

        // control points count toward the box: a superset never misses a hit
        let curve = try XCTUnwrap(SVGPathBounds.bounds(of: "M0 0 C10 -20 30 40 40 0"))
        XCTAssertEqual(curve.minY, -20)
        XCTAssertEqual(curve.maxY, 40)

        XCTAssertNil(SVGPathBounds.bounds(of: ""))
    }

    func testTransformParsingComposesInSVGOrder() {
        // translate then scale: the scale applies in the translated frame
        let t = SVGTransform.parse("translate(10, 20) scale(2, 2)")
        let p = CGPoint(x: 1, y: 1).applying(t)
        XCTAssertEqual(p.x, 12, accuracy: 0.001)
        XCTAssertEqual(p.y, 22, accuracy: 0.001)

        XCTAssertEqual(SVGTransform.parse(nil), .identity)
        XCTAssertEqual(SVGTransform.parse("nonsense"), .identity)
    }

    // MARK: - What a drawn path catches (build 124)

    func testAStrokeThroughABarSelectsIt() throws {
        let page = try XCTUnwrap(geometry("a").page(0))
        let note = try XCTUnwrap(page.elements.first { $0.kind == .note })
        // a swipe straight through the notehead: zero area, so the lasso test
        // alone would catch nothing
        let stroke = [CGPoint(x: note.frame.minX - 5, y: note.frame.midY),
                      CGPoint(x: note.frame.maxX + 5, y: note.frame.midY)]
        let caught = page.elements(caughtBy: stroke)
        XCTAssertTrue(caught.contains { $0.sessionID == note.sessionID },
                      "a stroke through an element should select it")
        XCTAssertTrue(page.elements(inLasso: stroke).isEmpty,
                      "the loop test alone catches nothing here — that is the point")
    }

    // MARK: a bar is only ever selected on purpose

    /// Exactly what `AppState.commitSelection` does with what a stroke caught:
    /// addresses out of the elements, into a selection through `combining`.
    /// Nothing here calls `ScoreSelection(_ elements:)` -- and that was the
    /// bug. The filter that keeps a `<measure>` out of a selection lived in
    /// that initializer, which only the TESTS call; the app builds selections
    /// the other way, so the rule was green here and absent on the iPad.
    private func asTheAppBuildsIt(_ caught: [ScoreElement]) -> ScoreSelection {
        ScoreSelection(addresses: []).combining(caught.compactMap(\.address),
                                                mode: .replace)
    }

    /// Ali: a note in the TOP staff was selected, the chip read "1 element
    /// from bar 4", and the highlight painted the whole bar across every
    /// staff. A `<measure>`'s frame spans all the staves, and a stroke catches
    /// what its band touches, so an imprecise swipe on the top staff caught
    /// the measure -- one element, no staff of its own, the whole system lit.
    func testAStrokeNearTheTopStaffDoesNotSelectTheWholeBar() throws {
        let page = try XCTUnwrap(geometry("a").page(0))
        let note = try XCTUnwrap(page.elements
            .filter { $0.kind == .note && $0.address?.staff == 1 }
            .min { $0.frame.minY < $1.frame.minY })
        let stroke = [CGPoint(x: note.frame.minX - 5, y: note.frame.midY),
                      CGPoint(x: note.frame.maxX + 5, y: note.frame.midY)]
        let selection = asTheAppBuildsIt(page.elements(caughtBy: stroke))

        XCTAssertFalse(selection.addresses.contains { $0.kind == .measure },
                       "a stroke on one staff selected the bar: \(selection.addresses)")
        XCTAssertEqual(selection.staves, [1],
                       "the highlight should stay on the staff that was touched")
    }

    /// The same, with nothing under the stroke at all: a swipe through empty
    /// space in a bar used to catch the measure and nothing else, which is a
    /// whole-bar selection nobody asked for.
    func testAStrokeThroughEmptySpaceSelectsNoBar() throws {
        let page = try XCTUnwrap(geometry("a").page(0))
        let measure = try XCTUnwrap(page.elements.first { $0.kind == .measure })
        // just inside the bar, above its first staff, where no glyph is drawn
        let y = measure.frame.minY + 2
        let stroke = [CGPoint(x: measure.frame.minX + 5, y: y),
                      CGPoint(x: measure.frame.maxX - 5, y: y)]
        let selection = asTheAppBuildsIt(page.elements(caughtBy: stroke))
        XCTAssertFalse(selection.addresses.contains { $0.kind == .measure },
                       "empty space selected the whole bar: \(selection.addresses)")
    }

    /// ...and a bar is still reachable the deliberate way. `selectBar` builds
    /// its selection out of the bar's MEMBERS, so a double-tap still lights
    /// the bar up -- element by element, on the staff that was tapped.
    func testABarIsStillSelectableByItsMembers() throws {
        let model = try geometry("a")
        let page = try XCTUnwrap(model.page(0))
        let bar = try XCTUnwrap(page.elements.first { $0.kind == .measure }?.address)
        let members = model.addresses.filter {
            $0.measure == bar.measure && $0.staff == 1
                && !ScoreElementKind.barLike.contains($0.kind)
        }
        XCTAssertFalse(members.isEmpty, "a bar with no members cannot be selected")
        let selection = ScoreSelection(addresses: members)
        XCTAssertEqual(selection.bars, [bar.measure])
        XCTAssertEqual(selection.staves, [1])
    }

    func testALoopStillSelectsWhatItEncloses() throws {
        let page = try XCTUnwrap(geometry("a").page(0))
        let note = try XCTUnwrap(page.elements.first { $0.kind == .note })
        let box = note.frame.insetBy(dx: -12, dy: -12)
        let loop = [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                    CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)]
        XCTAssertTrue(page.elements(caughtBy: loop).contains { $0.sessionID == note.sessionID })
    }

    func testSignedAreaIsZeroForAPathThatDoublesBack() {
        let there = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 0, y: 0)]
        XCTAssertEqual(ScorePage.signedArea(of: there), 0, accuracy: 0.0001)
        let square = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0),
                      CGPoint(x: 10, y: 10), CGPoint(x: 0, y: 10)]
        XCTAssertEqual(abs(ScorePage.signedArea(of: square)), 100, accuracy: 0.0001)
    }

    func testAUnifiedSelectionMixesKindsRatherThanFilteringThem() throws {
        let page = try XCTUnwrap(geometry("a").page(0))
        // the whole page: one selection, every kind on it, no picker
        let whole = [CGPoint(x: 0, y: 0), CGPoint(x: page.size.width, y: 0),
                     CGPoint(x: page.size.width, y: page.size.height),
                     CGPoint(x: 0, y: page.size.height)]
        let kinds = Set(page.elements(caughtBy: whole).map(\.kind))
        XCTAssertTrue(kinds.count > 1,
                      "a lasso over everything should catch more than one kind: \(kinds)")
    }

    func testSelectionReferenceReadsAsBarsAndStaves() throws {
        let page = try XCTUnwrap(geometry("a").page(0))
        let whole = [CGPoint(x: 0, y: 0), CGPoint(x: page.size.width, y: 0),
                     CGPoint(x: page.size.width, y: page.size.height),
                     CGPoint(x: 0, y: page.size.height)]
        let selection = ScoreSelection(page.elements(caughtBy: whole))
        XCTAssertFalse(selection.isEmpty)
        let reference = selection.chatReference
        XCTAssertTrue(reference.hasPrefix("[selection:"), reference)
        XCTAssertTrue(reference.contains("bar"), reference)
        XCTAssertTrue(reference.contains("staff") || reference.contains("staves"), reference)
    }

    func testStaffZeroIsNotReportedAsAStaff() {
        // a measure sits outside any <staff>, so the parser gives it staff 0
        let selection = ScoreSelection(addresses: [
            ScoreAddress(staff: 0, measure: 3, layer: 1, kind: .measure, ordinal: 0),
            ScoreAddress(staff: 4, measure: 3, layer: 1, kind: .note, ordinal: 0)])
        XCTAssertEqual(selection.addresses.count, 1,
                       "a measure handed to a selection is dropped, not kept")
        XCTAssertEqual(selection.staves, [4], "staff 0 is a marker, not a staff")
        XCTAssertFalse(selection.chatReference.contains("0"),
                       selection.chatReference)
        XCTAssertTrue(selection.chatReference.contains("staff 4"),
                      selection.chatReference)
    }

    /// This used to assert how a measures-only selection READ ("bar 2", no
    /// staff). It cannot exist any more: a selection drops bar-like addresses
    /// on the way in, wherever they come from, because a measure's frame spans
    /// every staff and painting it is what Ali saw when he selected one note.
    /// A bar is selected as its members instead.
    func testASelectionOfNothingButMeasuresIsEmpty() {
        let selection = ScoreSelection(addresses: [
            ScoreAddress(staff: 0, measure: 2, layer: 1, kind: .measure, ordinal: 0)])
        XCTAssertTrue(selection.isEmpty, "\(selection.addresses)")
        XCTAssertTrue(selection.staves.isEmpty)
        XCTAssertTrue(selection.bars.isEmpty)
    }

    // MARK: - Who gets the touch (build 124)

    // MARK: - Which staff a bar tap lands on (0.3.1 #3)

    /// A <measure> lives OUTSIDE any <staff> in MEI, so the bar element's own
    /// address carries staff 0 -- the parser's "not staff-specific" marker.
    /// Selecting "the bar on that staff" by comparing against it matched no
    /// element at all, so a double-tap selected nothing and only the
    /// triple-tap (all staves) ever appeared to work. The staff has to come
    /// from where the Pencil is.

    private let bands: [(staff: Int, span: ClosedRange<CGFloat>)] = [
        (staff: 1, span: 100...180),
        (staff: 2, span: 220...300),
        (staff: 3, span: 340...420),
    ]

    func testATapOnTheMiddleStaffPicksTheMiddleStaff() {
        XCTAssertEqual(ScoreGeometry.staff(at: 260, among: bands), 2)
    }

    func testATapOnTheTopStaffPicksTheTopStaff() {
        XCTAssertEqual(ScoreGeometry.staff(at: 140, among: bands), 1)
    }

    func testATapOnTheBottomStaffPicksTheBottomStaff() {
        XCTAssertEqual(ScoreGeometry.staff(at: 400, among: bands), 3)
    }

    /// Staves have gaps between them, and a bar's empty space -- which is
    /// exactly where the user is told to tap -- often falls in one.
    func testATapInTheGapPicksTheNearerStaff() {
        XCTAssertEqual(ScoreGeometry.staff(at: 200, among: bands), 1,
                       "200 is 20 below staff 1 and 20 above staff 2, ties to the first")
        XCTAssertEqual(ScoreGeometry.staff(at: 215, among: bands), 2)
        XCTAssertEqual(ScoreGeometry.staff(at: 310, among: bands), 2)
    }

    func testATapAboveEverythingPicksTheTopStaff() {
        XCTAssertEqual(ScoreGeometry.staff(at: 10, among: bands), 1)
    }

    func testATapBelowEverythingPicksTheBottomStaff() {
        XCTAssertEqual(ScoreGeometry.staff(at: 900, among: bands), 3)
    }

    func testNoStavesMeansNoAnswerRatherThanAGuess() {
        XCTAssertNil(ScoreGeometry.staff(at: 100, among: []))
    }

    /// The single-staff answer must never be staff 0: that is the marker the
    /// bar element itself carries, and using it is the bug.
    func testTheAnswerIsNeverTheNotStaffSpecificMarker() {
        for y in stride(from: CGFloat(0), through: 600, by: 37) {
            XCTAssertNotEqual(ScoreGeometry.staff(at: y, among: bands), 0)
        }
    }
}
