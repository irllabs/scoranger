import PDFKit
import SwiftUI
import UIKit

// The pieces the book reader and Extract share (design/BOOK_EXTRACT_0.19.md
// §B and §C): the pages, the filmstrip under them, and the bar's controls.

/// The book's pages in one of the score's three views, drawn by PDFKit.
///
/// PDFView rather than a scroll of rastered pictures: it draws a page in
/// tiles at whatever zoom it is shown at, so a page the full height of an iPad
/// is sharp when pinched without one huge bitmap per page, and a strip of a
/// 480-page book holds only what is near the screen. One page pages with a
/// swipe and pinches; two pages likewise, a spread at a time; continuous is
/// one row of pages at the full height, scrolling freely.
struct BookPagesView: UIViewRepresentable {
    let document: PDFDocument
    let layout: ScoreLayout
    /// The page on screen, 1-based.
    @Binding var page: Int
    var marks: BookPageMarks = .none
    /// A tap on a page, 1-based. Extract makes it the current page.
    var onTapPage: ((Int) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.backgroundColor = UIColor(Theme.Surface.band)
        view.pageShadowsEnabled = false
        view.pageBreakMargins = UIEdgeInsets(top: 12, left: 6, bottom: 12, right: 6)
        view.pageOverlayViewProvider = context.coordinator
        switch layout {
        case .page:
            view.displayMode = .singlePage
            view.displayDirection = .horizontal
            view.usePageViewController(true, withViewOptions: [
                UIPageViewController.OptionsKey.interPageSpacing: 16])
        case .spread:
            view.displayMode = .twoUp
            view.displaysAsBook = false
            view.displayDirection = .horizontal
            // A spread turns by a swipe as a page does; PDFView's page
            // controller is single-page only, so the swipe is ours.
            for direction in [UISwipeGestureRecognizer.Direction.left, .right] {
                let swipe = UISwipeGestureRecognizer(target: context.coordinator,
                                                     action: #selector(Coordinator.swiped(_:)))
                swipe.direction = direction
                view.addGestureRecognizer(swipe)
            }
        case .continuous:
            view.displayMode = .singlePageContinuous
            view.displayDirection = .horizontal
        }
        view.document = document
        view.autoScales = true
        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.tapped(_:)))
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)
        NotificationCenter.default.addObserver(
            context.coordinator, selector: #selector(Coordinator.pageChanged(_:)),
            name: .PDFViewPageChanged, object: view)
        context.coordinator.view = view
        DispatchQueue.main.async { context.coordinator.go(to: page) }
        view.accessibilityIdentifier = "book-view"
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        let coordinator = context.coordinator
        let marksChanged = coordinator.parent.marks != marks
        coordinator.parent = self
        if coordinator.shownPage != page { coordinator.go(to: page) }
        if marksChanged { coordinator.restyle() }
    }

    static func dismantleUIView(_ view: PDFView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
    }

    final class Coordinator: NSObject, PDFPageOverlayViewProvider {
        var parent: BookPagesView
        weak var view: PDFView?
        private var overlays: [Int: UIView] = [:]

        init(_ parent: BookPagesView) { self.parent = parent }

        /// The page PDFView shows, 1-based.
        var shownPage: Int? {
            guard let view, let page = view.currentPage, let document = view.document else { return nil }
            return document.index(for: page) + 1
        }

        func go(to page: Int) {
            guard let view, let document = view.document,
                  let target = document.page(at: max(0, min(page - 1, document.pageCount - 1)))
            else { return }
            view.go(to: target)
        }

        @objc func pageChanged(_ note: Notification) {
            guard let shown = shownPage, shown != parent.page else { return }
            // Out of the update pass: PDFView posts this while SwiftUI is
            // laying the view out.
            DispatchQueue.main.async { [weak self] in self?.parent.page = shown }
        }

        @objc func tapped(_ gesture: UITapGestureRecognizer) {
            guard let view, let document = view.document, let onTap = parent.onTapPage else { return }
            let point = gesture.location(in: view)
            guard let page = view.page(for: point, nearest: true) else { return }
            onTap(document.index(for: page) + 1)
        }

        @objc func swiped(_ gesture: UISwipeGestureRecognizer) {
            guard let view else { return }
            if gesture.direction == .left, view.canGoToNextPage { view.goToNextPage(nil) }
            if gesture.direction == .right, view.canGoToPreviousPage { view.goToPreviousPage(nil) }
        }

        // MARK: the marks, as a view laid over each page

        func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> UIView? {
            guard let document = view.document else { return nil }
            let index = document.index(for: page) + 1
            let overlay = UIView()
            overlay.isUserInteractionEnabled = false
            overlay.layer.cornerRadius = 4
            overlays[index] = overlay
            style(overlay, page: index)
            return overlay
        }

        func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: UIView,
                     for page: PDFPage) {
            guard let document = pdfView.document else { return }
            overlays[document.index(for: page) + 1] = nil
        }

        func restyle() {
            for (page, overlay) in overlays { style(overlay, page: page) }
        }

        private func style(_ overlay: UIView, page: Int) {
            let marks = parent.marks
            let inSpan = marks.span?.contains(page) ?? false
            let isCurrent = marks.current == page
            // Faint: the tint lies OVER the music, and at 45% the first build
            // greyed the notes out of a page the reader was trying to read.
            overlay.backgroundColor = inSpan ? UIColor(Theme.Accent.clayTint).withAlphaComponent(0.18) : .clear
            overlay.layer.borderWidth = isCurrent ? 3 : (inSpan ? 2 : 0)
            overlay.layer.borderColor = UIColor(isCurrent ? Theme.Accent.clay : Theme.Accent.clayBorder).cgColor
            overlay.accessibilityLabel = marks.label(page: page,
                                                     of: parent.document.pageCount)
        }
    }
}

/// The strip under the pages: every page in the book, lazily, with the scrub
/// bar and where you are in mono. The reader's one page-position control
/// (§B "The filmstrip").
struct BookFilmstrip: View {
    let document: PDFDocument
    /// 1-based.
    let showing: Int
    var spread = false
    /// Pages tinted as chosen (Extract's span).
    var chosen: (Int) -> Bool = { _ in false }
    /// The phone keeps only the scrub row.
    var compact = false
    var onJump: (Int) -> Void

    private static let cell = CGSize(width: 20, height: 27)
    private static let raster = CGSize(width: 40, height: 54)
    private static let gap: CGFloat = 3
    @State private var flying: Int?

    private var pages: Int { max(document.pageCount, 1) }

    private var readout: String {
        let at = flying ?? showing
        if spread {
            let unit = PagedCanvas.unit(at: at - 1, pageCount: document.pageCount, spread: true)
            if unit.count == 2 { return "\(unit[0] + 1)–\(unit[1] + 1) / \(document.pageCount)" }
        }
        return "\(at) / \(document.pageCount)"
    }

    var body: some View {
        VStack(spacing: Theme.Metric.s6) {
            if !compact {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: Self.gap) {
                            ForEach(0..<document.pageCount, id: \.self) { index in
                                thumb(index)
                            }
                        }
                        .padding(.vertical, Theme.Metric.s4)
                        .padding(.horizontal, Theme.Metric.s8)
                    }
                    // A horizontal scroll view takes every point of height it
                    // is offered, and the first build gave the strip 385pt of
                    // an iPad that belongs to the pages.
                    .frame(height: Self.cell.height + 2 * Theme.Metric.s4)
                    .onChange(of: showing) { _, page in
                        withAnimation { proxy.scrollTo(page - 1, anchor: .center) }
                    }
                    .onAppear { proxy.scrollTo(showing - 1, anchor: .center) }
                }
            }
            HStack(spacing: Theme.Metric.s12) {
                scrubBar
                Text(readout).typeRole(.data).foregroundStyle(Theme.Ink.ink2)
                    .monospacedDigit()
                    .fixedSize()
                    .accessibilityIdentifier("book-page-label")
            }
            .padding(.horizontal, Theme.Metric.s16)
        }
        .padding(.vertical, Theme.Metric.s8)
        .background(Theme.Surface.panel)
        .overlay(alignment: .top) { Theme.Rule() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("book-thumbnails")
    }

    private var scrubBar: some View {
        GeometryReader { geo in
            let current = (flying ?? showing) - 1
            let usable = max(geo.size.width - 16, 1)
            let x = pages > 1 ? usable * CGFloat(current) / CGFloat(pages - 1) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.Surface.well).frame(height: 4)
                Circle().fill(Theme.Accent.clay).frame(width: 16, height: 16)
                    .offset(x: x)
            }
            .frame(height: 24)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let fraction = min(max((value.location.x - 8) / usable, 0), 1)
                        flying = Int((fraction * CGFloat(pages - 1)).rounded()) + 1
                    }
                    .onEnded { _ in
                        if let flying { onJump(flying) }
                        flying = nil
                    })
        }
        .frame(height: 24)
        .accessibilityElement()
        .accessibilityIdentifier("book-scrub")
        .accessibilityLabel("Page")
        .accessibilityValue("\(showing) of \(document.pageCount)")
        .accessibilityAdjustableAction { direction in
            let stride = spread ? 2 : 1
            switch direction {
            case .increment: onJump(min(showing + stride, document.pageCount))
            case .decrement: onJump(max(showing - stride, 1))
            @unknown default: break
            }
        }
    }

    private func thumb(_ index: Int) -> some View {
        let page = index + 1
        let at = flying ?? showing
        let isShowing = spread
            ? PagedCanvas.unit(at: at - 1, pageCount: document.pageCount, spread: true).contains(index)
            : page == at
        let inRange = chosen(page)
        return Button { onJump(page) } label: {
            PageImage(document: document, index: index, drawn: Self.cell,
                      raster: Self.raster, interpolation: .medium) { _ in
                PageThumb(width: Self.cell.width, height: Self.cell.height)
            }
            .frame(width: Self.cell.width, height: Self.cell.height)
            .background(inRange ? Theme.Accent.clayTint : Theme.Surface.paper)
            .clipShape(RoundedRectangle(cornerRadius: 2))
            .overlay {
                RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(isShowing ? Theme.Accent.clay
                                  : (inRange ? Theme.Accent.clayBorder : Color.clear),
                                  lineWidth: isShowing ? 1.5 : 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(index)
        .accessibilityIdentifier("book-thumb-\(page)")
        .accessibilityLabel("Page \(page)")
        .accessibilityAddTraits(inRange ? [.isButton, .isSelected] : [.isButton])
    }
}

/// The score's three view cells, for a book: the same glyphs, the same group,
/// their own identifiers and their own stored choice.
struct BookLayoutControl: View {
    @Binding var layout: ScoreLayout
    let isCompact: Bool
    /// `book-layout` in the reader, `extract-layout` in Extract.
    let prefix: String

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(ScoreLayout.available(isCompact: isCompact).enumerated()),
                    id: \.element) { index, option in
                if index > 0 { Theme.Rule(vertical: true).frame(height: 34) }
                Button { layout = option } label: {
                    Image(systemName: option.glyph)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(layout == option ? Theme.Accent.clayStrong : Theme.Ink.ink2)
                        .frame(width: 40, height: 34)
                        .background(layout == option ? Theme.Accent.clayTint : Theme.Surface.panel)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.label)
                .accessibilityAddTraits(layout == option ? [.isButton, .isSelected] : [.isButton])
                .accessibilityIdentifier("\(prefix)-\(option.rawValue)")
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Metric.rCtl))
        .dashedBoundary()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(prefix)
    }
}

/// A capsule in a book's bar: the score bar's `barButton`.
struct BookBarButton: View {
    let glyph: String
    var word: String?
    let label: String
    let identifier: String
    var active = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Metric.s6) {
                Image(systemName: glyph).font(.system(size: 15, weight: .regular))
                if let word { Text(word).typeRole(.control).lineLimit(1) }
            }
            .foregroundStyle(active ? Theme.Accent.clayStrong : Theme.Ink.ink2)
            .frame(minWidth: 34, minHeight: 34)
            .padding(.horizontal, word == nil ? 0 : Theme.Metric.s12)
            .background(active ? Theme.Accent.clayTint : Theme.Surface.well)
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Metric.rCtl)
                    .stroke(active ? Theme.Accent.clay : Color.clear, lineWidth: 1.5)
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.Metric.rCtl))
            .frame(minWidth: Theme.Metric.hitTarget, minHeight: Theme.Metric.hitTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(label)
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : [.isButton])
    }
}
