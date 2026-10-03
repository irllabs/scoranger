import Foundation
import PDFKit
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
                        measureNumbers: MeasureNumbers.Mode = .system) -> String {
        EngravingOptions.json(lyricSize: lyricSize, continuous: continuous,
                              spacing: spacing, readerPaginated: readerPaginated,
                              measureNumbers: measureNumbers)
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
    }

    func engrave(musicXMLPath: String, layout: ScoreLayout = .page) throws -> Engraving {
        let continuous = layout.isContinuous
        let t = try tk()
        // The notation, read BEFORE the options: the score's own spacing rides
        // in it, and has to reach Verovio before the load for the same reason
        // the layout does.
        let source = (try? String(contentsOfFile: musicXMLPath, encoding: .utf8)) ?? ""
        let spacing = StaffSpacing.values(inMusicXML: source)
        let paginated = EngravingOptions.readerPaginated(inMusicXML: source)
        let numbering = MeasureNumbers.mode(inMusicXML: source)
        // BEFORE the load: Verovio lays the document out as it reads it, so
        // options set afterwards do not take until something reloads it -- and
        // on a score with no fingerings and no adjustments nothing does. Set
        // here, the very first continuous engrave is already continuous.
        _ = t.setOptions(Self.options(lyricSize: FingeringDiagrams.defaultLyricSize,
                                      continuous: continuous, spacing: spacing,
                                      readerPaginated: paginated,
                                      measureNumbers: numbering))
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
        var mei = t.getMEI("{}")
        // One text size, whatever the score carries: `lyricSize` also sizes
        // chord symbols, so shrinking it for the diagrams halved every chord
        // name on a fingered score. The diagrams are scaled in our own pass.
        _ = t.setOptions(Self.options(lyricSize: FingeringDiagrams.defaultLyricSize,
                                      continuous: continuous, spacing: spacing,
                                      readerPaginated: paginated,
                                      measureNumbers: numbering))

        // The user's adjustments live in the MusicXML, and Verovio's importer
        // drops them, so they are carried across here -- for every kind
        // `adjust-element` can reach, not for chord symbols alone.
        let byKind = ChordAdjustments.allAdjustments(inMusicXML: source)

        var reload = false
        if let above = FingeringDiagrams.meiWithFingeringsAbove(mei, rows: spacing.rows) {
            mei = above
            reload = true
        }
        // Real Book placement, for the symbols whose notation asks for it. The
        // PDF renderer used to apply this to EVERY score with a chord symbol
        // and this one to none, so the same file drew its names on the staff in
        // an export and above it here -- and a nudge would have meant two
        // different things. Both read the notation now.
        if let styled = ChordPlacement.meiWithChartStyling(
            mei, onStaff: ChordPlacement.onStaffFlags(inMusicXML: source)) {
            mei = styled
            reload = true
        }
        if let placed = ChordAdjustments.meiWithAdjustments(mei, byKind: byKind) {
            mei = placed
            reload = true
        }
        // Chord diagrams: the marker each one rides in reserves one line of
        // text, and a diagram is seven lines tall, so the block is opened up
        // here and the document reloaded around it. render.py does the same on
        // the export side.
        if let diagrams = ChordDiagrams.meiWithDiagrams(
            mei, adjustments: ChordDiagrams.adjustments(inMusicXML: source)) {
            mei = diagrams
            reload = true
        }
        // A mark is written to every part so the parts keep it; the combined
        // score would otherwise draw the letter once per staff, on top of
        // itself. render.py does the same on the export side.
        if let deduped = RehearsalMarks.meiWithDedupedMarks(mei) {
            mei = deduped
            reload = true
        }
        // "No measure numbers": Verovio has no option for it, only MEI's own
        // attribute on the score definition. render.py does the same.
        if numbering == .none, let hidden = MeasureNumbers.meiHidingNumbers(mei) {
            mei = hidden
            reload = true
        }
        if reload {
            guard t.loadData(mei) else { throw RenderError.loadFailed(musicXMLPath) }
        }
        meiSpan?.end()
        // Verovio draws every page FIRST, and alone.
        //
        // The toolkit holds one document and is not thread-safe, so this loop
        // stays exactly as serial as it was. It is also the last thing in this
        // method that touches `t` -- which is what lets the drawing below run
        // on several cores at once.
        var rawPages: [String] = []
        for page in 1...max(t.getPageCount(), 1) {
            // size is applied to the drawn glyph, because Verovio has no
            // per-element text size to ask for
            let svg = PerfMetrics.shared.measure(PerfMetrics.Name.engraveSVG) {
                ChordAdjustments.applySizes(t.renderToSVG(page, true),
                                            byKind: byKind)
            }
            rawPages.append(svg)
        }

        // ...and then every page is drawn at once. Half the wait for a score to
        // open was this loop: 95 ms a page in a RELEASE build, one after
        // another, against 1609 ms of Verovio C++ nobody here can shorten.
        // Nothing in it depends on anything else in it. See PageRasteriser for
        // what makes that safe and PageRasteriserTests for the proof.
        let drawn = PerfMetrics.shared.measure(PerfMetrics.Name.engravePDFAll) {
            PageRasteriser.rasterise(pages: rawPages)
        }

        // Assembling the document stays here, serial and on the actor. PDFKit
        // promises nothing about concurrent use and this costs nothing: what
        // was expensive is already done.
        let document = PDFDocument()
        /// Pages that could not be drawn, kept so the caller can say which.
        var failures: [RenderError] = []
        for page in drawn {
            // A page that cannot be drawn is SKIPPED, not fatal. Throwing here
            // meant one unconvertible page threw away every good page with it:
            // a reader whose page 1 failed got no score at all rather than
            // pages 2 to 9. The pages that work are the point.
            guard let pageData = page.pdf else {
                switch page.failure {
                case .empty: failures.append(.pageEmpty(page.number))
                case .unconvertible, .none:
                    failures.append(.pageUnconvertible(page.number))
                }
                continue
            }
            guard let pageDoc = PDFDocument(data: pageData),
                  let p = pageDoc.page(at: 0) else {
                failures.append(.pageUnconvertible(page.number)); continue
            }
            document.insert(p, at: document.pageCount)
        }
        // Only a score with NO drawable page at all is a failure.
        guard document.pageCount > 0, let data = document.dataRepresentation() else {
            throw failures.first ?? RenderError.nothingDrawn
        }
        // the same MEI the pages were drawn from, so addresses line up
        let geometry = PerfMetrics.shared.measure(PerfMetrics.Name.engraveModel) {
            try? ScoreModelBuilder.build(svgPages: rawPages, mei: mei)
        }
        return Engraving(pdf: data,
                         failedPages: failures.compactMap(\.pageNumber),
                         geometry: geometry,
                         markAdjustments: Self.byAddress(byKind, in: geometry))
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
