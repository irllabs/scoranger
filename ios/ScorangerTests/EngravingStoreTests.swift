import CoreGraphics
import XCTest

/// An engraving kept on disk must come back as the engraving that went in --
/// the same PDF bytes, and a geometry the fidelity check cannot tell from the
/// original -- and must never come back for anything it was not made from.
final class EngravingStoreTests: XCTestCase {

    private func fixture(_ name: String, _ ext: String) throws -> String {
        let bundle = Bundle(for: Self.self)
        guard let url = bundle.url(forResource: name, withExtension: ext,
                                   subdirectory: "Fixtures") else {
            XCTFail("missing fixture \(name).\(ext)")
            throw CocoaError(.fileNoSuchFile)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Two real models as two pages, so element order, several pages and
    /// addresses of every kind are all in the round trip.
    private func contents() throws -> EngravingArchive.Contents {
        let a = try ScoreModelBuilder.build(svgPages: [try fixture("fixture-a", "svg")],
                                            mei: try fixture("fixture-a", "mei"))
        let words = try ScoreModelBuilder.build(svgPages: [try fixture("words-page", "svg")],
                                                mei: try fixture("words-page", "mei"))
        let pages = a.pages + words.pages.map {
            ScorePage(index: $0.index + a.pages.count, size: $0.size, elements: $0.elements,
                      drawnSystems: $0.drawnSystems)
        }
        let geometry = ScoreGeometry(pages: pages)
        XCTAssertGreaterThan(geometry.elementCount, 50, "the fixtures no longer build a model")
        let addresses = geometry.pages.flatMap(\.elements).compactMap(\.address)
        var marks: [ScoreAddress: ChordAdjustments.Adjustment] = [:]
        marks[addresses[0]] = ChordAdjustments.Adjustment(size: 13.5)
        marks[addresses[1]] = ChordAdjustments.Adjustment(dx: -0.1, dy: 1.0 / 3.0)
        return EngravingArchive.Contents(pdf: Data((0..<4096).map { UInt8($0 % 251) }),
                                         failedPages: [3, 7], geometry: geometry,
                                         marks: marks)
    }

    // MARK: - The archive

    func testTheRoundTripIsTheSameEngraving() throws {
        let original = try contents()
        let back = try XCTUnwrap(EngravingArchive.decode(EngravingArchive.encode(original)))
        XCTAssertEqual(back.pdf, original.pdf)
        XCTAssertEqual(back.failedPages, original.failedPages)
        XCTAssertEqual(back.marks, original.marks)
        let a = try XCTUnwrap(original.geometry), b = try XCTUnwrap(back.geometry)
        XCTAssertEqual(OpenTiming.canonicalJSON(b), OpenTiming.canonicalJSON(a))
        // what the canonical form rounds and leaves out: exact frames and ids
        for (p, q) in zip(a.pages, b.pages) {
            XCTAssertEqual(p.elements, q.elements)
            XCTAssertEqual(p.size, q.size)
            XCTAssertEqual(p.barFrames.map(\.frame), q.barFrames.map(\.frame))
        }
        XCTAssertEqual(Set(a.addresses), Set(b.addresses))
        // and the same bytes again, so an entry is a function of the engraving
        XCTAssertEqual(EngravingArchive.encode(back), EngravingArchive.encode(original))
    }

    func testAnEngravingWithNoModelRoundTrips() throws {
        let original = EngravingArchive.Contents(pdf: Data([1, 2, 3]), failedPages: [],
                                                 geometry: nil, marks: [:])
        let back = try XCTUnwrap(EngravingArchive.decode(EngravingArchive.encode(original)))
        XCTAssertNil(back.geometry)
        XCTAssertEqual(back.pdf, original.pdf)
    }

    func testADamagedArchiveIsNothingRatherThanSomethingWrong() throws {
        let bytes = EngravingArchive.encode(try contents())
        for cut in [0, 4, 9, bytes.count / 2, bytes.count - 1] {
            XCTAssertNil(EngravingArchive.decode(bytes.prefix(cut)), "cut at \(cut)")
        }
        XCTAssertNil(EngravingArchive.decode(bytes + Data([0])), "trailing byte")
        var newer = bytes
        newer[4] = 99   // the format number
        XCTAssertNil(EngravingArchive.decode(newer))
    }

    // MARK: - The store

    private func store(budget: Int = 1 << 30, identity: String = "build-1") throws -> EngravingStore {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "engraving-store-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return EngravingStore(directory: dir, budget: budget, identity: identity, writeDelay: nil)
    }

    func testAKeptEngravingIsRecalledByTheSameKey() throws {
        let s = try store()
        let key = s.key(musicXML: Data("<score/>".utf8), engraving: "paged")
        XCTAssertNil(s.recall(key))
        s.keep(try contents(), under: key)
        s.settle()
        XCTAssertEqual(s.recall(key)?.pdf, try contents().pdf)
    }

    /// Everything the pages are made from is in the key.
    func testTheKeyChangesWithTheFileTheLayoutAndTheBuild() throws {
        let s = try store()
        let xml = Data("<score-partwise>…</score-partwise>".utf8)
        let base = s.key(musicXML: xml, engraving: "paged")
        XCTAssertEqual(base, s.key(musicXML: xml, engraving: "paged"))
        XCTAssertNotEqual(base, s.key(musicXML: xml + Data(" ".utf8), engraving: "paged"))
        XCTAssertNotEqual(base, s.key(musicXML: xml, engraving: "continuous"))
        XCTAssertNotEqual(base, try store(identity: "build-2").key(musicXML: xml, engraving: "paged"))
    }

    func testTheLeastRecentlyUsedGoFirstPastTheBudget() throws {
        let one = try contents()
        let size = EngravingArchive.encode(one).count
        let s = try store(budget: size * 2 + size / 2)
        let keys = (0..<3).map { s.key(musicXML: Data([UInt8($0)]), engraving: "paged") }
        s.keep(one, under: keys[0]); s.settle()
        Thread.sleep(forTimeInterval: 1.1)   // file dates are kept to the second
        s.keep(one, under: keys[1]); s.settle()
        Thread.sleep(forTimeInterval: 1.1)
        XCTAssertNotNil(s.recall(keys[0]), "reading it makes it the most recent")
        Thread.sleep(forTimeInterval: 1.1)
        s.keep(one, under: keys[2]); s.settle()
        XCTAssertNotNil(s.recall(keys[0]))
        XCTAssertNil(s.recall(keys[1]), "the least recently used was not the one to go")
        XCTAssertNotNil(s.recall(keys[2]))
    }

    func testAnEntryThatWillNotDecodeIsRemoved() throws {
        let s = try store()
        let key = s.key(musicXML: Data("x".utf8), engraving: "paged")
        try FileManager.default.createDirectory(at: s.directory, withIntermediateDirectories: true)
        try Data("not an engraving".utf8).write(to: s.directory.appending(path: key))
        XCTAssertNil(s.recall(key))
        XCTAssertFalse(FileManager.default.fileExists(atPath: s.directory.appending(path: key).path))
    }
}
