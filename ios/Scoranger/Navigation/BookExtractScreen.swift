import PDFKit
import SwiftUI

/// Taking tunes out of a book (design/BOOK_EXTRACT_0.19.md §C).
///
/// The book's pages on the left, and on the right one panel in one of two
/// modes: FIND TUNES, where the book's tunes are listed with a tick each and
/// the ticked ones are extracted in one press; and CHOOSE PAGES, where a span
/// is marked on the pages with Start and End. Both end in the same choice of
/// where it goes -- a new piece, or one already in the library.
///
/// It replaces the found-tunes list that sat under the book's page, which Ali
/// called "very goofy; too many buttons": Join previous, a greyed Split,
/// Remove, page steppers and an evidence label on every row. Here a reader
/// says what to extract by ticking it, and opens a row to correct its title
/// or its pages with the same Start and End the range uses.
struct BookExtractScreen: View {
    @EnvironmentObject var state: AppState
    let slug: String
    var onBack: () -> Void
    var onOpen: (String) -> Void
    /// Back to the reader with its Tunes panel open.
    var onShowTunes: () -> Void

    enum Mode: String { case auto, range }

    @AppStorage("bookLayout") private var layoutRaw = ScoreLayout.page.rawValue
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var mode: Mode = .auto
    @State private var document: PDFDocument?
    @State private var loading = true
    /// The page tapped last, which Start and End act on; nil is the page shown.
    @State private var tapped: Int?

    // Find tunes
    @State private var contents: BookContents?
    @State private var fromSaved = false
    @State private var ticked: Set<String> = []
    @State private var openRow: String?
    @State private var busy = false
    @State private var report: BookSplitReport?
    @State private var single: (score: String, title: String, piece: String)?
    @State private var saved: Int?

    // Choose pages
    @State private var fromPage = ""
    @State private var toPage = ""
    @State private var name = ""
    @State private var lastFill: String?
    @State private var made: (score: String, line: String)?

    // Where it goes (one ticked tune, or a range)
    @State private var toExisting = false
    @State private var chosenPiece: String?
    @State private var search = ""

    private var isCompact: Bool { sizeClass == .compact }
    private var book: BookDoc? { (state.manifest?.books ?? []).first { $0.slug == slug } }
    private var pieces: [PieceDoc] { state.manifest?.pieces ?? [] }
    private var pageCount: Int { document?.pageCount ?? book?.pages ?? 0 }

    private var layout: Binding<ScoreLayout> {
        Binding(get: {
                    let chosen = ScoreLayout(rawValue: layoutRaw) ?? .page
                    return ScoreLayout.available(isCompact: isCompact).contains(chosen) ? chosen : .page
                },
                set: { layoutRaw = $0.rawValue })
    }

    private var page: Binding<Int> {
        Binding(get: { state.bookPage[slug] ?? 1 },
                set: { state.bookPage[slug] = $0; tapped = nil })
    }

    private var current: Int { tapped ?? page.wrappedValue }

    private var range: (from: Int, to: Int)? {
        BookPages.range(from: fromPage, to: toPage, pages: pageCount > 0 ? pageCount : nil)
    }

    private var tickedEntries: [BookEntry] {
        (contents?.entries ?? []).filter { ticked.contains($0.id) }
    }

    /// What is tinted on the pages: the open row's span, or the range.
    private var marks: BookPageMarks {
        var marks = BookPageMarks(current: current)
        switch mode {
        case .auto:
            if let id = openRow, let entry = contents?.entries.first(where: { $0.id == id }) {
                marks.span = entry.from...entry.to
            }
        case .range:
            if let range { marks.span = range.from...range.to }
            else if let start = BookPages.number(fromPage) { marks.span = start...start }
        }
        return marks
    }

    var body: some View {
        Screen(title: "Extract", backLabel: book?.name ?? "Book", onBack: onBack,
               trailing: {
                   BookLayoutControl(layout: layout, isCompact: isCompact, prefix: "extract-layout")
                       .opacity(document == nil ? 0.45 : 1)
                       .disabled(document == nil)
               }, content: {
            if isCompact {
                VStack(spacing: 0) {
                    pages.frame(maxHeight: .infinity)
                    Theme.Rule()
                    panel.frame(maxHeight: .infinity)
                }
            } else {
                HStack(spacing: 0) {
                    pages
                    Theme.Rule(vertical: true)
                    panel.frame(width: Theme.Metric.panelWidth)
                }
            }
        }, scrolls: false)
        .task(id: slug) { await open() }
        .onChange(of: state.bookProposals[slug]) { _, proposal in
            if let proposal, report == nil, saved == nil { load(proposal.entries, saved: false) }
        }
    }

    // MARK: the pages

    @ViewBuilder
    private var pages: some View {
        VStack(spacing: 0) {
            if let document, document.pageCount > 0 {
                BookPagesView(document: document, layout: layout.wrappedValue, page: page,
                              marks: marks, onTapPage: { tapped = $0 })
                    .id(layout.wrappedValue)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("book-view")
                    .accessibilityLabel(marks.label(page: current, of: document.pageCount))
                BookFilmstrip(document: document, showing: page.wrappedValue,
                              spread: layout.wrappedValue == .spread,
                              chosen: { marks.span?.contains($0) ?? false },
                              compact: isCompact,
                              onJump: { page.wrappedValue = $0 })
            } else if loading {
                ProgressView().tint(Theme.Accent.clay)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.Surface.band)
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

    // MARK: the panel

    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            modeSegment
                .padding(.horizontal, Theme.Metric.panelSide)
                .padding(.vertical, Theme.Metric.s12)
            Theme.Rule()
            switch mode {
            case .auto:  findTunes
            case .range: choosePages
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.Surface.panel)
    }

    private var modeSegment: some View {
        Segment(options: [("Find tunes", Mode.auto, "extract-mode-auto"),
                          ("Choose pages", Mode.range, "extract-mode-range")],
                selection: $mode)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("extract-mode")
    }

    // MARK: find tunes

    @ViewBuilder
    private var findTunes: some View {
        if let stage = state.findingTunes[slug] {
            VStack(alignment: .leading, spacing: Theme.Metric.s8) {
                HStack(spacing: Theme.Metric.s8) {
                    ProgressView().controlSize(.small).tint(Theme.Accent.clay)
                    Text("Finding the tunes").typeRole(.row).foregroundStyle(Theme.Ink.ink)
                }
                Text(stage).typeRole(.data).foregroundStyle(Theme.Ink.ink2)
                Text("You can choose pages while this runs.").typeRole(.body)
                    .foregroundStyle(Theme.Ink.ink2)
            }
            .padding(Theme.Metric.panelSide)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("extract-finding")
            Spacer()
        } else if let report {
            resultList(report)
        } else if let single {
            singleResult(single)
        } else if let saved {
            VStack(alignment: .leading, spacing: Theme.Metric.s12) {
                Text("Saved \(saved) tune\(saved == 1 ? "" : "s") as the tune list.")
                    .typeRole(.body).foregroundStyle(Theme.Ink.ink)
                PanelButton(title: "Show the tune list", kind: .primary,
                            identifier: "extract-show-tunes", action: onShowTunes)
            }
            .padding(Theme.Metric.panelSide)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("extract-saved")
            Spacer()
        } else if let failure = state.findTunesFailure[slug] {
            notice(title: "Couldn't find the tunes", body: failure, id: "extract-failed",
                   primary: ("Try again", { find() }))
        } else if let contents, contents.entries.isEmpty {
            notice(title: "No tunes found", body: "Mark a tune's pages with Start and End instead.",
                   id: "extract-none", primary: ("Choose pages", { mode = .range }))
        } else if let contents {
            tuneList(contents)
        } else {
            Spacer()
        }
    }

    private func notice(title: String, body: String, id: String,
                        primary: (String, () -> Void)) -> some View {
        VStack(alignment: .leading, spacing: Theme.Metric.s12) {
            Text(title).typeRole(.titleS).foregroundStyle(Theme.Ink.ink)
            Text(body).typeRole(.body).foregroundStyle(Theme.Ink.ink2)
            HStack(spacing: Theme.Metric.s8) {
                PanelButton(title: primary.0, kind: .primary, action: primary.1)
                if id == "extract-failed" {
                    PanelButton(title: "Choose pages") { mode = .range }
                }
            }
        }
        .padding(Theme.Metric.panelSide)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(id)
    }

    private func tuneList(_ contents: BookContents) -> some View {
        let all = ticked.count == contents.entries.count
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.Metric.s4) {
                HStack {
                    Text("\(contents.entries.count) tune\(contents.entries.count == 1 ? "" : "s")")
                        .typeRole(.titleS).foregroundStyle(Theme.Ink.ink)
                    Spacer()
                    quiet(all ? "Select none" : "Select all", id: "extract-select-all") {
                        ticked = all ? [] : Set(contents.entries.map(\.id))
                    }
                }
                HStack {
                    Text(ExtractModel.source(of: contents.entries, saved: fromSaved))
                        .typeRole(.meta).foregroundStyle(Theme.Ink.ink3)
                        .accessibilityIdentifier("extract-found")
                    Spacer()
                    quiet("Find again", id: "extract-again") { find() }
                }
            }
            .padding(.horizontal, Theme.Metric.panelSide)
            .padding(.vertical, Theme.Metric.s12)
            Theme.Rule()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(contents.entries.enumerated()), id: \.element.id) { index, entry in
                            tuneRow(entry, at: index)
                            Theme.Rule()
                        }
                    }
                }
                .onChange(of: openRow) { _, id in
                    if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("extract-list")
            autoFooter
        }
    }

    private func tuneRow(_ entry: BookEntry, at index: Int) -> some View {
        let isTicked = ticked.contains(entry.id)
        let isOpen = openRow == entry.id
        let joins = ExtractModel.existingPiece(named: entry.title, in: pieces) != nil
        return HStack(alignment: .top, spacing: 0) {
            Button {
                if isTicked { ticked.remove(entry.id) } else { ticked.insert(entry.id) }
            } label: {
                Image(systemName: isTicked ? "checkmark.square.fill" : "square")
                    .font(.system(size: 17))
                    .foregroundStyle(isTicked ? Theme.Accent.clayStrong : Theme.Ink.ink3)
                    .frame(width: Theme.Metric.checkboxGutter, height: Theme.Metric.hitTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Extract \(entry.title)")
            .accessibilityAddTraits(isTicked ? [.isButton, .isSelected] : [.isButton])
            .accessibilityIdentifier("extract-check-\(index + 1)")
            VStack(alignment: .leading, spacing: Theme.Metric.s6) {
                if isOpen {
                    PanelField(placeholder: "Title", text: Binding(
                        get: { entry.title },
                        set: { contents?.rename(entry.id, to: $0) }))
                        .accessibilityIdentifier("extract-title-\(index + 1)")
                    HStack(spacing: Theme.Metric.s8) {
                        capsule("Start \(entry.from)", id: "extract-row-start-\(index + 1)") {
                            contents?.setRange(entry.id, from: current, to: max(entry.to, current))
                        }
                        capsule("End \(entry.to)", id: "extract-row-end-\(index + 1)") {
                            contents?.setRange(entry.id, from: min(entry.from, current), to: current)
                        }
                    }
                } else {
                    Text(entry.title).typeRole(.titleS)
                        .foregroundStyle(isTicked ? Theme.Ink.ink : Theme.Ink.ink2).lineLimit(1)
                    HStack(spacing: 0) {
                        Text(BookReading.pages(entry)).typeRole(.data).foregroundStyle(Theme.Ink.ink3)
                        if joins {
                            Text(" · Joins your piece").typeRole(.meta).foregroundStyle(Theme.Ink.ink2)
                        }
                    }
                }
            }
            .padding(.vertical, Theme.Metric.s8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                openRow = isOpen ? nil : entry.id
                if !isOpen { page.wrappedValue = entry.from }
            }
            .padding(.trailing, Theme.Metric.panelSide)
        }
        .frame(minHeight: 56)
        .background(isOpen ? Theme.Accent.clayTint : Color.clear)
        .id(entry.id)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("extract-row-\(index + 1)")
    }

    private var autoFooter: some View {
        let count = tickedEntries.count
        let problem = count == 0 ? nil
            : BookContents(entries: tickedEntries, pages: max(pageCount, 1)).problem
        return VStack(alignment: .leading, spacing: Theme.Metric.s12) {
            if count >= 2 {
                Text("Each tune becomes a new piece, or joins your piece of the same name.")
                    .typeRole(.meta).foregroundStyle(Theme.Ink.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("extract-dest-many")
            } else if count == 1, let only = tickedEntries.first {
                destination(name: only.title)
            }
            if let problem {
                Text(problem).typeRole(.meta).foregroundStyle(Theme.Status.warn)
                    .accessibilityIdentifier("extract-problem")
            }
            HStack(spacing: Theme.Metric.s12) {
                if busy { ProgressView().controlSize(.small).tint(Theme.Accent.clay) }
                PanelButton(title: ExtractModel.extractTunesTitle(count, busy: busy), kind: .primary,
                            identifier: "extract-auto") { extractTicked() }
                    .disabled(count == 0 || problem != nil || busy || !destinationReady)
                quiet("Save as tune list", id: "extract-keep") { saveList() }
                    .disabled(count == 0 || problem != nil || busy)
                    .accessibilityHint("The book stays one book. Its tunes are listed under Tunes.")
            }
        }
        .padding(.horizontal, Theme.Metric.panelSide)
        .padding(.vertical, Theme.Metric.s12)
        .overlay(alignment: .top) { Theme.Rule() }
    }

    private func resultList(_ report: BookSplitReport) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.Metric.s4) {
                Text("Extracted \(report.arrangements.count) tune\(report.arrangements.count == 1 ? "" : "s")")
                    .typeRole(.titleS).foregroundStyle(Theme.Ink.ink)
                Text(Self.summary(report)).typeRole(.body).foregroundStyle(Theme.Ink.ink2)
            }
            .padding(Theme.Metric.panelSide)
            Theme.Rule()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(report.arrangements.enumerated()), id: \.offset) { index, made in
                        resultRow(title: made.title, piece: made.piece, score: made.score, index: index)
                        Theme.Rule()
                    }
                }
            }
            HStack {
                quiet("Find again", id: "extract-again") { find() }
                Spacer()
            }
            .padding(.horizontal, Theme.Metric.panelSide)
            .padding(.vertical, Theme.Metric.s12)
            .overlay(alignment: .top) { Theme.Rule() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("extract-result")
    }

    private func singleResult(_ made: (score: String, title: String, piece: String)) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Extracted 1 tune").typeRole(.titleS).foregroundStyle(Theme.Ink.ink)
                .padding(Theme.Metric.panelSide)
            Theme.Rule()
            resultRow(title: made.title, piece: made.piece, score: made.score, index: 0)
            Theme.Rule()
            HStack {
                quiet("Find again", id: "extract-again") { find() }
                Spacer()
            }
            .padding(Theme.Metric.panelSide)
            Spacer()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("extract-result")
    }

    private func resultRow(title: String, piece: String, score: String, index: Int) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).typeRole(.titleS).foregroundStyle(Theme.Ink.ink).lineLimit(1)
                Text("in \(pieceName(piece))").typeRole(.meta).foregroundStyle(Theme.Ink.ink3)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 14)).foregroundStyle(Theme.Ink.ink3)
        }
        .padding(.horizontal, Theme.Metric.panelSide)
        .padding(.vertical, Theme.Metric.s8)
        .frame(minHeight: 56)
        .rowTappable(label: title, identifier: "extract-result-row-\(index + 1)") { onOpen(score) }
    }

    // MARK: choose pages

    private var choosePages: some View {
        let start = BookPages.number(fromPage)
        let end = BookPages.number(toPage)
        return VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let made {
                        HStack(spacing: Theme.Metric.s8) {
                            Text(made.line).typeRole(.body).foregroundStyle(Theme.Ink.ink)
                            Spacer()
                            PanelButton(title: "Open", identifier: "extract-open") { onOpen(made.score) }
                        }
                        .padding(Theme.Metric.panelSide)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("extract-made")
                        Theme.Rule()
                    }
                    PanelLabel(text: "Pages")
                    VStack(alignment: .leading, spacing: Theme.Metric.s8) {
                        if document == nil && !loading {
                            HStack(spacing: Theme.Metric.s12) {
                                PanelField(placeholder: "From", text: $fromPage, isMono: true)
                                    .accessibilityIdentifier("extract-range-from")
                                PanelField(placeholder: "To", text: $toPage, isMono: true)
                                    .accessibilityIdentifier("extract-range-to")
                            }
                            Text("This book's pages can't be shown, so type the page numbers.")
                                .typeRole(.body).foregroundStyle(Theme.Ink.ink2)
                        } else {
                            HStack(spacing: Theme.Metric.s8) {
                                capsule(start.map { "Start \($0)" } ?? "Start", id: "extract-range-start",
                                        label: start.map { "Start at page \($0)" } ?? "Start, not set") {
                                    markStart()
                                }
                                capsule(end.map { "End \($0)" } ?? "End", id: "extract-range-end",
                                        label: end.map { "End at page \($0)" } ?? "End, not set") {
                                    (fromPage, toPage) = BookPages.ending(at: current, from: fromPage, to: toPage)
                                }
                                Spacer()
                                if start != nil || end != nil {
                                    Button { fromPage = ""; toPage = "" } label: {
                                        Image(systemName: "xmark").font(.system(size: 13))
                                            .foregroundStyle(Theme.Ink.ink3)
                                            .frame(width: Theme.Metric.hitTarget,
                                                   height: Theme.Metric.hitTarget)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Clear the pages")
                                    .accessibilityIdentifier("extract-range-clear")
                                }
                            }
                            Text(ExtractModel.rangeLine(from: start, to: range == nil ? nil : end))
                                .typeRole(range == nil ? .body : .data)
                                .foregroundStyle(range == nil ? Theme.Ink.ink2 : Theme.Ink.ink)
                                .accessibilityIdentifier("extract-range-summary")
                        }
                    }
                    .padding(.horizontal, Theme.Metric.panelSide)
                    .padding(.bottom, Theme.Metric.s12)
                    PanelLabel(text: "Name")
                    PanelField(placeholder: "Name", text: $name)
                        .accessibilityIdentifier("extract-name")
                        .padding(.horizontal, Theme.Metric.panelSide)
                        .padding(.bottom, Theme.Metric.s12)
                    PanelLabel(text: "Goes to")
                    destination(name: name)
                        .padding(.horizontal, Theme.Metric.panelSide)
                        .padding(.bottom, Theme.Metric.s12)
                }
            }
            HStack {
                PanelButton(title: busy ? "Extracting…"
                                         : (range.map { ExtractModel.extractPagesTitle(from: $0.from, to: $0.to) }
                                            ?? "Extract pages"),
                            kind: .primary, identifier: "extract-range") { extractRange() }
                    .disabled(range == nil || name.trimmingCharacters(in: .whitespaces).isEmpty
                              || busy || !destinationReady)
                Spacer()
            }
            .padding(.horizontal, Theme.Metric.panelSide)
            .padding(.vertical, Theme.Metric.s12)
            .overlay(alignment: .top) { Theme.Rule() }
        }
    }

    private func markStart() {
        (fromPage, toPage) = BookPages.starting(at: current, from: fromPage, to: toPage)
        made = nil
        if let fill = ExtractModel.prefill(at: current, entries: contents?.entries ?? book?.contents ?? [],
                                           current: name, lastFill: lastFill) {
            name = fill
            lastFill = fill
        }
    }

    // MARK: where it goes

    private var destinationReady: Bool { !toExisting || chosenPiece != nil }

    private func destination(name: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Metric.s8) {
            Segment(options: [("New piece", false, "extract-dest-new"),
                              ("Existing piece", true, "extract-dest-existing")],
                    selection: Binding(get: { toExisting }, set: { existing in
                        toExisting = existing
                        if existing, chosenPiece == nil {
                            chosenPiece = ExtractModel.existingPiece(named: name, in: pieces)?.slug
                        }
                    }),
                    unavailable: pieces.isEmpty ? [true] : [])
            if toExisting {
                PanelField(placeholder: "Search pieces", text: $search)
                    .accessibilityIdentifier("extract-piece-search")
                let matches = pieces.filter {
                    search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)
                }
                if matches.isEmpty {
                    Text("No piece matches.").typeRole(.meta).foregroundStyle(Theme.Ink.ink3)
                }
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(matches) { piece in
                            Button { chosenPiece = piece.slug } label: {
                                HStack {
                                    Text(piece.name).typeRole(.row).foregroundStyle(Theme.Ink.ink)
                                        .lineLimit(1)
                                    Spacer()
                                    Text("\(piece.arrangements.count) arr.").typeRole(.data)
                                        .foregroundStyle(Theme.Ink.ink3)
                                    if chosenPiece == piece.slug {
                                        Image(systemName: "checkmark").font(.system(size: 14))
                                            .foregroundStyle(Theme.Accent.clayStrong)
                                    }
                                }
                                .padding(.horizontal, Theme.Metric.s12)
                                .frame(minHeight: Theme.Metric.hitTarget)
                                .background(chosenPiece == piece.slug ? Theme.Accent.clayTint
                                                                      : Theme.Surface.band)
                                .clipShape(RoundedRectangle(cornerRadius: Theme.Metric.rCtl))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(chosenPiece == piece.slug ? [.isSelected] : [])
                            .accessibilityIdentifier("extract-piece-\(piece.slug)")
                        }
                    }
                }
                .frame(maxHeight: 6 * 46)
            } else {
                Text(ExtractModel.newPieceLine(name: name, pieces: pieces))
                    .typeRole(.body).foregroundStyle(Theme.Ink.ink2)
                    .accessibilityIdentifier("extract-dest-line")
            }
        }
    }

    /// The `piece` the engine is given: the chosen piece's slug, or the tune's
    /// own name, which `resolve_piece` joins to a piece of that name or makes.
    private func pieceArgument(for name: String) -> String {
        if toExisting, let chosenPiece { return chosenPiece }
        return name.trimmingCharacters(in: .whitespaces)
    }

    private func pieceName(_ slugOrName: String) -> String {
        pieces.first { $0.slug == slugOrName }?.name ?? slugOrName
    }

    // MARK: actions

    private func open() async {
        loading = true
        document = await state.bookDocument(slug)
        loading = false
        if let document, document.pageCount > 0 {
            page.wrappedValue = BookPages.clamp(page.wrappedValue, pages: document.pageCount)
        }
        guard contents == nil else { return }
        if let proposal = state.bookProposals[slug] {
            load(proposal.entries, saved: false)
        } else if let saved = book?.contents, !saved.isEmpty {
            load(saved, saved: true)
        } else if state.findingTunes[slug] == nil {
            find()
        }
    }

    private func load(_ entries: [BookEntry], saved: Bool) {
        contents = BookContents(entries: entries, pages: max(pageCount, entries.map(\.to).max() ?? 1))
        ticked = Set(entries.map(\.id))
        fromSaved = saved
        openRow = nil
    }

    private func find() {
        report = nil; single = nil; saved = nil
        contents = nil
        Task {
            if let proposal = await state.findTunes(in: slug) {
                load(proposal.entries, saved: false)
            } else if state.findTunesFailure[slug] == nil {
                contents = BookContents(entries: [], pages: max(pageCount, 1))
            }
        }
    }

    private func extractTicked() {
        let entries = tickedEntries
        busy = true
        Task {
            defer { busy = false }
            if entries.count == 1, let only = entries.first {
                let piece = pieceArgument(for: only.title)
                if let made = await state.extractFromBook(slug, from: only.from, to: only.to,
                                                          name: only.title, piece: piece) {
                    single = (made, only.title, piece)
                    state.bookProposals[slug] = nil
                }
            } else if let made = await state.takeOutTunes(of: slug, entries) {
                report = made
            }
        }
    }

    private func saveList() {
        let entries = tickedEntries
        busy = true
        Task {
            defer { busy = false }
            if await state.keepContents(of: slug, entries) { saved = entries.count }
        }
    }

    private func extractRange() {
        guard let range else { return }
        let tune = name.trimmingCharacters(in: .whitespaces)
        let piece = pieceArgument(for: tune)
        busy = true
        Task {
            defer { busy = false }
            if let slugMade = await state.extractFromBook(slug, from: range.from, to: range.to,
                                                          name: tune, piece: piece) {
                made = (slugMade, ExtractModel.madeLine(name: tune, piece: pieceName(piece)))
                fromPage = ""; toPage = ""; name = ""; lastFill = nil
                toExisting = false; chosenPiece = nil; search = ""
            }
        }
    }

    // MARK: small parts

    private func capsule(_ title: String, id: String, label: String? = nil,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).typeRole(.control).monospacedDigit()
                .foregroundStyle(Theme.Ink.ink)
                .padding(.horizontal, Theme.Metric.s12)
                .frame(minHeight: 36)
                .background(Theme.Surface.paper)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Metric.rCtl))
                .frame(minHeight: Theme.Metric.hitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label ?? title)
        .accessibilityIdentifier(id)
    }

    private func quiet(_ title: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).typeRole(.control).foregroundStyle(Theme.Accent.clayStrong)
                .frame(minHeight: Theme.Metric.hitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    /// "Took out 124 tunes: 121 new pieces, 3 added to pieces already here."
    static func summary(_ report: BookSplitReport) -> String {
        var text = "\(report.piecesCreated) new piece\(report.piecesCreated == 1 ? "" : "s")"
        if report.piecesJoined > 0 {
            text += ", \(report.piecesJoined) added to piece\(report.piecesJoined == 1 ? "" : "s") already here"
        }
        return text + "."
    }
}

/// Two or three cells on a well track, one chosen: the panel's segment.
struct Segment<Value: Hashable>: View {
    let options: [(String, Value, String)]
    @Binding var selection: Value
    /// Cells that cannot be chosen: drawn at 45%, never hidden.
    var unavailable: Set<Value> = []
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.2) { title, value, id in
                Button { selection = value } label: {
                    Text(title).typeRole(.control)
                        .foregroundStyle(selection == value ? Theme.Ink.ink : Theme.Ink.ink2)
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background(selection == value ? Theme.Surface.panel : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Metric.rCtl))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(unavailable.contains(value))
                .opacity(unavailable.contains(value) ? 0.45 : 1)
                .accessibilityAddTraits(selection == value ? [.isButton, .isSelected] : [.isButton])
                .accessibilityIdentifier(id)
            }
        }
        .padding(2)
        .background(Theme.Surface.well)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Metric.rCtl))
        .opacity(isEnabled ? 1 : 0.45)
    }
}
