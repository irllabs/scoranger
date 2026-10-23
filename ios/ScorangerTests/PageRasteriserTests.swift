import PDFKit
import XCTest

/// Does drawing the pages of a score on several cores draw the SAME score?
///
/// This suite is the evidence behind the parallel rasteriser, and it exists
/// because the honest answer to "is SwiftDraw thread-safe?" is not a reading of
/// its source. Reading says the two calls on the hot path -- `SVG(data:)` and
/// `pdfData()` -- touch nothing shared: `SVG` is a `Sendable` struct, the URL
/// cache belongs to the `fileURL` initialiser alone, and `pdfData()` builds its
/// own `NSMutableData`, `CGDataConsumer` and `CGContext` every call. Running
/// says whether that reading was complete. A crash or a scrambled page here is
/// a musician on a stand looking at the wrong bar, so it is run, not argued.
///
/// The comparison is against the SERIAL path over the same input, page by page.
/// Not byte-for-byte on the raw output: `CGPDFContext` stamps every file with a
/// `/CreationDate`, a `/ModDate` and a random `/ID`, so two identical drawings
/// made a second apart differ in about forty bytes and in nothing else. Those
/// three fields are neutralised and the rest -- the whole content stream --
/// is compared exactly.
final class PageRasteriserTests: XCTestCase {

    // MARK: - Fixtures

    private func fixture(_ name: String, _ ext: String) throws -> String {
        let bundle = Bundle(for: Self.self)
        guard let url = bundle.url(forResource: name, withExtension: ext,
                                   subdirectory: "Fixtures") else {
            XCTFail("missing fixture \(name).\(ext)")
            throw CocoaError(.fileNoSuchFile)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// `count` pages that are real Verovio engravings and are each DIFFERENT.
    ///
    /// The difference matters more than it looks: the two committed fixtures
    /// are two loads of the same synthetic score, so they draw the same
    /// picture, and a rasteriser that returned its pages shuffled would pass a
    /// test built out of them. A rectangle of a per-page width is added to each
    /// so that page 7's drawing can only be page 7's.
    ///
    /// It goes in before the FINAL `</svg>`: `SVGForSwiftDraw.prepare` rewrites
    /// the first one, which closes Verovio's inner `definition-scale` element.
    private func distinctPages(_ count: Int) throws -> [String] {
        let base = try fixture("fixture-a", "svg")
        guard let close = base.range(of: "</svg>", options: .backwards) else {
            XCTFail("the fixture is not an SVG document"); return []
        }
        return (0..<count).map { i in
            var page = base
            page.replaceSubrange(close, with:
                "<rect x=\"0\" y=\"0\" width=\"\(i + 1)\" height=\"1\" fill=\"black\"/></svg>")
            return page
        }
    }

    // MARK: - Comparing two PDFs that were made at different moments

    /// Blank the three fields Quartz varies per call, so what is left to
    /// compare is the drawing.
    ///
    /// `/CreationDate` and `/ModDate` are fixed-width timestamps and `/ID` is
    /// two fixed-width hex strings, so blanking them in place changes no
    /// length and therefore no byte offset in the cross-reference table: two
    /// identical drawings canonicalise to identical files.
    private func canonical(_ data: Data) -> Data {
        var bytes = [UInt8](data)
        let zero = UInt8(ascii: "0")

        func blankDigits(after marker: String, count: Int) {
            let needle = [UInt8](marker.utf8)
            var i = 0
            while i + needle.count + count <= bytes.count {
                if Array(bytes[i..<(i + needle.count)]) == needle {
                    for j in (i + needle.count)..<(i + needle.count + count) {
                        bytes[j] = zero
                    }
                    i += needle.count + count
                } else {
                    i += 1
                }
            }
        }

        // (D:20260904012116Z00'00') -- 14 digits of timestamp
        blankDigits(after: "(D:", count: 14)

        // /ID [ <6fcf..> <6fcf..> ] -- every hex digit up to the closing bracket
        let idNeedle = [UInt8](("/ID".utf8))
        var i = 0
        while i + idNeedle.count <= bytes.count {
            if Array(bytes[i..<(i + idNeedle.count)]) == idNeedle {
                var j = i + idNeedle.count
                while j < bytes.count, bytes[j] != UInt8(ascii: "]") {
                    let c = bytes[j]
                    let isHex = (c >= 0x30 && c <= 0x39)
                        || (c >= 0x61 && c <= 0x66) || (c >= 0x41 && c <= 0x46)
                    if isHex { bytes[j] = zero }
                    j += 1
                }
                i = j
            } else {
                i += 1
            }
        }
        return Data(bytes)
    }

    private func assertSamePages(_ got: [PageRasteriser.Page],
                                 _ want: [PageRasteriser.Page],
                                 _ what: String,
                                 file: StaticString = #filePath,
                                 line: UInt = #line) {
        XCTAssertEqual(got.count, want.count, "\(what): page count",
                       file: file, line: line)
        guard got.count == want.count else { return }
        for (a, b) in zip(got, want) {
            XCTAssertEqual(a.number, b.number, "\(what): page numbers",
                           file: file, line: line)
            XCTAssertEqual(a.failure, b.failure,
                           "\(what): page \(b.number) failed differently",
                           file: file, line: line)
            switch (a.pdf, b.pdf) {
            case let (x?, y?):
                XCTAssertEqual(canonical(x), canonical(y),
                               "\(what): page \(b.number) drew different bytes "
                               + "(\(x.count) vs \(y.count))",
                               file: file, line: line)
            case (nil, nil):
                break
            default:
                XCTFail("\(what): page \(b.number) drew in one path and not the other",
                        file: file, line: line)
            }
        }
    }

    // MARK: - The claim

    /// The whole point: the same pages, drawn the same, in the same order.
    func testConcurrentRasterisationDrawsTheSamePagesAsSerial() throws {
        let pages = try distinctPages(12)
        let serial = PageRasteriser.rasteriseSerially(pages: pages)
        XCTAssertEqual(serial.compactMap(\.pdf).count, 12,
                       "the fixture no longer draws; this test proves nothing")

        let concurrent = PageRasteriser.rasterise(pages: pages)
        assertSamePages(concurrent, serial, "concurrent vs serial")
    }

    /// The pipeline the engrave uses -- each page started as its SVG arrives,
    /// while the caller goes on making the next -- draws the same pages, in
    /// the same order, as the serial path. Started with a pause between pages
    /// and in a burst, run after run, so both a late page and a pile-up are
    /// covered.
    func testPipelinedRasterisationDrawsTheSamePagesAsSerial() throws {
        let pages = try distinctPages(9)
        let reference = PageRasteriser.rasteriseSerially(pages: pages)
        for run in 0..<6 {
            let pipeline = PageRasteriser.Pipeline()
            for (i, svg) in pages.enumerated() {
                pipeline.start(number: i + 1, svg: svg)
                if run.isMultiple(of: 2) { Thread.sleep(forTimeInterval: 0.002) }
            }
            let drawn = pipeline.finish()
            XCTAssertEqual(drawn.map(\.number), Array(1...9))
            assertSamePages(drawn, reference, "pipelined run \(run)")
        }
    }

    func testAPipelineWithOnePageOrNoneFinishes() throws {
        let one = PageRasteriser.Pipeline()
        let page = try distinctPages(1)[0]
        one.start(number: 1, svg: page)
        assertSamePages(one.finish(), PageRasteriser.rasteriseSerially(pages: [page]),
                        "one page")
        XCTAssertTrue(PageRasteriser.Pipeline().finish().isEmpty)
    }

    /// Run it again and again. A race that shows up one time in ten would pass
    /// a single comparison; the drawing is deterministic, so every run must
    /// agree with the same reference.
    func testConcurrentRasterisationIsStableAcrossRepeatedRuns() throws {
        let pages = try distinctPages(8)
        let reference = PageRasteriser.rasteriseSerially(pages: pages)
        for run in 0..<8 {
            let concurrent = PageRasteriser.rasterise(pages: pages)
            assertSamePages(concurrent, reference, "run \(run)")
        }
    }

    /// Several scores at once, which is the shape a race would most likely take
    /// in the app: nothing serialises two readers' engraves except the actor,
    /// and this asks the rasteriser to answer to more than one caller at a time.
    func testRasterisingSeveralScoresAtOnceKeepsEachOneWhole() throws {
        let pages = try distinctPages(6)
        let reference = PageRasteriser.rasteriseSerially(pages: pages)

        let lock = NSLock()
        var runs: [[PageRasteriser.Page]] = []
        DispatchQueue.concurrentPerform(iterations: 6) { _ in
            let result = PageRasteriser.rasterise(pages: pages)
            lock.lock(); runs.append(result); lock.unlock()
        }
        XCTAssertEqual(runs.count, 6)
        for (i, run) in runs.enumerated() {
            assertSamePages(run, reference, "overlapping engrave \(i)")
        }
    }

    /// Page order is not an accident of which core finished first.
    ///
    /// The pages differ from one another by construction, so this fails if the
    /// results are returned shuffled -- which byte-comparing a set of identical
    /// pages never would.
    func testPagesComeBackNumberedInOrderAndCarryingTheirOwnDrawing() throws {
        let pages = try distinctPages(10)
        let concurrent = PageRasteriser.rasterise(pages: pages)

        XCTAssertEqual(concurrent.map(\.number), Array(1...10))
        for (i, page) in concurrent.enumerated() {
            let alone = PageRasteriser.rasterise(number: i + 1, svg: pages[i])
            XCTAssertEqual(canonical(try XCTUnwrap(page.pdf)),
                           canonical(try XCTUnwrap(alone.pdf)),
                           "page \(i + 1) is carrying another page's drawing")
        }
    }

    /// Pages are numbered from where Verovio numbers them, not from zero.
    func testPageNumbersStartWhereTheCallerSaysTheyDo() throws {
        let pages = try distinctPages(3)
        XCTAssertEqual(PageRasteriser.rasterise(pages: pages, firstNumber: 5)
                        .map(\.number), [5, 6, 7])
    }

    // MARK: - Pages that do not draw

    /// A page that cannot be converted is reported by ITS OWN number, and the
    /// pages around it still draw. Throwing on the first failure once threw
    /// away every good page with it: a reader whose page 1 failed got no score
    /// at all rather than pages 2 to 9.
    func testAnUnconvertiblePageIsNamedAndTheRestOfTheScoreStillDraws() throws {
        var pages = try distinctPages(5)
        pages[2] = "<svg><this is not markup"
        let result = PageRasteriser.rasterise(pages: pages)

        XCTAssertEqual(result.count, 5)
        XCTAssertEqual(result[2].number, 3, "the failure lost its page number")
        XCTAssertNotNil(result[2].failure, "a page that cannot parse was reported as drawn")
        XCTAssertNil(result[2].pdf)
        for i in [0, 1, 3, 4] {
            XCTAssertNil(result[i].failure, "page \(i + 1) was lost with page 3")
            XCTAssertNotNil(result[i].pdf)
        }
    }

    /// An empty page and an unconvertible one are different findings. Reporting
    /// both as "Verovio rendered an empty page" sent three people hunting
    /// degenerate notation for a score that was fine.
    func testAnEmptyPageIsReportedAsEmptyAndNotAsUnconvertible() {
        let result = PageRasteriser.rasterise(number: 4, svg: "")
        XCTAssertEqual(result.failure, .empty)
        XCTAssertEqual(result.number, 4)
    }

    func testAMalformedPageIsReportedAsUnconvertibleAndNotAsEmpty() {
        let result = PageRasteriser.rasterise(number: 2, svg: "<svg><nonsense")
        XCTAssertEqual(result.failure, .unconvertible)
    }

    /// A one-page score takes the serial path (there is nothing to overlap) and
    /// must come back looking exactly the same as a many-page one.
    func testASinglePageScoreIsRasterisedTheSameWay() throws {
        let pages = try distinctPages(1)
        assertSamePages(PageRasteriser.rasterise(pages: pages),
                        PageRasteriser.rasteriseSerially(pages: pages),
                        "single page")
    }

    func testNoPagesIsNoResultsAndNotACrash() {
        XCTAssertTrue(PageRasteriser.rasterise(pages: []).isEmpty)
    }

    // MARK: - The first pages, ahead of the rest

    /// Collects what a `FirstPages` hands over, from whichever thread.
    private final class Handed: @unchecked Sendable {
        private let lock = NSLock()
        private var documents: [Data] = []
        func add(_ data: Data) { lock.lock(); documents.append(data); lock.unlock() }
        var all: [Data] { lock.lock(); defer { lock.unlock() }; return documents }
    }

    /// Opening a score shows pages 1...n the moment they are drawn: handed
    /// over once, holding exactly those pages, however the drawing threads
    /// happen to finish -- and never a later page in their place.
    func testFirstPagesAreHandedOverOnceWhenTheyAreAllDrawn() throws {
        let pages = try distinctPages(7)
        for count in [1, 2] {
            for run in 0..<4 {
                let handed = Handed()
                let first = PageRasteriser.FirstPages(count: count) { handed.add($0) }
                let pipeline = PageRasteriser.Pipeline(onDrawn: { first.drawn($0) })
                for (i, svg) in pages.enumerated() {
                    pipeline.start(number: i + 1, svg: svg)
                    if run.isMultiple(of: 2) { Thread.sleep(forTimeInterval: 0.002) }
                }
                _ = pipeline.finish()
                XCTAssertEqual(handed.all.count, 1, "count \(count), run \(run)")
                let document = try XCTUnwrap(handed.all.first.flatMap { PDFDocument(data: $0) })
                XCTAssertEqual(document.pageCount, count)
            }
        }
    }

    /// The first page a reader is shown is the first page of the document
    /// that replaces it: the canvas keeps its picture of page 1 across the
    /// handover, so the two must draw the same pixels. Both documents are
    /// read back from their bytes, as AppState reads them.
    func testTheFirstPageShownDrawsAsTheWholeDocumentsFirstPage() throws {
        let pages = try distinctPages(5)
        let drawn = PageRasteriser.rasteriseSerially(pages: pages)
        let handed = Handed()
        let first = PageRasteriser.FirstPages(count: 1) { handed.add($0) }
        for page in drawn.reversed() { first.drawn(page) }
        let early = try XCTUnwrap(handed.all.first.flatMap { PDFDocument(data: $0) })
        let (whole, left) = PageRasteriser.document(of: drawn)
        XCTAssertTrue(left.isEmpty)
        let reread = try XCTUnwrap(whole.dataRepresentation().flatMap { PDFDocument(data: $0) })
        XCTAssertEqual(reread.pageCount, 5)
        func pixels(_ document: PDFDocument) throws -> Data {
            let page = try XCTUnwrap(document.page(at: 0))
            let bounds = page.bounds(for: .mediaBox)
            let image = page.thumbnail(of: CGSize(width: bounds.width * 2,
                                                  height: bounds.height * 2), for: .mediaBox)
            return try XCTUnwrap(image.pngData())
        }
        XCTAssertEqual(try pixels(early), try pixels(reread))
        XCTAssertEqual(early.page(at: 0)?.bounds(for: .mediaBox),
                       reread.page(at: 0)?.bounds(for: .mediaBox))
    }

    /// Pages drawn from a cut of the score wait for the renderer to vouch for
    /// them, and pages it withdraws are never shown, however soon they are
    /// drawn.
    func testFirstPagesFromACutWaitToBeVouchedFor() throws {
        let drawn = PageRasteriser.rasteriseSerially(pages: try distinctPages(2))
        let handed = Handed()
        let vouched = PageRasteriser.FirstPages(count: 1, awaitsVouch: true) { handed.add($0) }
        vouched.drawn(drawn[0])
        XCTAssertTrue(handed.all.isEmpty)
        XCTAssertFalse(vouched.handedOver)
        vouched.vouch()
        XCTAssertEqual(handed.all.count, 1)
        XCTAssertTrue(vouched.handedOver)
        vouched.vouch()
        XCTAssertEqual(handed.all.count, 1, "handed over once")

        let refused = Handed()
        let withdrawn = PageRasteriser.FirstPages(count: 1, awaitsVouch: true) { refused.add($0) }
        withdrawn.withdraw()
        withdrawn.drawn(drawn[0])
        withdrawn.vouch()
        XCTAssertTrue(refused.all.isEmpty)
        XCTAssertFalse(withdrawn.handedOver)

        // vouched before the page is drawn: handed over when it is
        let early = Handed()
        let ahead = PageRasteriser.FirstPages(count: 1, awaitsVouch: true) { early.add($0) }
        ahead.vouch()
        XCTAssertTrue(early.all.isEmpty)
        ahead.drawn(drawn[0])
        XCTAssertEqual(early.all.count, 1)
    }

    /// The drawing kept for a page is what tells an early page from the
    /// whole engraving's: equal for the same SVG drawn twice, different for a
    /// page that differs by one rectangle, and kept only where asked.
    func testAKeptDrawingTellsPagesApart() throws {
        let pages = try distinctPages(2)
        let pipeline = PageRasteriser.Pipeline(keepingDrawingsOf: [1, 2])
        pipeline.start(number: 1, svg: pages[0])
        pipeline.start(number: 2, svg: pages[1])
        let kept = pipeline.finish()
        let again = PageRasteriser.rasterise(number: 1, svg: pages[0], keepDrawing: true)
        XCTAssertNotNil(kept[0].drawing)
        XCTAssertEqual(kept[0].drawing, again.drawing)
        XCTAssertNotEqual(kept[0].drawing, kept[1].drawing)
        XCTAssertNil(PageRasteriser.rasterise(number: 1, svg: pages[0]).drawing)
    }

    /// A first page that could not be drawn is not shown early: the score
    /// then appears whole, with the page named, as it always has.
    func testFirstPagesAreNotHandedOverWhenOneOfThemFailed() throws {
        var pages = try distinctPages(3)
        pages[1] = "<svg"
        let handed = Handed()
        let first = PageRasteriser.FirstPages(count: 2) { handed.add($0) }
        let pipeline = PageRasteriser.Pipeline(onDrawn: { first.drawn($0) })
        for (i, svg) in pages.enumerated() { pipeline.start(number: i + 1, svg: svg) }
        let drawn = pipeline.finish()
        XCTAssertTrue(handed.all.isEmpty)
        let (document, left) = PageRasteriser.document(of: drawn)
        XCTAssertEqual(document.pageCount, 2)
        XCTAssertEqual(left.map(\.number), [2])
    }
}
