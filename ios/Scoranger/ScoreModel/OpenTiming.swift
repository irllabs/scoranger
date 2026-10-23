import Foundation
import PDFKit
import QuartzCore
import UIKit
import os

/// How long one arrangement takes to open, from the reader asking for it to
/// its first page on the glass -- and, behind its own switch, exactly what
/// that open drew, so a faster open can be checked against a slower one.
///
/// Ali, 2026-10-22: opening "Espresso" takes more than a second, and he wants
/// about 200 ms. Three readings answer it, all in milliseconds since the open
/// was requested (the moment `RootView.open` runs for a row tap):
///
///  - `firstPageMs`: the frame that commits the first page's PIXELS -- the
///    first picture the canvas hands any page view (`PDFPageImage`,
///    `ContinuousTileView`) of this arrangement's engraving, by whichever of
///    their routes it arrives. Not the moment the PDF exists, and not the
///    moment SwiftUI is handed the image:
///    one turn of the run loop after the canvas assigns the picture, the
///    transaction being assembled is the one that draws it, and its completion
///    fires when the render server has it -- the rule `LaunchTiming` and
///    `PerfMetrics.measureUntilPresented` already use.
///  - `geometryMs`: the first hit-test model published on `AppState` for the
///    arrangement, which is when a lasso can select something.
///    `geometryPages` says how many pages that model covers.
///  - `allPagesMs`: the first document published on `AppState` holding as
///    many pages as the one on screen when the open's render pass finished
///    (`AppState.renderIfNeeded` publishing, or failing). Every document the
///    open published is in `documents`, so a render that shows page 1 first
///    and the rest later is read correctly -- provided the rest arrive before
///    `renderIfNeeded` returns. One that hands them over after it returns
///    reads early here with fewer `pages`, which is why the judge compares
///    `pages` with the baseline's.
///
/// Not `loadingPDF`: two overlapping calls of `renderIfNeeded` (the row tap's
/// and the library poll's) share that one Bool, and the first to return
/// lowers it while the engrave is still running -- measured, it fell before
/// any document existed.
///
/// Inert unless the app was launched with `-openTiming <slug>`, which only
/// `ios/scripts/measure_open.sh` passes. Every hook reads one `static let`
/// Bool first, so a reader's app pays a load and a branch per hook and
/// nothing else. `-openFidelity` adds the dump `compare_open_fidelity.py`
/// reads: the SVG of every page as handed to the rasteriser, the geometry as
/// canonical JSON, and every published page drawn to a PNG.
final class OpenTiming: @unchecked Sendable {

    static let shared = OpenTiming()

    /// The arrangement to open, or nil: the whole switch.
    static let requestedSlug: String? = {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-openTiming"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }()
    static let isRequested = requestedSlug != nil
    static let dumpsFidelity = isRequested
        && ProcessInfo.processInfo.arguments.contains("-openFidelity")

    struct Span: Codable, Equatable {
        var name: String
        /// Milliseconds since the open was requested; negative for work that
        /// began before it and overlapped it.
        var start: Double
        var end: Double
    }

    struct Stage: Codable, Equatable {
        var name: String
        var count: Int
        /// The part of this name's work inside the open's window. Pages
        /// rasterised in parallel overlap, so stages can sum past the wait.
        var totalMs: Double
    }

    /// One document published on `AppState` during the open.
    struct Published: Codable, Equatable {
        var ms: Double
        var pages: Int
    }

    struct Report: Codable, Equatable {
        var slug: String
        var layout: String
        /// The arrangement the launch had selected and engraved by itself
        /// before the open. If it is `slug`, the open was a cache hit and the
        /// reading is not an open.
        var selectedBefore: String?
        /// When the open was requested, in ms since the process started: how
        /// settled the app was when it was asked.
        var requestedAtLaunchMs: Double
        var firstPageMs: Double?
        var geometryMs: Double?
        var allPagesMs: Double?
        /// Pages in the document on screen when the render pass finished.
        var pages: Int?
        var geometryPages: Int?
        var elements: Int?
        var documents: [Published]
        var error: String?
        /// All three readings are in, or the render failed. The script waits
        /// for this.
        var complete: Bool
        var stages: [Stage]
        var spans: [Span]

        static var fileURL: URL {
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appending(path: "open-timing.json")
        }
    }

    private let lock = NSLock()
    private var slug: String?
    private var layout = ""
    private var selectedBefore: String?
    private var start: TimeInterval = 0
    private var requestedAtLaunchMs: Double = 0
    private var firstPage: Double?
    private var firstPageQueued = false
    private var geometryAt: Double?
    private var geometryPages: Int?
    private var elements: Int?
    private var documents: [Published] = []
    private var finished = false
    private var allPages: Double?
    private var pages: Int?
    private var error: String?
    private var written = false
    /// Each reading as it lands, so a device (or a run that never finishes)
    /// can be read with `log stream --predicate 'category == "open"'`.
    private let logger = Logger(subsystem: "com.irllabs.scoranger", category: "open")

    private init() {}

    private func note(_ what: String) {
        logger.log("SCORANGER-OPEN \(what, privacy: .public)")
    }

    // MARK: - The open

    /// The open is being requested now. Called immediately before the same
    /// call a row tap makes.
    func begin(slug: String, layout: String, selectedBefore: String?) {
        guard Self.isRequested else { return }
        lock.lock()
        self.slug = slug
        self.layout = layout
        self.selectedBefore = selectedBefore
        start = PerfClock.now
        requestedAtLaunchMs = LaunchTiming.shared.now
        lock.unlock()
        if Self.dumpsFidelity { Self.resetFidelityDirectory() }
        note("begin \(slug) layout=\(layout) selectedBefore=\(selectedBefore ?? "none")")
    }

    /// Whether an engraving key (`slug/version/layout#stamp`) belongs to the
    /// open being timed. Under the lock.
    private func belongs(_ key: String) -> Bool {
        guard let slug else { return false }
        return key.hasPrefix(slug + "/")
    }

    /// Under the lock.
    private func since() -> Double { (PerfClock.now - start) * 1000 }

    /// The canvas has handed a page its first picture. Only the first one
    /// counts; the reading is the frame that carries it.
    @MainActor
    func pagePictureSet(document: String) {
        guard Self.isRequested else { return }
        lock.lock()
        guard belongs(document), !firstPageQueued else { lock.unlock(); return }
        firstPageQueued = true
        lock.unlock()
        DispatchQueue.main.async {
            CATransaction.begin()
            CATransaction.setCompletionBlock {
                let s = OpenTiming.shared
                s.lock.lock()
                let ms = s.since()
                s.firstPage = ms
                s.lock.unlock()
                s.note("first page on glass \(Int(ms)) ms")
                s.publishIfComplete()
            }
            CATransaction.commit()
        }
    }

    /// `AppState.geometry` has been published.
    @MainActor
    func geometryPublished(_ geometry: ScoreGeometry, slug: String?) {
        guard Self.isRequested, let slug else { return }
        lock.lock()
        guard slug == self.slug, geometryAt == nil else { lock.unlock(); return }
        let ms = since()
        geometryAt = ms
        geometryPages = geometry.pages.count
        elements = geometry.elementCount
        lock.unlock()
        note("geometry \(Int(ms)) ms, \(geometry.pages.count) pages")
        if Self.dumpsFidelity {
            Self.write(Data(Self.canonicalJSON(geometry).utf8), to: "geometry.json")
        }
        publishIfComplete()
    }

    /// `AppState.pdfDocument` has been set to this document.
    @MainActor
    func documentPublished(_ document: PDFDocument, slug: String?) {
        guard Self.isRequested, let slug else { return }
        lock.lock()
        guard slug == self.slug, !finished else { lock.unlock(); return }
        let entry = Published(ms: since(), pages: document.pageCount)
        documents.append(entry)
        lock.unlock()
        note("document \(Int(entry.ms)) ms, \(entry.pages) pages")
    }

    /// `AppState.renderIfNeeded` has published the arrangement's engraving,
    /// or failed to, for the open being timed.
    @MainActor
    func renderFinished(slug: String, error: String?, document: PDFDocument?) {
        guard Self.isRequested else { return }
        lock.lock()
        guard slug == self.slug, !finished else { lock.unlock(); return }
        finished = true
        let count = document?.pageCount
        pages = count
        self.error = error
        allPages = count.flatMap { n in documents.first(where: { $0.pages >= n })?.ms }
        let ms = allPages
        lock.unlock()
        note("render finished \(ms.map { "\(Int($0)) ms" } ?? "-"), "
             + "\(count ?? 0) pages, error=\(error ?? "none")")
        if Self.dumpsFidelity, let document {
            Self.dumpPages(of: document)
        }
        publishIfComplete()
    }

    private func publishIfComplete() {
        lock.lock()
        // A render that failed never draws a page; it is complete with its
        // error, so the script does not wait for ever.
        let failed = finished && error != nil
        let complete = failed
            || (firstPage != nil && allPages != nil && geometryAt != nil)
        guard complete, !written, let slug else { lock.unlock(); return }
        written = true
        let end = [firstPage, geometryAt, allPages].compactMap { $0 }.max() ?? since()
        var report = Report(slug: slug, layout: layout,
                            selectedBefore: selectedBefore,
                            requestedAtLaunchMs: requestedAtLaunchMs,
                            firstPageMs: firstPage, geometryMs: geometryAt,
                            allPagesMs: allPages, pages: pages,
                            geometryPages: geometryPages, elements: elements,
                            documents: documents, error: error,
                            complete: true, stages: [], spans: [])
        let start = self.start
        lock.unlock()
        let ledger = PerfMetrics.shared.snapshot()
        let to = start + end / 1000
        report.stages = ledger.accounted(from: start, to: to).map {
            Stage(name: $0.name, count: $0.count, totalMs: $0.total * 1000)
        }
        report.spans = ledger.samples(from: start, to: to).map {
            Span(name: $0.name, start: ($0.start - start) * 1000, end: ($0.end - start) * 1000)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(report) else { return }
        try? data.write(to: Report.fileURL, options: .atomic)
        // after the reading: the script collects the dump once this exists
        if Self.dumpsFidelity { Self.write(Data("done\n".utf8), to: "done") }
        note("written: first page \(report.firstPageMs.map { Int($0) } ?? -1) ms, "
             + "geometry \(report.geometryMs.map { Int($0) } ?? -1) ms, "
             + "all pages \(report.allPagesMs.map { Int($0) } ?? -1) ms")
    }

    // MARK: - Fidelity

    /// Where the dump goes for the script to collect: one open per launch, so
    /// one directory, emptied when the open begins.
    static var fidelityDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "open-fidelity")
    }

    private static func resetFidelityDirectory() {
        try? FileManager.default.removeItem(at: fidelityDirectory)
        try? FileManager.default.createDirectory(at: fidelityDirectory,
                                                 withIntermediateDirectories: true)
    }

    private static func write(_ data: Data, to name: String) {
        let url = fidelityDirectory.appending(path: name)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// Every page's SVG exactly as handed to the rasteriser, for the engrave
    /// that belongs to the open. `musicXMLPath` is how the renderer names
    /// what it engraved; the workspace keeps an arrangement's versions under
    /// a directory named by its slug.
    func dumpRasteriserInput(pages: [String], musicXMLPath: String) {
        guard Self.dumpsFidelity else { return }
        lock.lock()
        let wanted = slug.map { musicXMLPath.contains("/\($0)/") } ?? false
        lock.unlock()
        guard wanted else { return }
        for (i, svg) in pages.enumerated() {
            Self.write(Data(svg.utf8), to: String(format: "svg/page-%03d.svg", i + 1))
        }
    }

    /// Every page of the published document drawn at one fixed width, so two
    /// opens can be compared by what a reader would SEE, whatever route the
    /// pages took to get there.
    @MainActor
    private static func dumpPages(of document: PDFDocument) {
        let width: CGFloat = 1200
        for i in 0..<document.pageCount {
            guard let page = document.page(at: i) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            let size = CGSize(width: width,
                              height: (width * bounds.height / max(bounds.width, 1)).rounded())
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
                UIColor.white.setFill()
                ctx.fill(CGRect(origin: .zero, size: size))
                let cg = ctx.cgContext
                cg.translateBy(x: 0, y: size.height)
                cg.scaleBy(x: size.width / max(bounds.width, 1),
                           y: -size.height / max(bounds.height, 1))
                page.draw(with: .mediaBox, to: cg)
            }
            if let png = image.pngData() {
                write(png, to: String(format: "png/page-%03d.png", i + 1))
            }
        }
    }

    /// The geometry as text two opens can be compared by: page sizes, the
    /// engraver's system count, the bar frames, and every element's kind,
    /// address and frame, rounded to 0.01 and in the model's own order. The
    /// session id is left out: it names the element only inside one load.
    static func canonicalJSON(_ geometry: ScoreGeometry) -> String {
        func r(_ v: CGFloat) -> String { String(format: "%.2f", Double(v)) }
        func frame(_ f: CGRect) -> String {
            "[\(r(f.minX)),\(r(f.minY)),\(r(f.width)),\(r(f.height))]"
        }
        var lines: [String] = ["{\"pages\":["]
        for (p, page) in geometry.pages.enumerated() {
            lines.append("{\"index\":\(page.index),\"size\":[\(r(page.size.width)),\(r(page.size.height))],"
                         + "\"drawnSystems\":\(page.drawnSystems),\"bars\":[")
            lines.append(page.barFrames.map { "[\($0.number),\(frame($0.frame))]" }
                .joined(separator: ",\n"))
            lines.append("],\"elements\":[")
            lines.append(page.elements.map { e in
                let address = e.address.map { "\"\($0.description)\"" } ?? "null"
                return "[\"\(e.kind.rawValue)\",\(address),\(e.pageIndex),\(frame(e.frame))]"
            }.joined(separator: ",\n"))
            lines.append("]}" + (p == geometry.pages.count - 1 ? "" : ","))
        }
        lines.append("]}")
        return lines.joined(separator: "\n") + "\n"
    }
}
