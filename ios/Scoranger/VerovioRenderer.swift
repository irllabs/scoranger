import Foundation
import OSLog
import PDFKit
import SwiftDraw
import VerovioToolkit

/// On-device engraving: MusicXML -> SVG pages (Verovio) -> PDF (SwiftDraw).
/// The toolkit is not thread-safe, so everything runs inside this actor.
actor VerovioRenderer {
    static let shared = VerovioRenderer()

    private var toolkit: VerovioToolkit?

    enum RenderError: Error, LocalizedError {
        case resourcesMissing
        case loadFailed(String)
        /// Verovio itself produced nothing for this page.
        case pageEmpty(Int)
        /// Verovio drew the page and OUR rewrite of it would not parse. A
        /// different failure with a different fix, and it used to report
        /// itself as `emptyPage` -- which sent three people hunting degenerate
        /// notation for a score that was fine (see SVGForSwiftDraw).
        case pageUnconvertible(Int)
        /// Not one page of the score could be drawn.
        case nothingDrawn
        var errorDescription: String? {
            switch self {
            case .resourcesMissing: return "Verovio resources bundle missing"
            case .loadFailed(let p): return "Verovio could not load \(p)"
            case .pageEmpty(let n): return "Verovio drew nothing for page \(n)"
            case .pageUnconvertible(let n):
                return "Page \(n) was engraved but could not be converted for display"
            case .nothingDrawn: return "No page of this version could be drawn"
            }
        }

        var pageNumber: Int? {
            switch self {
            case .pageEmpty(let n), .pageUnconvertible(let n): return n
            case .resourcesMissing, .loadFailed, .nothingDrawn: return nil
            }
        }
    }

    private func tk() throws -> VerovioToolkit {
        if let toolkit { return toolkit }
        let t = VerovioToolkit()
        guard let dataPath = VerovioResources.bundle.path(forResource: "data", ofType: nil),
              t.setResourcePath(dataPath) else {
            throw RenderError.resourcesMissing
        }
        _ = t.setOptions(Self.options(lyricSize: FingeringDiagrams.defaultLyricSize))
        toolkit = t
        return t
    }

    /// A page is a FIXED size: US Letter portrait, which is what the sources
    /// are (the sample PDFs measure 8.5x11 and 8.26x11.69, both portrait).
    ///
    /// This replaces `adjustPageHeight`, which trimmed each page to its own
    /// content. That went in at build 119 for a real reason -- without it a
    /// partly filled last page rendered as a tall white void. But trimming
    /// means a page holding less music is a SHORTER page, which is what Ali's
    /// two-page spread showed: the left page's bottom edge above the right's.
    /// Paper does not do that. White at the bottom of a partial page is
    /// correct; pages of different heights never are.
    ///
    /// These were 816 x 1056 for one build, from measuring an exported PDF and
    /// reading 96 units to the inch off it. That is the arithmetic for the
    /// PDF's physical size, which is applied separately, and it told Verovio
    /// the paper was 82 x 106mm. The engraving was laid out for a postcard:
    /// this quartet paginated to 131 pages of enormous notes.
    ///
    /// The numbers themselves live in `EngravingOptions`, which is pure and so
    /// can be read by the suite; these two names are kept because callers and
    /// `render.py`'s comments refer to them.
    static let pageWidthTenthsMM = EngravingOptions.pageWidthTenthsMM
    static let pageHeightTenthsMM = EngravingOptions.pageHeightTenthsMM

    /// The option set for a layout. See `EngravingOptions` for why every
    /// layout-dependent option is named in BOTH sets: Verovio's `setOptions`
    /// merges, so an option one layout names and the other omits is a value
    /// left behind for the other to find -- which is how one visit to
    /// continuous mode took pagination away from every paged engrave after it.
    static func options(lyricSize: Double, continuous: Bool = false,
                        spacing: StaffSpacing.Values = StaffSpacing.defaults,
                        readerPaginated: Bool = false,
                        measureNumbers: MeasureNumbers.Mode = .system,
                        layOut: Bool = true) -> String {
        EngravingOptions.json(lyricSize: lyricSize, continuous: continuous,
                              spacing: spacing, readerPaginated: readerPaginated,
                              measureNumbers: measureNumbers, layOut: layOut)
    }

    /// One engrave: the pages to draw, and the model to hit-test against.
    ///
    /// Both come from the same Verovio load, which is the whole point — a
    /// selection is only meaningful if the geometry it queries is the geometry
    /// on screen. The PDF is built from the SwiftDraw-flattened SVG; the model
    /// is built from Verovio's own SVG, which still has the class/id structure
    /// the parser needs.
    struct Engraving {
        let pdf: Data
        /// Pages that could not be drawn. The score still opens; these are what
        /// is missing from it.
        var failedPages: [Int] = []
        /// nil when the model could not be built. The page still draws: a
        /// selection that cannot be made is better than a score that cannot be
        /// read.
        let geometry: ScoreGeometry?
        /// What each added mark already carries, by address, so the chip
        /// starts a nudge from the truth in the file rather than from the
        /// default. Matched by document order -- the same 1:1 correspondence
        /// between <harmony> tags and <harm> elements that ChordAdjustments
        /// relies on to place the offsets in the first place, and the same for
        /// the other four kinds.
        var markAdjustments: [ScoreAddress: ChordAdjustments.Adjustment] = [:]
        /// The first pages handed over early (`FirstPages`) do not draw as
        /// this engraving's do. The canvas must then draw these pages afresh
        /// instead of keeping its pictures of those. Never expected: see
        /// `earlyPages`.
        var firstPagesSuperseded = false
    }

    /// The first pages of an engraving, ahead of the rest: the document of
    /// pages 1...n, made exactly as the whole one is
    /// (`PageRasteriser.document`), and how many pages the whole one will
    /// have -- nil when they were laid out from a cut of the score
    /// (`EarlyPages`), before anything knows.
    typealias FirstPages = @Sendable (_ document: Data, _ pageCount: Int?) -> Void

    /// - Parameter firstPages: told once, from a drawing thread, when the
    ///   first `layout.pagesPerUnit` pages are drawn -- what a reader opening
    ///   the score sees first -- while the rest are still being made. Not told
    ///   when one of them could not be drawn, nor for the strip, which is one
    ///   page. The returned `Engraving` is the same with or without it.
    func engrave(musicXMLPath: String, layout: ScoreLayout = .page,
                 firstPages: FirstPages? = nil) throws -> Engraving {
        let continuous = layout.isContinuous
        let t = try tk()
        // The notation, read BEFORE the options: the score's own spacing rides
        // in it, and has to reach Verovio before the load for the same reason
        // the layout does.
        let readSpan = PerfMetrics.shared.begin(PerfMetrics.Name.engraveRead)
        let source = (try? String(contentsOfFile: musicXMLPath, encoding: .utf8)) ?? ""
        let spacing = StaffSpacing.values(inMusicXML: source)
        let paginated = EngravingOptions.readerPaginated(inMusicXML: source)
        let numbering = MeasureNumbers.mode(inMusicXML: source)
        // The user's adjustments live in the MusicXML, and Verovio's importer
        // drops them, so they are carried across here -- for every kind
        // `adjust-element` can reach, not for chord symbols alone.
        let byKind = ChordAdjustments.allAdjustments(inMusicXML: source)
        let chordsOnStaff = ChordPlacement.onStaffFlags(inMusicXML: source)
        let diagramAdjustments = ChordDiagrams.adjustments(inMusicXML: source)
        // A score whose MEI is about to be rewritten is laid out from the
        // rewritten MEI, so its first load needs no layout of its own. The
        // strip is never laid out on load (`breaks` is already `none`).
        // Measured with Verovio 6.2.1 on the six open-speed scores, in paged
        // and reader-paginated layouts: the MEI exported after an unlaid load
        // is the MEI exported after a laid-out one, ids aside.
        let skipFirstLayout = !continuous && MEIRewritePrediction.likely(
            inMusicXML: source, adjustments: byKind, chordsOnStaff: chordsOnStaff,
            diagrams: diagramAdjustments, numbering: numbering)
        readSpan?.end()
        // BEFORE the load: Verovio lays the document out as it reads it, so
        // options set afterwards do not take until something reloads it -- and
        // on a score with no fingerings and no adjustments nothing does. Set
        // here, the very first continuous engrave is already continuous.
        _ = t.setOptions(Self.options(lyricSize: FingeringDiagrams.defaultLyricSize,
                                      continuous: continuous, spacing: spacing,
                                      readerPaginated: paginated,
                                      measureNumbers: numbering,
                                      layOut: !skipFirstLayout))
        let loaded = PerfMetrics.shared.measure(PerfMetrics.Name.engraveLoad) {
            t.loadFile(musicXMLPath)
        }
        guard loaded else {
            throw RenderError.loadFailed(musicXMLPath)
        }
        let meiSpan = PerfMetrics.shared.begin(PerfMetrics.Name.engraveMEI)
        // Whistle fingerings belong above their staff. Verovio ignores
        // MusicXML's lyric placement, so the move is made on the MEI and the
        // document reloaded before anything is drawn.
        var mei = PerfMetrics.shared.measure(PerfMetrics.Name.engraveGetMEI) { t.getMEI("{}") }
        let rewriteSpan = PerfMetrics.shared.begin(PerfMetrics.Name.engraveRewrite)
        // One text size, whatever the score carries: `lyricSize` also sizes
        // chord symbols, so shrinking it for the diagrams halved every chord
        // name on a fingered score. The diagrams are scaled in our own pass.
        // With the layout, too, when the first load went without it.
        _ = t.setOptions(Self.options(lyricSize: FingeringDiagrams.defaultLyricSize,
                                      continuous: continuous, spacing: spacing,
                                      readerPaginated: paginated,
                                      measureNumbers: numbering))

        let rewrites = Rewrites(rows: spacing.rows, chordsOnStaff: chordsOnStaff, byKind: byKind,
                                diagrams: diagramAdjustments, numbering: numbering)
        // A reader opening a score sees its first pages laid out from the bars
        // they need, while the whole score is laid out after them. The cut is
        // taken from the MEI as exported and rewritten on its own, while the
        // whole score is rewritten beside it: the rewrites cost in proportion
        // to the bars ("Espresso", natively: 46 ms whole, 17 ms for its first
        // 24 of 62 bars), and only the cut's rewrites stand between the reader
        // and page 1. The cut rewritten alone is held to the same cut of the
        // rewritten whole, byte for byte, before its page is shown (equal on
        // all six open-speed scores).
        let shownCount = layout.pagesPerUnit
        let rawCut = (skipFirstLayout && firstPages != nil)
            ? EarlyPages.cut(mei: mei, pages: shownCount) : nil
        var reload = false
        var early: (rasters: PageRasteriser.Pipeline, gate: PageRasteriser.FirstPages)?
        if let rawCut, let firstPages {
            let whole = Rewrites.Running(rewrites, of: mei)
            let cutMEI = rewrites.applied(to: rawCut.mei) ?? rawCut.mei
            rewriteSpan?.end()
            early = EarlyPages.rewritten(rawCut, as: cutMEI).flatMap { cut in
                earlyPages(t, cut: cut, count: shownCount, byKind: byKind, handler: firstPages,
                           matchesWhole: {
                               // only a score whose rewritten MEI is what is drawn
                               guard let rewritten = whole.result() else { return false }
                               return EarlyPages.cut(mei: rewritten, pages: shownCount)?.mei == cutMEI
                           })
            }
            if let rewritten = whole.result() {
                mei = rewritten
                reload = true
            }
        } else {
            if let rewritten = rewrites.applied(to: mei) {
                mei = rewritten
                reload = true
            }
            rewriteSpan?.end()
        }
        // The hit-test model's two parses, run beside everything after this
        // as their inputs arrive: the MEI is final now, and each page as it
        // is written. The same MEI the pages are drawn from, so addresses
        // line up.
        let model = ScoreModelBuilder.Concurrent()
        model.start(mei: mei)
        if early == nil, rawCut == nil, reload, !continuous, let firstPages {
            early = EarlyPages.cut(mei: mei, pages: shownCount).flatMap {
                earlyPages(t, cut: $0, count: shownCount, byKind: byKind, handler: firstPages)
            }
        }
        let reloadSpan = PerfMetrics.shared.begin(PerfMetrics.Name.engraveReload)
        if reload {
            guard t.loadData(mei) else { throw RenderError.loadFailed(musicXMLPath) }
        } else if skipFirstLayout {
            // Predicted wrongly: nothing was rewritten, and the document in
            // the toolkit was never laid out. Loaded again from the file with
            // its layout -- NOT from the MEI, which is not always drawn the
            // same as the MusicXML it came from (measured on the accordion
            // solo) -- so the pages are the ones this score always had.
            guard t.loadFile(musicXMLPath) else { throw RenderError.loadFailed(musicXMLPath) }
        }
        reloadSpan?.end()
        meiSpan?.end()
        // Verovio writes every page's SVG alone, and each page starts drawing
        // the moment its SVG exists.
        //
        // The toolkit holds one document and is not thread-safe, so this loop
        // stays exactly as serial as it was; only the drawing, which never
        // touches `t`, runs beside it. Half the wait for a score to open was
        // that drawing, 95 ms a page in a RELEASE build, and it used to wait
        // for the last page's SVG before the first page began. See
        // PageRasteriser.Pipeline for what makes the overlap safe and
        // PageRasteriserTests for the proof.
        var rawPages: [String] = []
        let pageCount = max(t.getPageCount(), 1)
        let first = early != nil ? nil : firstPages.flatMap { handler in
            continuous ? nil : PageRasteriser.FirstPages(
                count: min(shownCount, pageCount),
                handler: { handler($0, pageCount) })
        }
        let rasters = PageRasteriser.Pipeline(
            onDrawn: first.map { watch in { watch.drawn($0) } },
            keepingDrawingsOf: early.map { _ in Set(1...shownCount) } ?? [])
        for page in 1...pageCount {
            let svg = Self.pageSVG(t, page: page, byKind: byKind)
            rawPages.append(svg)
            rasters.start(number: page, svg: svg)
            model.start(page: page - 1, svg: svg)
        }
        // the fidelity dump of a timed open (`OpenTiming`); nothing otherwise
        OpenTiming.shared.dumpRasteriserInput(pages: rawPages, musicXMLPath: musicXMLPath)

        // The model reads Verovio's own SVG and the MEI, not the drawing; its
        // parses ran beside the drawing, and what is timed here is the wait
        // for them and the join.
        let geometry = PerfMetrics.shared.measure(PerfMetrics.Name.engraveModel) {
            try? model.finish(pageCount: rawPages.count)
        }
        let drawn = rasters.finish()
        // The early pages were only ever shown because nothing they depend on
        // was cut away. Held to the whole engraving here regardless, drawing
        // against drawing, so a page that got past `EarlyPages` wrongly is
        // replaced rather than kept.
        var superseded = false
        // (finished first: a page is handed over before its drawing thread
        // leaves the pipeline, so after this `handedOver` is final)
        if let early, case let shown = early.rasters.finish(), early.gate.handedOver {
            let whole = drawn.filter { $0.number <= shownCount }
            superseded = shown.count != whole.count
                || zip(shown, whole).contains { $0.drawing == nil || $0.drawing != $1.drawing }
            if superseded {
                Self.log.error("early first pages differ from the whole engraving: \(musicXMLPath, privacy: .public)")
            } else {
                Self.log.info("early first pages drew as the whole engraving's: \(musicXMLPath, privacy: .public)")
            }
        }

        let (document, left) = PageRasteriser.document(of: drawn)
        let failures: [RenderError] = left.map { page in
            page.failure == .empty ? .pageEmpty(page.number) : .pageUnconvertible(page.number)
        }
        // Only a score with NO drawable page at all is a failure.
        guard document.pageCount > 0, let data = document.dataRepresentation() else {
            throw failures.first ?? RenderError.nothingDrawn
        }
        var marks = Self.byAddress(byKind, in: geometry)
        // a WORD's size is in its verse name, which the MEI holds by id
        let wordScales = LyricLooks.scales(inMEI: mei)
        if !wordScales.isEmpty, let geometry {
            for element in geometry.pages.flatMap(\.elements) where element.kind == .verse {
                if let address = element.address, let scale = wordScales[element.sessionID] {
                    marks[address] = ChordAdjustments.Adjustment(
                        size: scale * ChordAdjustments.defaultChordPoints)
                }
            }
        }
        return Engraving(pdf: data,
                         failedPages: failures.compactMap(\.pageNumber),
                         geometry: geometry,
                         markAdjustments: marks,
                         firstPagesSuperseded: superseded)
    }

    private static let log = Logger(subsystem: "com.irllabs.scoranger", category: "engrave")

    /// One page of the document in the toolkit, as the rasteriser takes it.
    private static func pageSVG(_ t: VerovioToolkit, page: Int,
                                byKind: [ChordAdjustments.Kind: [ChordAdjustments.Adjustment]])
        -> String {
        // size is applied to the drawn glyph, because Verovio has no
        // per-element text size to ask for
        PerfMetrics.shared.measure(PerfMetrics.Name.engraveSVG) {
            // a word's size and style ride in its verse name (0.21.0)
            LyricLooks.apply(to: ChordAdjustments.applySizes(t.renderToSVG(page, true),
                                                             byKind: byKind))
        }
    }

    /// The first `count` pages, laid out from `cut` and handed
    /// to `handler` once drawn -- if what was cut away cannot have changed
    /// them (`EarlyPages`). Leaves the CUT document in the toolkit; the caller
    /// loads the whole one next.
    ///
    /// Why: Verovio's layout is most of an open. "Espresso" laid out whole
    /// took 1.05 s on the simulator and its first 23 bars 0.5 s; natively
    /// 90 ms and 34 ms (Verovio 6.2.1, the six open-speed scores, where every
    /// first page laid out this way matched the whole score's, ids aside).
    /// The whole layout still follows, so the rest of the score and the
    /// model come later by what the cut costs.
    ///
    /// Returns the drawing of the pages and their gate, or nil when the score
    /// gets no early pages.
    ///
    /// `matchesWhole`, when given, is asked last, before anything is shown:
    /// whether the cut laid out is the cut of the score as it will be drawn.
    private func earlyPages(_ t: VerovioToolkit, cut whole: EarlyPages.Cut, count: Int,
                            byKind: [ChordAdjustments.Kind: [ChordAdjustments.Adjustment]],
                            handler: @escaping FirstPages,
                            matchesWhole: (() -> Bool)? = nil)
        -> (rasters: PageRasteriser.Pipeline, gate: PageRasteriser.FirstPages)? {
        let span = PerfMetrics.shared.begin(PerfMetrics.Name.engraveEarly)
        defer { span?.end() }
        var cut = whole
        if count == 1 {
            let inside = EarlyPages.endingInside(cut)
            cut = inside.cut
            if inside.moved > 0 {
                Self.log.info("early pages: \(inside.moved) marks made to end in the cut")
            }
        }
        if let reach = EarlyPages.reachPastCut(cut, throughBar: max(cut.keptMeasures / 2, 1)) {
            Self.log.info("no early pages: \(reach, privacy: .public)")
            return nil
        }
        guard t.loadData(cut.mei) else { return nil }
        let pageCount = t.getPageCount()
        guard pageCount > count else { return nil }
        let gate = PageRasteriser.FirstPages(count: count, awaitsVouch: true,
                                             handler: { handler($0, nil) })
        let rasters = PageRasteriser.Pipeline(onDrawn: { gate.drawn($0) },
                                              keepingDrawingsOf: Set(1...count))
        // drawn while the cut is checked; shown only if it passes
        for page in 1...count {
            rasters.start(number: page, svg: Self.pageSVG(t, page: page, byKind: byKind))
        }
        // The system after the shown pages decides where the last of them
        // breaks, so it must be one the whole score has: complete, which the
        // cut's last system need not be.
        let next = EarlyPages.systemsOnPage(svg: t.renderToSVG(count + 1, true))
        guard let following = next.first, let lastBar = following.last,
              pageCount > count + 1 || next.count >= 2 else {
            gate.withdraw()
            return nil
        }
        if let reach = EarlyPages.reachPastCut(cut, throughMeasure: lastBar) {
            Self.log.info("no early pages: \(reach, privacy: .public)")
            gate.withdraw()
            return nil
        }
        if let matchesWhole, !matchesWhole() {
            Self.log.error("no early pages: the cut rewritten alone is not the rewritten score's cut")
            gate.withdraw()
            return nil
        }
        gate.vouch()
        return (rasters, gate)
    }

    /// Every rewrite an engrave makes of the MEI Verovio exports, before the
    /// document it draws is loaded. Pure string work over the MEI with what was
    /// read from the MusicXML, so it runs on any thread (`Running`).
    struct Rewrites {
        let rows: Int
        let chordsOnStaff: [Bool]
        let byKind: [ChordAdjustments.Kind: [ChordAdjustments.Adjustment]]
        let diagrams: [ChordDiagrams.Adjustment]
        let numbering: MeasureNumbers.Mode

        /// `mei` rewritten, or nil when no rewrite applies to it.
        func applied(to mei: String) -> String? {
            var mei = mei
            var changed = false
            if let above = FingeringDiagrams.meiWithFingeringsAbove(mei, rows: rows) {
                mei = above
                changed = true
            }
            // Real Book placement, for the symbols whose notation asks for it. The
            // PDF renderer used to apply this to EVERY score with a chord symbol
            // and this one to none, so the same file drew its names on the staff in
            // an export and above it here -- and a nudge would have meant two
            // different things. Both read the notation now.
            if let styled = ChordPlacement.meiWithChartStyling(mei, onStaff: chordsOnStaff) {
                mei = styled
                changed = true
            }
            if let placed = ChordAdjustments.meiWithAdjustments(mei, byKind: byKind) {
                mei = placed
                changed = true
            }
            // Chord diagrams: the marker each one rides in reserves one line of
            // text, and a diagram is seven lines tall, so the block is opened up
            // here and the document reloaded around it. render.py does the same on
            // the export side.
            if let opened = ChordDiagrams.meiWithDiagrams(mei, adjustments: diagrams) {
                mei = opened
                changed = true
            }
            // A mark is written to every part so the parts keep it; the combined
            // score would otherwise draw the letter once per staff, on top of
            // itself. render.py does the same on the export side.
            if let deduped = RehearsalMarks.meiWithDedupedMarks(mei) {
                mei = deduped
                changed = true
            }
            // "No measure numbers": Verovio has no option for it, only MEI's own
            // attribute on the score definition. render.py does the same.
            if numbering == .none, let hidden = MeasureNumbers.meiHidingNumbers(mei) {
                mei = hidden
                changed = true
            }
            return changed ? mei : nil
        }

        /// The rewrites of one document, made on another thread from the
        /// moment this is created. Never touches the toolkit.
        final class Running: @unchecked Sendable {
            private let done = DispatchSemaphore(value: 0)
            private let lock = NSLock()
            private var rewritten: String?

            init(_ rewrites: Rewrites, of mei: String) {
                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    let out = rewrites.applied(to: mei)
                    lock.lock()
                    rewritten = out
                    lock.unlock()
                    done.signal()
                }
            }

            /// The rewritten document, or nil when no rewrite applied; waits
            /// for it until it is made.
            func result() -> String? {
                // passed on, so every later ask finds it signalled
                done.wait()
                done.signal()
                lock.lock()
                defer { lock.unlock() }
                return rewritten
            }
        }
    }

    /// Pair each added mark's stored adjustment with its address.
    ///
    /// Both sequences are in document order -- the geometry's elements come
    /// from the same MEI the offsets were written into -- so they zip. A
    /// mismatch in count means the join is unsafe for THAT KIND, and that kind
    /// is dropped rather than returned as a map that is subtly wrong about
    /// which mark is which. Per kind, not all-or-nothing: a score whose text
    /// marks do not line up should still let its dynamics be nudged from the
    /// truth.
    static func byAddress(_ byKind: [ChordAdjustments.Kind: [ChordAdjustments.Adjustment]],
                          in geometry: ScoreGeometry?)
        -> [ScoreAddress: ChordAdjustments.Adjustment] {
        guard let geometry else { return [:] }
        let addresses = geometry.pages.flatMap(\.elements).compactMap(\.address)
        var out: [ScoreAddress: ChordAdjustments.Adjustment] = [:]
        for kind in AddedMark.kinds {
            guard let reading = AddedMark.adjustmentKind(kind),
                  let adjustments = byKind[reading], !adjustments.isEmpty else { continue }
            let drawn = addresses.filter { $0.kind == kind }
            guard drawn.count == adjustments.count else { continue }
            for (address, adjustment) in zip(drawn, adjustments) {
                out[address] = adjustment
            }
        }
        return out
    }

    /// Pages only, for callers with nothing to select (export, iPhone).
    func renderPDF(musicXMLPath: String) throws -> Data {
        try engrave(musicXMLPath: musicXMLPath).pdf
    }

    // MARK: SVG preprocessing
    //
    // SwiftDraw doesn't process Verovio's CSS (`path {stroke:currentColor}`),
    // nested <svg viewBox> scaling, or double-nested <tspan> text — so we
    // rewrite the SVG into the plain subset it does handle. Validated against
    // the desktop toolchain (same output as the browser render).

}
