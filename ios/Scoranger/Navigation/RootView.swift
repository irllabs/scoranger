import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The app's places (NAVIGATION_SYSTEM.md §3, §4C).
///
/// There is ONE place: My Library. Home is gone -- it was a lobby in front of
/// the library, holding a second search field, four large panels and two
/// "recent" sections of the same rows the library already lists -- and the tab
/// bar went with it, because one live tab and a disabled placeholder is not a
/// tab bar. A score opens OVER the library, full screen, and X always closes
/// back to it. It is not a place: it is a document you are in.
///
/// The score's own state -- page, zoom, selection, chat -- survives a close and
/// reopen within a session, because `AppState` outlives this view and the score
/// screen is only hidden, never rebuilt from nothing.
struct RootView: View {
    @EnvironmentObject var state: AppState
    /// Only to stop the ink sync on the way out of a shared entry, and to hand
    /// the shared set list screen its data. Publishes nothing while signed out.
    @EnvironmentObject var shared: SharedSetlists
    /// Whether there is an account, which decides whether the share button
    /// can do its work or has to explain itself (§6A.2).
    @EnvironmentObject var signIn: SignIn

    /// The library's stack. The score view stays OUTSIDE it -- it is presented
    /// over the library, which is what lets its page, zoom and selection
    /// survive going back and returning.
    @State private var libraryPath: [Route] = []
    @State private var scoreOpen = false
    /// The right page (design/DESIGN_SYSTEM.md §7.2): what a tool-row button
    /// or a row's action opened, beside the page. One for the library side;
    /// the score has its own.
    @StateObject private var panel = PanelModel()
    /// A new piece or set list being named in place at the top of the list.
    @State private var libraryNaming: String?
    /// A row the library should open a rename on -- the set list just made
    /// from a selection (REDESIGN_BRIEF_0.8 §7.4 rule 4).
    @State private var libraryRenameRequest: String?

    /// Whether the app is frontmost, for ScreenWake. The idle timer is an
    /// application-wide flag, so the app's claim on the screen is dropped on
    /// the way out and taken again on the way back.
    @Environment(\.scenePhase) private var scenePhase

    /// The one place the three facts meet. `scoreOpen` rather than
    /// `state.selectedScore != nil`: a score stays selected while the reader
    /// is back in the library -- that is what makes returning to it cheap --
    /// so selection is not the same question as whether anybody is reading.
    private var screenShouldStayLit: Bool {
        ScreenWake.shouldStayLit(readingScore: scoreOpen,
                                 playing: state.playback.isPlaying,
                                 appActive: scenePhase == .active)
    }

    @State private var librarySearch = ""
    @State private var segment: LibrarySegment = .pieces
    @State private var sort: LibrarySort = .name
    @State private var filters: Set<LibraryFilter> = []
    @State private var editing = false

    /// The piece an import should land in, set only by a piece's own "Import
    /// into this piece". A plain Import leaves it nil and the score arrives
    /// unfiled.
    @State private var importIntoPiece: String?
    @State private var showSettings = false
    /// What the one file picker is currently being asked for.
    ///
    /// ONE `.fileImporter`, not three. Three of them on the same view is a
    /// SwiftUI trap: stacked importers swallow each other and tapping Import
    /// opened nothing at all -- the same "import is broken" failure the app
    /// already shipped once. The three ACTIONS remain; they set this and share
    /// a single presenter.
    @State private var importIntent = ImportIntent()
    /// The camera roll's own picker, which is not a document picker.
    @State private var showPhotoImport = false


    var body: some View {
        ZStack {
            Theme.Surface.band.ignoresSafeArea()

            // The table (§7.1): the page 16 from the edges, the panel beside
            // it when something is open. Pushed pages ride inside the stack;
            // the panel stays put and each page sets what it shows at rest.
            PanelHost(panel: panel, suspended: scoreOpen) {
                NavigationStack(path: $libraryPath) {
                    library.navigationBarHidden(true)
                        .navigationDestination(for: Route.self) { screen($0) }
                }
                .pageShape()
            } content: { route in
                screen(route, inPanel: true)
            }
            .padding(.horizontal, Theme.Metric.tableMargin)
            .environmentObject(panel)
            // A page change closes what a row on the page before had open.
            .onChange(of: libraryPath) { _, _ in panel.done() }
            // An import opens what it brought in (Ali, build 193): from Files
            // and from another app's share sheet alike.
            .onChange(of: state.openAfterImport) { _, slug in
                guard let slug else { return }
                state.openAfterImport = nil
                open(slug)
            }
            // A file shared in is asked about before it is imported (0.14.0
            // §1). The reader came from another app to put it somewhere, so
            // the question is put in front of them, over a score if one is
            // open: the score keeps its place and is one tap back.
            .onChange(of: state.importOffer) { old, offer in
                guard offer != nil, old == nil else { return }
                if scoreOpen { close() }
                if libraryPath.last != .importAs { libraryPath.append(.importAs) }
            }
            // A book just imported opens on its proposed tunes, in Extract.
            .onChange(of: state.openBookAfterImport) { _, slug in
                guard let slug else { return }
                state.openBookAfterImport = nil
                segment = .books
                if libraryPath.last == .importAs { _ = libraryPath.popLast() }
                // The book, and on it Extract, where its found tunes are
                // ticked or saved (0.19.0); Back is the book itself.
                libraryPath.append(.book(slug))
                libraryPath.append(.bookExtract(slug))
            }
            // SHARING'S PROGRESS AND FAILURES, through the app's own notice
            // bar rather than a second surface invented for this one feature.
            //
            // Found by running it: only the `.ready` state had any UI, so
            // tapping share while signed out set `.failed` and NOTHING
            // appeared -- a control that did nothing and said nothing, which
            // is the exact failure the Apple button had. A state machine with
            // an unrendered state is a silent one.
            .onChange(of: sharing.state) { _, now in
                switch now {
                case .working(let done, let total):
                    state.notice = total > 0
                        ? "Sharing… \(done) of \(total) uploaded."
                        : "Sharing…"
                case .failed(let why):
                    state.notice = why
                case .ready, .idle:
                    break       // the sheet speaks for `ready`
                }
            }
            // A tapped invite link, from a cold launch or from anywhere in
            // the app. `.task` catches the cold case -- the URL is delivered
            // before this view exists -- and `.onChange` the warm one.
            .task { routePendingInvite(state.pendingInvite) }
            .onChange(of: state.pendingInvite) { _, new in
                routePendingInvite(new)
            }
            // The share sheet, and the two states before it.
            .sheet(isPresented: Binding(
                get: { if case .ready = sharing.state { return true } else { return false } },
                set: { if !$0 { sharing.clear() } })) {
                if case .ready(let url, let name) = sharing.state {
                    ShareSheet(items: [ShareSetlistAction.message(name: name, url: url)])
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .opacity(scoreOpen ? 0 : 1)
            // hidden, not unloaded: coming back to the library should not cost
            // a rebuild, and the score is what is expensive to re-open
            .allowsHitTesting(!scoreOpen)
            // and out of the accessibility tree too: an invisible page's
            // buttons were still elements, so a test (or VoiceOver) asking
            // for the panel's Done found the piece screen's, under the score,
            // and tapped the score bar's Perform where it lay.
            .accessibilityHidden(scoreOpen)

            // Above the score too: a PDF that will not transcribe has its say
            // while the reader is looking at that very score.
            if let message = state.notice {
                VStack {
                    Spacer()
                    NoticeBar(message: message) { state.notice = nil }
                        .padding(.bottom, Theme.Metric.s20)
                        .padding(.horizontal, Theme.Metric.s16)
                }
                .zIndex(2)
            }

            if let offer = state.bundleOffer, !scoreOpen {
                VStack {
                    Spacer()
                    BundleOfferBar(summary: offer.summary, detail: offer.detail,
                                   onImport: { Task { await state.acceptBundle() } },
                                   onDismiss: { state.bundleOffer = nil })
                        .padding(.bottom, Theme.Metric.s20)
                }
                .zIndex(3)
            }

            if let undo = state.undoableDelete, !scoreOpen {
                VStack {
                    Spacer()
                    UndoBar(what: undo.what,
                            onUndo: { state.restoreDeleted() },
                            onDismiss: {
                                state.undoableDelete = nil
                                Task { await state.sweepDeleted() }
                            })
                        .padding(.bottom, Theme.Metric.s20)
                }
            }

            if scoreOpen {
                ContentView(onClose: close)
                    .transition(.opacity)
            }
        }
        // The screen stays lit while a score is being read, and goes back to
        // the system's own timer everywhere else (ScreenWake). All three facts
        // are visible here and nowhere else: the library and the score are
        // siblings in this ZStack, and the transport belongs to AppState.
        .onChange(of: screenShouldStayLit, initial: true) { _, lit in
            UIApplication.shared.isIdleTimerDisabled = lit
            // The rule is unit-tested; that the FLAG follows it is not
            // observable from a test bundle with no host app, so the wiring is
            // verified by driving the app and reading this back. NSLog rather
            // than print, because a GUI app's stdout does not reach the
            // unified log and print would leave nothing to read:
            //   xcrun simctl spawn <udid> log stream \
            //     --predicate 'eventMessage CONTAINS "SCREEN-WAKE"'
            NSLog("SCORANGER-SCREEN-WAKE idleTimerDisabled=%@ reading=%@ playing=%@ active=%@",
                  String(describing: UIApplication.shared.isIdleTimerDisabled),
                  String(describing: scoreOpen),
                  String(describing: state.playback.isPlaying),
                  String(describing: scenePhase == .active))
        }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .task {
            // reclaim anything whose undo window passed while the app was shut
            await state.sweepDeleted()
            // and clear pieces left holding nothing by a build that shipped
            // without the empty-piece rule. tidyPieces existed and worked and
            // was called from NOWHERE, so Ali's "Morrison's Jig -- 0
            // arrangements" survived every launch: the sweep that was supposed
            // to remove it never ran.
            await state.tidyPieces()
            // and number every arrangement's first full bar 1: chat counts
            // bars as the page does, and an ABC tune came in from 0
            await state.numberBarsFromOne()
            Theme.verifyFontsRegistered()
            state.migrateScoreLayout()
            state.startPolling()
            #if DEBUG
            // Measurement fixture (L21): reach the spread with no tapping, so
            // the layout can be read on a rotated simulator without XCUITest,
            // whose rotation kills the runner on the 11-inch.
            if ProcessInfo.processInfo.arguments.contains("-forceLandscape"),
               let scene = UIApplication.shared.connectedScenes
                   .compactMap({ $0 as? UIWindowScene }).first {
                scene.requestGeometryUpdate(
                    .iOS(interfaceOrientations: .landscapeRight))
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
            if ProcessInfo.processInfo.arguments.contains("-openFirstScoreSpread") {
                for _ in 0..<120 where state.manifest?.scores.isEmpty != false {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    await state.refresh()
                }
                if let first = state.manifest?.scores.first?.slug {
                    let args = ProcessInfo.processInfo.arguments
                    state.layoutChoice = args.contains("-continuous") ? .continuous
                        : (args.contains("-spread") ? .spread : .page)
                    open(first)
                }
            }
            #endif
        }
        // The camera roll, which Files cannot reach. A sheet of its own
        // rather than a fourth `ImportKind`: PHPicker is not a document
        // picker and shares none of `fileImporter`'s presentation.
        .sheet(isPresented: $showPhotoImport) {
            PhotoImport(onPicked: { urls in
                showPhotoImport = false
                guard !urls.isEmpty else {
                    state.notice = "That picture could not be read."
                    return
                }
                // SEVERAL PHOTOS ARE ONE ARRANGEMENT OF n PAGES (§15 ruling
                // 2), in the order they were picked -- somebody photographing
                // a score is photographing a piece, and PHPicker hands its
                // results back in selection order, which is page order.
                //
                // Files multi-select is unchanged and still means n
                // arrangements: there, n files really are n things.
                state.receivePhotographedPages(urls)
                segment = .pieces
            }, onCancel: { showPhotoImport = false })
            .ignoresSafeArea()
        }
        // ONE presenter for all three actions -- see ImportKind.
        .fileImporter(isPresented: Binding(get: { importIntent.isPresented },
                                           set: { if !$0 { importIntent.dismissed() } }),
                      allowedContentTypes: importIntent.requested.contentTypes,
                      allowsMultipleSelection: importIntent.requested.allowsMultiple) { result in
            // Read from the REQUEST, never from the presentation: SwiftUI has
            // already cleared the latter by the time this runs (ImportIntent).
            let kind = importIntent.requested
            let piece = importIntoPiece
            importIntoPiece = nil
            switch result {
            case .failure(let error):
                // Swallowed until now: the picker failing and the picker
                // finding nothing looked identical from the outside.
                state.notice = "The file picker could not open that: "
                             + error.localizedDescription
                return
            case .success(let urls) where urls.isEmpty:
                state.notice = "Nothing was selected."
                return
            default: break
            }
            guard case .success(let urls) = result, let first = urls.first else { return }
            switch kind {
            case .file:
                for url in urls { state.receiveFile(at: url, intoPiece: piece) }
                segment = .pieces
            case .folder:
                // planned and shown before anything is written
                Task {
                    if await state.previewFolderImport(at: first) {
                        libraryPath.append(.folderImport)
                    }
                }
            case .book:
                state.importBook(at: first)
                segment = .books
            }
        }
    }

    /// Deleting knows what it is deleting: a set list is unmade, a piece takes
    /// its arrangements with it, an arrangement goes on its own.
    /// A quick action from the Import or New panel.
    private func runQuickAction(_ action: LibraryQuickAction) {
        switch action {
        case .importScore:  importIntent.ask(for: .file)
        case .importPhotos: showPhotoImport = true
        case .importFolder: importIntent.ask(for: .folder)
        case .importBook:   importIntent.ask(for: .book)
        }
    }

    /// The Filter panel's groups and counts (L4), from the rows the segment
    /// shows before any filter is applied.
    private var filterGroups: [LibraryModel.FilterGroup] {
        guard let manifest = state.manifest else { return [] }
        let base: [LibraryRow]
        switch segment {
        case .pieces:
            base = LibraryModel.pieceRows(manifest: manifest, arrangementTags: state.allArrangementTags)
                + LibraryModel.unfiledRows(manifest: manifest, arrangementTags: state.allArrangementTags)
        case .setlists: base = LibraryModel.setlistRows(manifest: manifest)
        case .books:    base = LibraryModel.bookRows(manifest: manifest)
        }
        return LibraryModel.filterGroups(rows: base, manifest: manifest)
    }

    private func commitDelete(_ row: LibraryRow) {
        if segment == .setlists {
            Task { _ = await state.deleteSetlist(row.id) }
        } else if (state.manifest?.pieces ?? []).contains(where: { $0.slug == row.id }) {
            state.deletePiece(row.id)
        } else {
            state.deleteScore(slug: row.id)
        }
    }

    /// What a route shows. Page routes are pushed on the stack; panel routes
    /// are drawn in the panel (`inPanel`), where back is the panel's own ‹ or
    /// Done and a push from inside opens beside. A push of a page route from
    /// anywhere goes on the stack.
    @ViewBuilder
    private func screen(_ route: Route, inPanel: Bool = false) -> some View {
        let pop: () -> Void = inPanel
            ? { if panel.canGoBack { panel.back() } else { panel.done() } }
            : { _ = libraryPath.popLast() }
        let push: (Route) -> Void = { next in
            if next.presentation == .panel { panel.push(next) } else { libraryPath.append(next) }
        }
        let importInto: (String) -> Void = { pieceSlug in
            importIntoPiece = pieceSlug
            importIntent.ask(for: .file)
        }
        // A route holds the slug it was pushed with, and an arrangement can be
        // MOVED to a new slug from the screen the route points at. Follow the
        // move rather than resolving to nothing.
        switch route.following(state.movedSlugs) {
        case .piece(let slug):
            if let piece = (state.manifest?.pieces ?? []).first(where: { $0.slug == slug }) {
                PieceScreen(piece: piece, onBack: pop,
                            onOpen: { open($0) }, push: push,
                            onImport: importInto)
                    .navigationBarHidden(true)
                    .accessibilityElement(children: .contain)
                .accessibilityIdentifier("screen-piece-\(slug)")
                    // The panel at rest on this page (P1).
                    .onAppear { panel.setRest(.thisPiece(slug)) }
                    .onDisappear { panel.clearRest(.thisPiece(slug)) }
            }
        case .sort:
            SortPanel(sort: $sort)
        case .filter:
            FilterPanel(filters: $filters, groups: filterGroups)
        case .importMenu:
            ImportPanel(run: runQuickAction)
        case .pieceArrangements(let slug):
            PieceArrangementsPanel(slug: slug, onOpen: { open($0) },
                                   onPieceScreen: { libraryPath.append(.piece(slug)) },
                                   onImport: importInto)
        case .thisPiece(let slug):
            ThisPiecePanel(slug: slug, onImport: importInto,
                           onDeleted: { if libraryPath.last == .piece(slug) { _ = libraryPath.popLast() } })
        case .thisSetlist(let slug):
            ThisSetlistPanel(slug: slug, push: push,
                             onShare: { shareSetlist(slug) },
                             onRemoved: { if libraryPath.last == .setlist(slug) { _ = libraryPath.popLast() } })
        case .setlistInvite(let slug):
            if let shareId = (state.manifest?.setlists ?? []).first(where: { $0.slug == slug })?.shareId {
                SharedSetlistScreen(setlistId: shareId, onBack: pop, onOpen: { open($0) })
            }
        case .arrangement(let slug):
            if let score = state.manifest?.scores.first(where: { $0.slug == slug }) {
                ArrangementScreen(score: score, onBack: pop,
                                  onOpen: { open(slug) }, push: push)
                    .navigationBarHidden(true)
                    .accessibilityElement(children: .contain)
                .accessibilityIdentifier("screen-arrangement-\(slug)")
            }
        case .book(let slug):
            BookScreen(slug: slug, onBack: pop, onOpen: { open($0) },
                       onRead: { libraryPath.append(.bookEntry(slug, $0)) },
                       onExtract: { libraryPath.append(.bookExtract(slug)) })
                .navigationBarHidden(true)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("screen-book-\(slug)")
        case .bookExtract(let slug):
            BookExtractScreen(slug: slug, onBack: pop, onOpen: { open($0) },
                              onShowTunes: {
                                  state.bookTunesOpen = slug
                                  pop()
                              })
                .navigationBarHidden(true)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("screen-book-extract-\(slug)")
        case .bookEntry(let slug, let entry):
            // Next and previous REPLACE the page rather than stacking it: back
            // goes to the book, as a set list's reader goes back to its list.
            BookEntryReader(slug: slug, entryID: entry, onBack: pop,
                            onStep: { next in
                                if case .bookEntry = libraryPath.last { _ = libraryPath.popLast() }
                                libraryPath.append(.bookEntry(slug, next))
                            })
                .navigationBarHidden(true)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("screen-book-entry")
        case .importAs:
            ImportAsScreen(onBack: {
                               state.declineImport()
                               pop()
                           },
                           onChosen: { choice in
                               pop()
                               state.acceptImport(choice)
                               if case .newBook = choice { segment = .books } else { segment = .pieces }
                           })
                .navigationBarHidden(true)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("screen-import-as")
        case .folderImport:
            FolderImportScreen(onBack: pop)
                .navigationBarHidden(true)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("screen-folder-import")
        case .moveToPiece(let slugs):
            MoveToPieceScreen(moving: slugs, onBack: pop)
                .navigationBarHidden(true)
        case .combinePieces(let slugs):
            CombinePiecesScreen(combining: slugs, onBack: pop)
                .navigationBarHidden(true)
        case .setlistsFor(let slug):
            SetlistsForScreen(slug: slug, onBack: pop)
                .navigationBarHidden(true)
        case .setlist(let slug):
            SetlistScreen(slug: slug, onBack: pop,
                          onOpen: { member in
                              if let setlist = state.manifest?.setlists?
                                  .first(where: { $0.slug == slug }) {
                                  state.currentSetlist = setlist.slug
                              }
                              open(member)
                          },
                          push: push,
                          onShare: { shareSetlist(slug) })
                .navigationBarHidden(true)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("screen-setlist-\(slug)")
                // The panel at rest on this page (S1).
                .onAppear { panel.setRest(.thisSetlist(slug)) }
                .onDisappear { panel.clearRest(.thisSetlist(slug)) }
        case .joinSetlist(let inviteId):
            JoinSetlistScreen(inviteId: inviteId, onBack: pop,
                              onJoined: { slug in
                                  // §6A.5: "the set list appears in Setlists as
                                  // a normal row. The screen pops to it." So:
                                  // back to the list, on the Setlists segment,
                                  // and say what just arrived. Not the shared
                                  // screen -- that is one tap away on the row,
                                  // and landing there hid the fact that the
                                  // row now exists.
                                  libraryPath.removeLast()
                                  segment = .setlists
                                  let name = state.manifest?.setlists?
                                      .first(where: { $0.slug == slug })?.name ?? "the set list"
                                  state.notice = "Added \"\(name)\" to your set lists."
                              })
                .navigationBarHidden(true)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("screen-join-setlist")
        case .sharedSetlist(let id):
            SharedSetlistScreen(setlistId: id, onBack: pop,
                                onOpen: { open($0) })
                .navigationBarHidden(true)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("screen-shared-setlist")
        case .addArrangements(let slug):
            AddArrangementsScreen(slug: slug, onBack: pop)
                .navigationBarHidden(true)
        case .versions(let slug):
            // picking a version MARKS it and stays on the list: this is the
            // history, and reading it means moving down it. The score opens on
            // whatever is marked when you go back to it -- and while reading,
            // the title band in the score is the faster way to switch.
            VersionsScreen(slug: slug, onBack: pop,
                           onShow: { version in
                               state.select(slug: slug, version: version)
                           })
                .navigationBarHidden(true)
        case .parts(let slug):
            PartsScreen(slug: slug, onBack: pop)
                .navigationBarHidden(true)
        case .details(let slug):
            // resolved ONCE, into a view that then follows its own edits: the
            // slug is editable on this screen, and re-resolving by slug on
            // every manifest tick closed the screen the instant a move landed
            DetailsScreen(slug: slug, onBack: pop)
                .navigationBarHidden(true)
        case .settings, .settingsSection:
            SettingsPage(onBack: pop)
                .navigationBarHidden(true)
        }
    }

    // MARK: - The place

    // The "where should this land?" chooser lived here -- an enum, a screen
    // and a row builder. It is gone (see `onImport` above): it asked a
    // question before the file picker that is better answered after, and the
    // path through it was broken outright.

    private var library: some View {
        LibraryView(segment: $segment, search: $librarySearch, sort: $sort,
                    filters: $filters, editing: $editing,
                    creatingName: $libraryNaming,
                    onOpenPiece: openPieceOrArrangement,
                    onOpenArrangement: { open($0) },
                    onOpenSetlist: openSetlist,
                    onOpenSharedSetlist: { libraryPath.append(.sharedSetlist($0)) },
                    onShareSetlist: { slug in shareSetlist(slug) },
                    onOpenBook: { libraryPath.append(.book($0)) },
                    onOpenPieceScreen: { libraryPath.append(.piece($0)) },
                    onOpenSetlistScreen: { libraryPath.append(.setlist($0)) },
                    onCreate: { name in
                        Task {
                            if segment == .setlists {
                                // a set list with nothing in it is not worth
                                // making, so naming one leads straight to
                                // choosing what goes in it
                                if let slug = await state.createSetlist(name: name) {
                                    // S3: Add opens beside the new list's row.
                                    panel.open(.addArrangements(slug))
                                }
                            } else {
                                _ = await state.createPiece(named: name)
                            }
                        }
                    },
                    // Straight to the system picker. It used to push a screen
                    // asking WHICH PIECE first, and that screen could not
                    // deliver: naming a new piece ran `pop()` and
                    // `showImporter = true` in the same tick, so SwiftUI threw
                    // the presentation away mid-transition and the file picker
                    // never appeared. Import was unusable.
                    //
                    // The question it asked is answerable later and better: a
                    // score arrives UNFILED, it is visible in the library as
                    // its own row, and filing it is Move to piece whenever you
                    // like. Asking first put a modal-shaped question in front
                    // of the one thing the button exists to do.
                    onImport: { importIntent.ask(for: .file) },
                    onImportPhotos: { showPhotoImport = true },
                    onImportFolder: { importIntent.ask(for: .folder) },
                    onImportBook: { importIntent.ask(for: .book) },
                    onSettings: { libraryPath.append(.settings) },
                    onRowAction: handle,
                    onBarAction: handleBar,
                    renameRequest: $libraryRenameRequest)
    }

    /// Choosing between the arrangements of a piece (§4.4). A piece is not
    /// openable; opening one means opening one of its arrangements.
    /// Choosing between the arrangements of a piece (§4.4), with their
    /// versions -- the sidebar's expandable rows, rehomed.
    // MARK: - Row actions -- the sidebar's management, rehomed (§8)

    /// The Edit-mode action bar (§2.2), over whatever is highlighted.
    private func handleBar(_ action: LibraryAction, _ ids: [String],
                           _ kind: LibrarySelectionKind) {
        let scores = ids.compactMap { id in state.manifest?.scores.first { $0.slug == id } }
        switch action {
        case .newArrangement:
            guard let id = ids.first else { return }
            Task { _ = await state.createArrangement(pieceSlug: id) }
        case .moveToPiece:
            libraryPath.append(.moveToPiece(scores.map(\.slug)))
        case .combine:
            // Pieces, not arrangements, and in the order the list shows them:
            // the first is the one that survives, which is what the screen
            // says before the button.
            //
            // Edit mode goes off here, as it does for New set list, and for a
            // sharper reason: combining DELETES the pieces it absorbs, so a
            // selection left standing afterwards names rows that no longer
            // exist. The bar would keep offering Delete over them and the
            // engine would refuse a slug it cannot find. `ids` is already
            // copied into the route, so clearing the selection cannot take
            // the screen's subject with it.
            editing = false
            libraryPath.append(.combinePieces(ids))
        case .addToSetlist:
            if let first = scores.first { libraryPath.append(.setlistsFor(first.slug)) }
        case .newSetlist:
            // A set list from the checked pieces (REDESIGN_BRIEF_0.8 §7.4):
            // arrangement #1 of each, in the list's order; a piece with none
            // is skipped and said so; the proposed name (§7.5) arrives in the
            // new row's rename field, selected, so one keystroke replaces it.
            let pieces = state.manifest?.pieces ?? []
            let chosen = ids.compactMap { id in pieces.first { $0.slug == id } }
            let plan = SetlistFromSelection.plan(pieces: chosen)
            guard !plan.members.isEmpty else {
                // Nothing to make; the selection survives (rule 3).
                state.notice = plan.notices.joined(separator: " ")
                return
            }
            let taken = Set((state.manifest?.setlists ?? []).map(\.name))
            let name = SetlistNaming.name(
                for: chosen.map { SetlistNaming.Piece(title: $0.name, composer: $0.composer) },
                taken: taken)
            editing = false
            Task {
                guard let slug = await state.createSetlist(name: name) else { return }
                for member in plan.members { _ = await state.addToSetlist(setlist: slug, score: member) }
                segment = .setlists
                if !plan.notices.isEmpty { state.notice = plan.notices.joined(separator: " ") }
                libraryRenameRequest = slug
            }
        case .duplicate:
            Task { for score in scores { _ = await state.duplicateScore(slug: score.slug) } }
        case .delete:
            // the undo bar is the confirmation: the row goes at once and comes
            // back for as long as the engine still holds it
            for id in ids {
                switch kind {
                case .setlists: Task { _ = await state.deleteSetlist(id) }
                case .pieces:   state.deletePiece(id)
                default:        state.deleteScore(slug: id)
                }
            }
            editing = false
        }
    }

    /// Every row currently in the library, for the bar to name what it is
    /// acting on.
    private var libraryRows: [LibraryRow] {
        guard let manifest = state.manifest else { return [] }
        return segment == .pieces
            ? LibraryModel.pieceRows(manifest: manifest)
                + LibraryModel.unfiledRows(manifest: manifest)
            : LibraryModel.setlistRows(manifest: manifest)
    }

    private func handle(_ row: LibraryRow, _ action: RowAction) {
        let score = state.manifest?.scores.first { $0.slug == row.id }
        switch action {
        case .open:
            open(row)
        case .versions:
            // a piece opens its own screen, which lists its arrangements;
            // a lone arrangement opens its versions directly
            if (state.manifest?.pieces ?? []).contains(where: { $0.slug == row.id }) {
                libraryPath.append(.piece(row.id))
            } else {
                libraryPath.append(.versions(row.id))
            }
        case .details:
            if score != nil {
                libraryPath.append(.details(row.id))
            } else if let piece = (state.manifest?.pieces ?? []).first(where: { $0.slug == row.id }),
                      let first = piece.arrangements.first {
                libraryPath.append(.details(first))
            }
        case .addToSetlist:
            // from a SET LIST, pick its arrangements; from an arrangement, pick
            // its set lists -- two directions, two questions
            if segment == .setlists {
                libraryPath.append(.addArrangements(row.id))
            } else if score != nil {
                libraryPath.append(.setlistsFor(row.id))
            } else if let piece = (state.manifest?.pieces ?? []).first(where: { $0.slug == row.id }),
                      let first = piece.arrangements.first {
                libraryPath.append(.setlistsFor(first))
            }
        case .delete:
            commitDelete(row)
        case .newArrangement:
            Task { _ = await state.createArrangement(pieceSlug: row.id) }
        }
    }

    private func open(_ row: LibraryRow) {
        if segment == .setlists,
           let setlist = (state.manifest?.setlists ?? []).first(where: { $0.slug == row.id }) {
            openSetlist(setlist)
        } else {
            openPieceOrArrangement(row.id)
        }
    }


    // MARK: - Transitions

    private func openPieceOrArrangement(_ slug: String) {
        guard let piece = (state.manifest?.pieces ?? []).first(where: { $0.slug == slug }) else {
            open(slug)
            return
        }
        // one arrangement opens straight away; several put the choice on screen
        if piece.arrangements.count == 1, let only = piece.arrangements.first {
            open(only)
        } else {
            // A piece with several arrangements PUSHES its screen (§4). It
            // used to open a sheet; the sheet is gone, and for a while this
            // set a flag nothing rendered -- so tapping such a piece did
            // nothing at all.
            libraryPath.append(.piece(slug))
        }
    }

    private func open(_ slug: String, version: String? = nil) {
        state.select(slug: slug, version: version)
        withAnimation(.easeOut(duration: 0.18)) { scoreOpen = true }
    }

    private func openSetlist(_ setlist: SetlistDoc) {
        state.currentSetlist = setlist.slug
        segment = .setlists
        if let first = setlist.arrangements.first { open(first) }
    }

    /// Share a set list from its row: promote if needed, then the iOS sheet.
    @StateObject private var sharing = ShareSetlistAction()

    /// A tapped invite link pushes the one confirmation screen.
    ///
    /// Watched here rather than handled at `onOpenURL`, because the link can
    /// arrive while the app is cold, mid-score, or on another tab -- and the
    /// screen has to be pushed onto the library's stack wherever the reader
    /// happens to be. Cleared immediately so a back-swipe does not re-push it.
    private func routePendingInvite(_ inviteId: String?) {
        guard let inviteId else { return }
        state.pendingInvite = nil
        if scoreOpen { close() }
        segment = .setlists
        libraryPath.append(.joinSetlist(inviteId))
    }

    private func shareSetlist(_ slug: String) {
        guard let setlist = (state.manifest?.setlists ?? [])
                .first(where: { $0.slug == slug }) else { return }
        // ALREADY SHARED: the row's glyph is two people, and two people is what
        // it opens -- who is in it, the invite, the link again, removal. It
        // used to run the whole promotion again from here, re-uploading every
        // arrangement and minting a fresh link on every tap.
        if let shareId = setlist.shareId {
            if scoreOpen { close() }
            segment = .setlists
            libraryPath.append(.sharedSetlist(shareId))
            return
        }
        Task {
            await sharing.share(setlist: setlist,
                                arrangements: state.manifest?.scores ?? [],
                                shared: shared, state: state,
                                signedIn: signIn.account != nil)
        }
    }

    /// X always returns to the library, because there is nowhere else.
    private func close() {
        // The music stops when the score goes. It did not: back to the set
        // list, and the performance -- click included -- carried on under a
        // screen with no transport on it (Ali, 2026-09-10). The beat is left
        // where it was, so reopening resumes from there.
        if state.playback.isPlaying { state.playback.stop() }
        withAnimation(.easeOut(duration: 0.18)) { scoreOpen = false }
        // Leaving a shared entry stops the band's ink coming in AND stops mine
        // going out. Left installed, the store hook would push the next local
        // arrangement's private markup to whichever entry was open last
        // (design/FIREBASE.md §6.3).
        if state.openSharedEntry != nil {
            state.openSharedEntry = nil
            shared.closeInk(store: DrawingStore.shared)
        }
    }
}
