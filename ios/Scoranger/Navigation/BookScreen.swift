import PDFKit
import SwiftUI

/// A book, read (design/BOOK_EXTRACT_0.19.md §B).
///
/// The page as large as the screen allows, in the score's three views -- one
/// page, two pages, a strip of pages at full height -- with the filmstrip as
/// the one control for where you are. Everything about taking tunes out is on
/// the Extract screen, at the bar's far right.
///
/// It used to stack, under one 420pt page: a pager, a filmstrip, From here /
/// To here, the found-tunes review with its steppers and row actions, and a
/// take-out form. Ali: "not usable ... make the score larger so we can
/// actually see it."
///
/// A book kept with a tune list is read a tune at a time from the Tunes
/// panel, which is that list's one way in now that it is not on the page.
struct BookScreen: View {
    @EnvironmentObject var state: AppState
    let slug: String
    var onBack: () -> Void
    var onOpen: (String) -> Void
    /// Read one tune of the book's contents, by entry id (0.14.0).
    var onRead: (String) -> Void = { _ in }
    /// Push the Extract screen (§C).
    var onExtract: () -> Void = {}

    @AppStorage("bookLayout") private var layoutRaw = ScoreLayout.page.rawValue
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var document: PDFDocument?
    @State private var loading = true
    @State private var showingTunes = false

    private var isCompact: Bool { sizeClass == .compact }
    private var book: BookDoc? { (state.manifest?.books ?? []).first { $0.slug == slug } }
    private var contents: [BookEntry] { book?.contents ?? [] }

    private var layout: Binding<ScoreLayout> {
        Binding(get: {
                    let chosen = ScoreLayout(rawValue: layoutRaw) ?? .page
                    return ScoreLayout.available(isCompact: isCompact).contains(chosen) ? chosen : .page
                },
                set: { layoutRaw = $0.rawValue })
    }

    private var page: Binding<Int> {
        Binding(get: { state.bookPage[slug] ?? 1 }, set: { state.bookPage[slug] = $0 })
    }

    /// The tune on the page, said under the title.
    private var tuneLine: String? {
        guard !isCompact,
              let entry = contents.first(where: { ($0.from...$0.to).contains(page.wrappedValue) })
        else { return nil }
        return "\(entry.title) · \(BookReading.pages(entry))"
    }

    var body: some View {
        Screen(title: book?.name ?? "Book", backLabel: isCompact ? "Back" : "Library",
               subtitle: tuneLine,
               onBack: onBack, trailing: { bar }, content: {
            HStack(spacing: 0) {
                if !(isCompact && showingTunes) {
                    reading
                }
                if showingTunes {
                    if !isCompact { Theme.Rule(vertical: true) }
                    tunesPanel
                        .frame(width: isCompact ? nil : Theme.Metric.panelWidth)
                        .frame(maxWidth: isCompact ? .infinity : nil)
                }
            }
        }, scrolls: false)
        .task(id: slug) { await open() }
        .onAppear { openTunesIfAsked() }
        // Coming back from Extract does not always re-run onAppear: the
        // reader never left the stack.
        .onChange(of: state.bookTunesOpen) { _, _ in openTunesIfAsked() }
    }

    // MARK: the bar

    @ViewBuilder
    private var bar: some View {
        HStack(spacing: Theme.Metric.s8) {
            BookBarButton(glyph: "list.bullet", word: isCompact ? nil : "Tunes",
                          label: "Tunes", identifier: "book-tunes", active: showingTunes) {
                showingTunes.toggle()
            }
            BookLayoutControl(layout: layout, isCompact: isCompact, prefix: "book-layout")
                .opacity(document == nil ? 0.45 : 1)
                .disabled(document == nil)
            BookBarButton(glyph: "doc.badge.plus", word: isCompact ? nil : "Extract",
                          label: "Extract", identifier: "book-extract", action: onExtract)
        }
    }

    // MARK: the pages

    @ViewBuilder
    private var reading: some View {
        VStack(spacing: 0) {
            if let document, document.pageCount > 0 {
                BookPagesView(document: document, layout: layout.wrappedValue, page: page)
                    .id(layout.wrappedValue)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("book-view")
                    .accessibilityLabel(BookPages.label(page: page.wrappedValue,
                                                        pages: document.pageCount))
                BookFilmstrip(document: document, showing: page.wrappedValue,
                              spread: layout.wrappedValue == .spread, compact: isCompact,
                              onJump: { page.wrappedValue = $0 })
            } else if loading {
                VStack(spacing: Theme.Metric.s8) {
                    ProgressView().tint(Theme.Accent.clay)
                    Text("Opening the book…").typeRole(.body).foregroundStyle(Theme.Ink.ink2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.Surface.band)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("book-loading")
            } else {
                StateView(systemImage: "book.closed", title: "Can't open this book",
                          message: "Its pages could not be read on this device.",
                          identifier: "book-unopenable")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.Surface.band)
            }
        }
    }

    // MARK: its tunes

    private var tunesPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Metric.s8) {
                Text("Tunes").typeRole(.titleS).foregroundStyle(Theme.Ink.ink)
                if !contents.isEmpty {
                    Text("\(contents.count)").typeRole(.data).foregroundStyle(Theme.Ink.ink3)
                }
                Spacer()
                PanelButton(title: "Done", identifier: "book-tunes-done") { showingTunes = false }
            }
            .padding(.horizontal, Theme.Metric.panelSide)
            .frame(height: Theme.Metric.scoreTopBar)
            .overlay(alignment: .bottom) { Theme.Rule() }
            if contents.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Metric.s12) {
                    Text("This book has no tune list yet.").typeRole(.body)
                        .foregroundStyle(Theme.Ink.ink2)
                    PanelButton(title: "Find tunes", kind: .primary,
                                identifier: "book-tunes-find", action: onExtract)
                }
                .padding(Theme.Metric.panelSide)
                .frame(maxWidth: .infinity, alignment: .leading)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(contents.enumerated()), id: \.element.id) { index, entry in
                                tuneRow(entry, at: index)
                                Theme.Rule()
                            }
                        }
                    }
                    .onAppear {
                        if let here = contents.firstIndex(where: {
                            ($0.from...$0.to).contains(page.wrappedValue) }) {
                            proxy.scrollTo(contents[here].id, anchor: .center)
                        }
                    }
                }
            }
        }
        .background(Theme.Surface.panel)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("book-tunes-panel")
    }

    private func tuneRow(_ entry: BookEntry, at index: Int) -> some View {
        let here = (entry.from...entry.to).contains(page.wrappedValue)
        return HStack(spacing: Theme.Metric.s12) {
            Text("\(index + 1)").typeRole(.data).foregroundStyle(Theme.Ink.ink3)
                .frame(width: 32, alignment: .trailing)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title).typeRole(.titleS).foregroundStyle(Theme.Ink.ink).lineLimit(1)
                Text(BookReading.pages(entry)).typeRole(.meta).foregroundStyle(Theme.Ink.ink3)
            }
            Spacer()
        }
        .padding(.horizontal, Theme.Metric.panelSide)
        .padding(.vertical, Theme.Metric.s8)
        .frame(minHeight: 56)
        .background(here ? Theme.Accent.clayTint : Color.clear)
        .id(entry.id)
        .rowTappable(label: entry.title, identifier: "book-tune-\(index + 1)") {
            onRead(entry.id)
        }
    }

    private func openTunesIfAsked() {
        guard state.bookTunesOpen == slug else { return }
        state.bookTunesOpen = nil
        showingTunes = true
    }

    private func open() async {
        loading = true
        document = await state.bookDocument(slug)
        loading = false
        if let document, document.pageCount > 0 {
            page.wrappedValue = BookPages.clamp(page.wrappedValue, pages: document.pageCount)
        }
    }
}

/// A page as a picture, drawn off the main thread and abandoned when the
/// reader moves on.
///
/// Used by the book browser and by the score's own thumbnail strip
/// (`ScoreFooter`), which had the same fault and is fixed by the same view
/// rather than by a second copy of this reasoning.
///
/// This is the fix for "too slow to scroll a big book". The picture used to be
/// made INSIDE the view body: `ThumbnailCache.shared.image(...)` rasterises a
/// PDF page on whatever thread asks, and the thread asking was the main one.
/// A lazy strip builds a cell for every page a flick passes over, so a flick
/// across a 512-page book stopped the main thread once per page — and there
/// was nothing to call off, because the drawing WAS the view.
///
/// So: ask the cache what it already holds, which is a dictionary lookup and
/// free; and only when it holds nothing, queue the raster and wait. `.task` is
/// cancelled when the cell leaves the strip, which cancels the operation, and
/// one that has not started never rasterises at all.
///
/// The placeholder is told WHY it is being shown. A page not drawn yet and a
/// page that cannot be drawn are two different problems, and with cancellation
/// the first one is the ordinary outcome of a flick — so the warning triangle
/// belongs to `.missing` alone.
struct PageImage<Placeholder: View>: View {
    let document: PDFDocument
    let index: Int
    /// Where it is drawn, in points.
    let drawn: CGSize
    /// What it is rastered at, in pixels.
    let raster: CGSize
    let interpolation: Image.Interpolation
    @ViewBuilder let placeholder: (PageThumbnails.Phase) -> Placeholder

    @State private var image: UIImage?
    @State private var phase: PageThumbnails.Phase = .pending

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().interpolation(interpolation)
            } else {
                placeholder(phase)
            }
        }
        .frame(width: drawn.width, height: drawn.height)
        // The key names the document, the page AND the size, so a cell that
        // changes any of them asks again and one that changes none does not.
        .task(id: ThumbnailCache.key(document: document, index: index, size: raster)) {
            if let held = ThumbnailCache.shared.cached(document: document,
                                                       index: index, size: raster) {
                image = held
                phase = .drawn
                return
            }
            image = nil
            phase = .pending
            let made = await ThumbnailCache.shared.request(document: document,
                                                           index: index, size: raster)
            phase = PageThumbnails.phase(drew: made != nil, abandoned: Task.isCancelled)
            image = phase == .drawn ? made : nil
        }
    }
}

