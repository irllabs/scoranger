import Foundation
import PDFKit
import SwiftDraw

/// One page of Verovio's SVG turned into a one-page PDF, and the whole score's
/// worth of them turned at once.
///
/// Why this is its own file, out of the renderer: it is the half of an engrave
/// that is OURS. A release-configuration reading of an eight-page score:
///
///     Verovio loadFile        1609 ms   (C++, one call, not ours)
///     SVG -> PDF (SwiftDraw)    95 ms   PER PAGE, serial  -> 1623 ms
///     Verovio renderToSVG       25 ms   per page          ->  455 ms
///     geometry model            71 ms
///
/// Half the wait is a loop over pages that do not depend on each other. Verovio
/// holds one document in one toolkit and must stay serial; this does not.
///
/// It lives in `ScoreModel/` so the suite can reach it without an app, an
/// engine or a screen -- which is the only way the claim that the concurrent
/// path draws the same bytes as the serial one gets to be a claim and not a
/// hope. See `PageRasteriserTests`.
enum PageRasteriser {

    /// Why a page did not draw. Both were once reported as the same thing,
    /// which sent three people hunting degenerate notation for a score that was
    /// fine; the renderer's errors keep them apart and so does this.
    enum Failure: Equatable {
        /// Our rewrite of Verovio's page came out empty.
        case empty
        /// The page was engraved and rewritten, and SwiftDraw would not take it.
        case unconvertible
    }

    /// What became of one page. Exactly one of `pdf` and `failure` is set.
    struct Page: Equatable {
        /// The page number Verovio drew, 1-based -- what an error message says
        /// to the reader, so it survives the trip through the task pool.
        let number: Int
        let pdf: Data?
        let failure: Failure?

        static func drawn(_ number: Int, _ pdf: Data) -> Page {
            Page(number: number, pdf: pdf, failure: nil)
        }
        static func failed(_ number: Int, _ failure: Failure) -> Page {
            Page(number: number, pdf: nil, failure: failure)
        }
    }

    // MARK: - One page

    /// Rewrite one page and draw it.
    ///
    /// Every piece of state this touches is created inside it. `SVGForSwiftDraw`
    /// and the diagram drawers it calls are pure string work over their
    /// argument with no storage of their own; `SVG(data:)` parses into a value
    /// type (a `Sendable` struct of drawing commands) and never consults
    /// SwiftDraw's URL cache, which only the `fileURL` initialiser reads; and
    /// `pdfData()` allocates its own `NSMutableData`, `CGDataConsumer` and
    /// `CGContext` per call. That is what makes `rasterise(pages:)` legal.
    static func rasterise(number: Int, svg: String) -> Page {
        let prepared = SVGForSwiftDraw.prepare(svg)
        guard !prepared.isEmpty else { return .failed(number, .empty) }
        guard let parsed = SVG(data: Data(prepared.utf8)) else {
            return .failed(number, .unconvertible)
        }
        guard let pdf = try? parsed.pdfData() else {
            return .failed(number, .unconvertible)
        }
        return .drawn(number, pdf)
    }

    // MARK: - Every page

    /// The whole score, one page per core, returned IN PAGE ORDER.
    ///
    /// Order is restored rather than relied upon: the pages finish in whatever
    /// order the cores get to them, and a score whose bars 40-52 print before
    /// bars 1-13 is worse than a slow one.
    ///
    /// `concurrentPerform` and not a task group, deliberately. The caller is an
    /// actor holding a Verovio toolkit, and a task group would suspend it --
    /// which lets a second engrave in on the same toolkit while the first is
    /// mid-flight. This blocks the actor's thread exactly as the serial loop it
    /// replaces did, so the guarantee that only one engrave is ever inside the
    /// toolkit is the one that was already there.
    ///
    /// The results are collected under a lock rather than written into a
    /// preallocated array by index: distinct indices of a Swift `Array` are not
    /// a thread-safe destination (the subscript setter checks uniqueness of the
    /// buffer), and a lock held for the length of a dictionary insert is
    /// nothing against 95 ms of drawing.
    static func rasterise(pages: [String], firstNumber: Int = 1) -> [Page] {
        guard pages.count > 1 else {
            return pages.enumerated().map {
                rasterise(number: firstNumber + $0.offset, svg: $0.element)
            }
        }
        let lock = NSLock()
        var done: [Int: Page] = [:]
        done.reserveCapacity(pages.count)
        DispatchQueue.concurrentPerform(iterations: pages.count) { i in
            let span = PerfMetrics.shared.begin(PerfMetrics.Name.engravePDF)
            let page = rasterise(number: firstNumber + i, svg: pages[i])
            span?.end()
            lock.lock()
            done[i] = page
            lock.unlock()
        }
        return (0..<pages.count).compactMap { done[$0] }
    }

    // MARK: - Pages as they are engraved

    /// Draws each page the moment Verovio hands it over.
    ///
    /// `rasterise(pages:)` starts only once every page's SVG exists, and
    /// Verovio makes them one at a time on the renderer actor: on "Espresso"
    /// that was 220 ms of SVG with every core but one idle, then 340 ms of
    /// drawing. Here page 1 is drawing while Verovio writes page 2, and the
    /// actor can build the hit-test model while the last pages finish.
    ///
    /// Each page is the same `rasterise(number:svg:)` the other paths run, on
    /// its own input, so what is drawn does not depend on the order or the
    /// overlap -- the property `PageRasteriserTests` holds the concurrent path
    /// to, and holds this one to as well.
    final class Pipeline: @unchecked Sendable {
        private let group = DispatchGroup()
        private let lock = NSLock()
        private var done: [Int: Page] = [:]
        private var started: [Int] = []
        private var firstStart: TimeInterval?
        /// Told of each page as it is drawn, on the thread that drew it.
        private let onDrawn: (@Sendable (Page) -> Void)?

        /// `onDrawn` hears of each page the moment it is drawn, in whatever
        /// order they finish, which is how the first page reaches the screen
        /// before the last is drawn. It runs on a drawing thread and must not
        /// block it.
        init(onDrawn: (@Sendable (Page) -> Void)? = nil) {
            self.onDrawn = onDrawn
        }

        /// Start drawing one page. Returns at once.
        func start(number: Int, svg: String) {
            lock.lock()
            started.append(number)
            if firstStart == nil { firstStart = PerfClock.now }
            lock.unlock()
            DispatchQueue.global(qos: .userInitiated).async(group: group) { [self] in
                let span = PerfMetrics.shared.begin(PerfMetrics.Name.engravePDF)
                let page = PageRasteriser.rasterise(number: number, svg: svg)
                span?.end()
                lock.lock()
                done[number] = page
                lock.unlock()
                onDrawn?(page)
            }
        }

        /// Every started page, in the order they were started, once all are
        /// drawn. `engravePDFAll` covers the first start to the last finish.
        func finish() -> [Page] {
            group.wait()
            lock.lock()
            defer { lock.unlock() }
            if let firstStart {
                PerfMetrics.shared.record(PerfMetrics.Name.engravePDFAll, start: firstStart,
                                          duration: PerfClock.now - firstStart)
            }
            return started.compactMap { done[$0] }
        }
    }

    // MARK: - The document

    /// The document of the drawn pages, in the order given, and the pages
    /// that could not go in it.
    ///
    /// A page that cannot be drawn is SKIPPED, not fatal. Throwing here meant
    /// one unconvertible page threw away every good page with it: a reader
    /// whose page 1 failed got no score at all rather than pages 2 to 9. The
    /// pages that work are the point. (A page whose PDF will not even open is
    /// left out as `unconvertible`.)
    ///
    /// Serial over a PDFDocument of its own, which is all PDFKit is asked to
    /// bear: the first pages (`FirstPages`) are assembled by this on a drawing
    /// thread while the renderer goes on making the rest, each into its own
    /// document. One function for both is what makes the first page a reader
    /// is shown the page the whole document holds.
    static func document(of drawn: [Page]) -> (PDFDocument, left: [Page]) {
        let document = PDFDocument()
        var left: [Page] = []
        for page in drawn {
            guard let pageData = page.pdf else { left.append(page); continue }
            guard let pageDoc = PDFDocument(data: pageData),
                  let p = pageDoc.page(at: 0) else {
                left.append(.failed(page.number, .unconvertible)); continue
            }
            document.insert(p, at: document.pageCount)
        }
        return (document, left)
    }

    /// Waits for pages 1...count to be drawn, in whatever order the drawing
    /// threads finish them, and hands their document's bytes over ONCE --
    /// never when one of them could not be drawn, since a first page that is
    /// not the score's first page is worse than waiting for the whole score.
    final class FirstPages: @unchecked Sendable {
        private let count: Int
        private let handler: @Sendable (Data) -> Void
        private let lock = NSLock()
        private var got: [Int: Page] = [:]
        private var sent = false

        init(count: Int, handler: @escaping @Sendable (Data) -> Void) {
            self.count = count
            self.handler = handler
        }

        /// Called from a drawing thread with each page as it is drawn
        /// (`Pipeline`'s `onDrawn`).
        func drawn(_ page: Page) {
            guard page.number >= 1, page.number <= count else { return }
            lock.lock()
            got[page.number] = page
            let ready = !sent && got.count == count
            if ready { sent = true }
            let pages = ready ? (1...count).compactMap { got[$0] } : []
            lock.unlock()
            guard ready else { return }
            let (document, left) = PageRasteriser.document(of: pages)
            guard left.isEmpty, document.pageCount == count,
                  let data = document.dataRepresentation() else { return }
            handler(data)
        }
    }

    /// The same work, one page after another. Kept because it is what the
    /// concurrent path is checked AGAINST: a test that only ran the concurrent
    /// path could tell you it did not crash, not that it drew the same score.
    static func rasteriseSerially(pages: [String], firstNumber: Int = 1) -> [Page] {
        pages.enumerated().map {
            rasterise(number: firstNumber + $0.offset, svg: $0.element)
        }
    }
}
