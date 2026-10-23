import SwiftUI
import UniformTypeIdentifiers

/// Score-first (§7, §8): the score is the permanent ground, the library and chat
/// slide over it, and every canvas control lives in one pill. There is no
/// navigation bar, no title bar and no split view — losing `NavigationSplitView`
/// is the largest change in the revamp.
struct ContentView: View {
    /// Leaving the score. The score view is presented OVER the tab bar and X is
    /// how you leave it (NAVIGATION_SYSTEM.md §3); the tabs own where "back"
    /// goes, so this only reports that it happened.
    var onClose: () -> Void = {}

    @EnvironmentObject var state: AppState
    /// Only for the band's markup, and only while a shared set list entry is
    /// what is open. Signed out it publishes nothing and this reads as empty
    /// (design/FIREBASE.md §6.3).
    @EnvironmentObject var shared: SharedSetlists
    @Environment(\.horizontalSizeClass) private var hSize
    @Environment(\.verticalSizeClass) private var vSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The band's marks for every page of the entry that is open, or nothing.
    ///
    /// Nothing is the answer for a reader with no account, for an arrangement
    /// of their own, and for a shared entry nobody else has marked -- which is
    /// most of the time, and costs one dictionary lookup to establish.
    private var bandInk: [Int: [SharedInk.Layer]] {
        guard let open = state.openSharedEntry,
              let setlist = shared.setlists.first(where: { $0.id == open.setlist }),
              !shared.ink.isEmpty else { return [:] }
        let participants = Array(setlist.members.keys)
        let pages = Set(shared.ink.values.flatMap(\.keys))
        // The width the canvas is laid out at is the page's own width, which
        // the geometry knows; without it a bandmate's ink cannot be placed
        // (`SharedInk.scale`).
        let width = state.geometry?.page(0)?.size.width ?? 0
        return Dictionary(uniqueKeysWithValues: pages.map { page in
            (page, shared.layers(page: page, participants: participants,
                                 visibility: state.inkVisibility, readAt: width))
        })
    }

    /// The two overlays, which replace the split view's columns.

    /// Off by default and named a preview (§9.2): a transport that does nothing
    /// teaches people the app is broken. Previous and next step the setlist and
    /// work whether or not this is on.
    /// Defaults to TRUE since 0.6.1. It was false, and playback -- the whole
    /// of 0.6 -- was invisible behind a toggle in a submenu.
    /// Whether the transport has ever been put on screen unasked. Carries a
    /// reader holding a stored `false` from the builds where that was the
    /// default.

    /// Lane 1 is the ink bar's, and it is only occupied when the bar is out.
    private var inkLaneHeight: CGFloat { state.annotation.isOn ? 56 : 0 }
    private var syncLaneInset: CGFloat { inkLaneHeight + 12 }
    /// The mixer sits above whichever lanes are occupied. Recomputed when a
    /// lane appears or disappears -- never per frame, or the panel drifts
    /// under the reader's hand.
    /// Which list the title band is showing. The versions dropdown and the
    /// title block open the same band on two different columns (0.6.3 #8).
    @State private var titleMenuMode: TitleBandLayout.Mode = .versions
    @State private var exportRequested = 0
    @State private var scoreScreen: ScoreScreen?
    @State private var optionsSection: String?
    /// The score's panel (§7.2) is `scoreScreen`; Chat is one of its states.
    private var chatOpen: Bool { scoreScreen == .chat }
    private var panelOpen: Bool { scoreScreen != nil }
    /// The states More opened, for which the More button stays lit.
    private var moreOpen: Bool {
        switch scoreScreen {
        case nil, .chat, .titleVersions, .titleArrangements, .titleSetlists: return false
        // The scan's own offer is not something More opened, so More is not
        // lit while it is showing; the same state opened FROM More is.
        case .convert(let fromMore): return fromMore
        default: return true
        }
    }
    private var railShown: Bool {
        state.scoreMode != .performance && !state.layout.isContinuous && !isCompact
            && state.pdfDocument != nil
    }
    /// Done: the panel closes whatever it showed.
    private func closePanel() {
        withAnimation(Theme.Motion.overlay(reduced: reduceMotion)) {
            scoreScreen = nil
            optionsSection = nil
            state.titleMenuOpen = false
        }
    }
    private func setPanel(_ screen: ScoreScreen?) {
        withAnimation(Theme.Motion.overlay(reduced: reduceMotion)) {
            if screen != .options { optionsSection = nil }
            scoreScreen = screen
            switch screen {
            case .titleVersions, .titleArrangements, .titleSetlists: break
            default: state.titleMenuOpen = false
            }
        }
    }
    /// ‹ inside the panel, when a state opened from another.
    private func panelBack(for screen: ScoreScreen) -> (() -> Void)? {
        switch screen {
        case .options, .optionsSection:
            return optionsSection == nil ? nil : { optionsSection = nil }
        case .setlists, .details, .settings:
            return { setPanel(.options) }
        case .convert(let fromMore):
            // Nothing behind the offer when the scan itself opened it.
            return fromMore ? { setPanel(.options) } : nil
        case .chatModel:
            return { setPanel(.chat) }
        case .chat, .titleVersions, .titleArrangements, .titleSetlists:
            return nil
        }
    }
    @State private var didSetInitialOverlays = false
    /// The height the score view has, so the title band can be capped against
    /// it rather than taking whatever it is offered (L16).
    @State private var scoreHeight: CGFloat = 0
    /// The top bar's measured width, owned here because TWO views decide from
    /// it: the bar seats what it can, and Options carries the switches the bar
    /// could not (0.6.8). One measurement, one `Fit`, so a switch cannot end up
    /// in both places or in neither.
    @State private var barWidth: CGFloat = 0
    /// The keyboard, watched rather than obeyed: the score screen opts out of
    /// SwiftUI's automatic avoidance so the page keeps its size, and the chat
    /// panel lifts its own input instead (#59).
    @StateObject private var keyboard = KeyboardObserver()

    @State private var showSettings = false
    @State private var showImporter = false
    /// Piece rows are expanded by default; track only the collapsed ones.
    @State private var collapsedPieces: Set<String> = []
    @State private var collapsedSetlists: Set<String> = []
    /// Arrangements showing their version history.
    @State private var expandedArrangements: Set<String> = []
    /// Prompt groups showing their steps, keyed "<slug>/<group id>".
    @State private var expandedVersionGroups: Set<String> = []
    @State private var infoScore: ScoreDoc?
    @State private var importTargetPiece: String?
    /// Every dialog goes through one request, so they cannot disagree.
    @State private var newPieceName = ""
    @State private var newSetlistName = ""
    /// An arrangement that should go into the setlist about to be created.
    @State private var setlistSeedScore: String?
    /// The setlist whose arrangement picker is open.
    @State private var setlistPicker: SetlistDoc?
    /// The arrangement being put into a set list from its own row.
    @State private var setlistChooserScore: ScoreDoc?

    /// The list moved to `ImportKind`, where the tests can reach it. Kept
    /// here under its own name: this is where the rest of the app asks.
    static let scoreTypes: [UTType] = ImportKind.scoreTypes

    /// Build identity, read from the bundle so what is displayed is exactly the
    /// CFBundleVersion App Store Connect records.
    static let buildStamp: String = {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let sha = (Bundle.main.url(forResource: "build-sha", withExtension: "txt")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) })?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "v\(version) · b\(build)" + (sha.map { " · \($0)" } ?? "")
    }()

    private var isCompact: Bool { hSize == .compact }

    /// A PHONE ON ITS SIDE, which is the only place both size classes are
    /// compact. It is the case with 130pt of chrome budget rather than 266,
    /// and the one §3 E-B merges the deck for.
    ///
    /// IT IS NEVER TRUE TODAY. The app is portrait-only on iPhone, and the
    /// one line that says so is
    /// `INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone` in
    /// project.yml -- which carries the note about what else wakes up when it
    /// changes. Kept rather than deleted because the layout it chooses is
    /// designed, built and tested: it is waiting for the orientation, not for
    /// the code.
    private var isPhoneLandscape: Bool { isCompact && vSize == .compact }

    /// Go to the unit holding that page.
    ///
    /// A tap on the rail or the scrubber is a page turned BY THE READER just
    /// as much as a swipe is, so it yields following the same way. It does not
    /// go through `step(by:)`, which is where the swipe path hooks this -- so
    /// it needs its own call, or paging from either control would leave the
    /// score snapping back.
    ///
    /// One function, because the rail and the scrubber are two shapes of the
    /// same act and a second copy would drift from this one.
    /// The scrubber, when it is riding in the transport's row rather than
    /// having one of its own. Nil everywhere else, which is what makes the
    /// deck a merge rather than a duplicate.
    private var mergedScrubber: AnyView? {
        guard isPhoneLandscape, state.scoreMode != .performance,
              !state.layout.isContinuous,
              let document = state.pdfDocument else { return nil }
        return AnyView(PageScrubber(pageCount: document.pageCount,
                                    current: state.visiblePageIndices.first ?? 0,
                                    onJump: jumpToPage)
            .background(Color.clear))
    }

    private func jumpToPage(_ index: Int) {
        state.readerTurnedPage()
        state.pageIndex = PagedCanvas.index(forPage: index,
                                            spread: state.twoPageSpread)
    }

    /// What the top bar can seat at its measured width. Read by the bar and by
    /// Options, which carries what the bar could not.
    private var barFit: ScoreBarLayout.Fit {
        ScoreBarLayout.fit(barWidth: barWidth, omrBusy: state.omrBusy,
                           compact: isCompact)
    }

    var body: some View {
        // A GeometryReader, and not a measurement taken anywhere inside: it is
        // handed its size by its PARENT and nothing below it can change that.
        // Every other place this could go is downstream of the bar -- a
        // `.background` is sized to its content, and a VStack widens to its
        // widest child -- so an overflowing bar reports its overflow, believes
        // it has the room, and seats one more control. Measured on an iPhone
        // 17 Pro: a 402pt screen reporting 411 and seating the numeral and the
        // subtitle it could not draw, with the title left as "S…".
        //
        // The width is also IMPOSED, not only measured. Without the frame the
        // stack is still free to grow past the screen; with it, the bar has to
        // fit inside what it was told.
        GeometryReader { geo in
            ZStack {
                scoreBody
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .onAppear { barWidth = geo.size.width }
            .onChange(of: geo.size.width) { _, new in barWidth = new }
        }
    }


    @ViewBuilder
    private func scoreScreenView(_ screen: ScoreScreen) -> some View {
        switch screen {
        case .options, .optionsSection:
            ScoreOptionsScreen(mode: $state.scoreMode,
                               barFit: barFit,
                               section: optionsSection,
                               onBack: {
                                   if optionsSection != nil { optionsSection = nil }
                                   else { scoreScreen = nil }
                               },
                               push: { optionsSection = $0 },
                               onSettings: { scoreScreen = .settings },
                               onDetails: { scoreScreen = .details },
                               onSetlists: { scoreScreen = .setlists },
                               onConvert: { setPanel(.convert(fromMore: true)) })
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("score-options")
        case .setlists:
            // The pieces list's own screen (Route.setlistsFor -> this same
            // view), pushed from here because the score's stack is keyed by
            // ScoreScreen and not by Route. Nothing about it is re-implemented:
            // the checklist, the inline "New set list" that files this
            // arrangement into what it makes, and the wording are all the ones
            // a reader met coming the other way.
            if let score = state.selectedScore {
                // No identifier on the container, deliberately. An
                // accessibilityIdentifier applied to a whole Screen lands on
                // its first element and REPLACES the one already there --
                // PieceScreen's back button reports `screen-piece-<slug>` and
                // not `screen-back` for exactly that reason. Naming this one
                // would have made the two entrances differ in the tree, which
                // is the one thing §16 is trying to avoid.
                SetlistsForScreen(slug: score.slug,
                                  onBack: { setPanel(.options) })
            }
        case .details:
            if let score = state.selectedScore {
                Screen(title: "Details", backLabel: "More",
                       subtitle: ScoreTitle.arrangementName(title: score.title,
                                                            name: score.name,
                                                            slug: score.slug),
                       onBack: { setPanel(.options) }) {
                    ScoreInfoView(score: score)
                }
            }
        case .settings:
            // The SPLIT, not the flat list (0.8.2, the fourth of what 0.8.0
            // said it did not have). At 380 the split takes its compact leg --
            // the index alone, each section pushed over it with a ‹ of its own
            // (Ph6) -- so the score's panel and the Settings page are one
            // surface at two widths rather than two surfaces.
            //
            // `scrolls: false`: the split scrolls its index and its section
            // itself, and a ScrollView around a GeometryReader gives it zero
            // height to lay out in.
            Screen(title: "Settings", backLabel: "More",
                   onBack: { setPanel(.options) }, scrolls: false) {
                SettingsSplit()
            }
        case .convert:
            ConvertPanel(onAnswered: {
                state.recordConvertAnswer(for: state.selectedScore?.slug ?? "")
                closePanel()
            })
        case .chatModel:
            ChatModelScreen(onBack: { setPanel(.chat) })
        case .chat:
            chatPanel
        case .titleVersions, .titleArrangements, .titleSetlists:
            if let score = state.selectedScore {
                TitleSwitcherBand(score: score,
                                  mode: titleMenuMode,
                                  onPickArrangement: { slug in
                                      closePanel()
                                      state.select(slug: slug)
                                  },
                                  onPickVersion: { version in
                                      closePanel()
                                      state.pinnedVersion = version
                                      Task { await state.renderIfNeeded() }
                                  },
                                  onAllVersions: {
                                      state.titleMenuOpen = false
                                      optionsSection = "Versions"
                                      scoreScreen = .options
                                  },
                                  inPanel: true,
                                  onDone: { closePanel() })
            }
        }
    }

    /// The score bar, and on a phone its SECOND ROW (Ph4). One call
    /// site, two instances: the row is what differs, and every binding
    /// they share is shared rather than copied.
    private func scoreBar(row: ScoreTopBar.Row) -> some View {
        ScoreTopBar(annotation: state.annotation,
                    number: state.selectedScore
                        .flatMap { state.placement(of: $0.slug)?.number },
                    title: scoreTitle,
                    subtitle: scoreSubtitle,
                    origin: scoreOrigin,
                    mode: $state.scoreMode,
                    titleMenuOpen: $state.titleMenuOpen,
                    titleMenuMode: $titleMenuMode,
                    barWidth: $barWidth,
                    // The bar clears More when it opens something else;
                    // that must not close what it just opened.
                    moreOpen: Binding(get: { moreOpen },
                                      set: { on in
                                      if on {
                                          setPanel(.options)
                                      } else if moreOpen {
                                          // Only More goes: the bar
                                          // clears it AFTER opening
                                          // the title menu, which
                                          // must stay open.
                                          withAnimation(Theme.Motion.overlay(reduced: reduceMotion)) {
                                              scoreScreen = nil
                                              optionsSection = nil
                                          }
                                      }
                                      }),
                    chatOpen: chatOpen,
                    onClose: onClose,
                    onAsk: { setPanel(chatOpen ? nil : .chat) },
                    row: row)
    }

    private var scoreBody: some View {
        VStack(spacing: 0) {
            scoreBar(row: .bar)
            ZStack(alignment: .top) {
                Theme.Surface.band
                canvasLayer
                overlayLayer
                // The two menus the top bar opens. Plain children of the
                // canvas stack rather than an overlay on the whole view: as an
                // overlay they did not materialise at all, and a menu that
                // cannot be opened is worse than one that is in the wrong place.

            }
            // What this arrangement IS, opposite the counters (0.6.3 #5).
            .overlay(alignment: .topLeading) {
                if state.selectedScore != nil, state.pdfDocument != nil,
                   ScorePosition.counterShown(panelOpen: panelOpen, isCompact: isCompact) {
                    ArtifactMarker(kind: state.displayedArtifact)
                        .padding(.top, Theme.Metric.s8)
                        .padding(.leading, Theme.Metric.s12)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .topTrailing) {
                VStack(alignment: .trailing, spacing: Theme.Metric.s6) {
                    if state.selectedScore != nil,
                       ScorePosition.counterShown(panelOpen: panelOpen, isCompact: isCompact) {
                        LiveCounters(playback: state.playback,
                                     pages: state.layout.showsPageCounter ? pageCounter : nil,
                                     bar: barCounter,
                                     probe: ProcessInfo.processInfo.arguments
                                        .contains("-geometryProbe")
                                        ? [state.geometry?.probeDescription,
                                           state.seedOutcome.map { "seed[\($0)]" }]
                                            .compactMap { $0 }.joined(separator: " ")
                                        : nil)
                            .allowsHitTesting(false)
                    }
                    // The transcription chip where the BAR could not seat it: a
                    // phone at reading width has about four points of slack,
                    // and OMR running with no sign of it in the score view is
                    // what 0.6.8 set out to fix. Same view, same signal -- only
                    // where it sits changes, and it sits here only while the
                    // bar is not showing it.
                    if let here = state.omrHere, !barFit.showsOMRProgress,
                       state.scoreMode != .performance {
                        OMRProgressChip(control: MakeEditable.control(status: here),
                                        action: { setPanel(.convert(fromMore: false)) })
                    }
                }
                .padding(.top, Theme.Metric.s8)
                // clear of the chat panel: these belong to the music, and they
                // were being drawn over the chat's own header
                .padding(.trailing,
                         ScorePosition.counterTrailingInset(
                            chatOpen: panelOpen, isCompact: isCompact,
                            chatWidth: Theme.Metric.panelWidth + Theme.Metric.pagePanelGap,
                            base: Theme.Metric.s12))
            }
            // TWO gates, not one. They were a single condition, and that put
            // the transport behind `!isContinuous` -- so the scrolling view,
            // which is the ONE mode playing along to the score is for, was the
            // only mode with no transport at all.
            //
            // Performance mode still gives the score the whole screen: both go,
            // and the page-turn zones become the point (§4.5).
            //
            // The STRIP is a list of PAGES. Continuous mode has one, so the
            // strip showed a single thumbnail of the whole score -- true, and
            // useless. The designer's position markers are the right answer and
            // are not built yet; showing nothing is better than showing that.
            // A PHONE gets a 28pt scrubber where an iPad gets the 96pt rail.
            // The rail is better where there is room -- a legible thumbnail
            // says what a page IS, which no tick can -- but 96pt is more than
            // a third of a phone's whole chrome budget, spent on thumbnails
            // that at 52x68 show only that a page has staves (§9.6). Neither
            // screen loses a way to reach a page.
            if state.scoreMode != .performance, !state.layout.isContinuous,
               isCompact, !isPhoneLandscape, let document = state.pdfDocument {
                PageScrubber(pageCount: document.pageCount,
                             current: state.visiblePageIndices.first ?? 0,
                             onJump: jumpToPage)
            }
            // The phone's second row, between the canvas and the tray
            // (Ph4). It draws itself only where `ScoreBarLayout` says the bar
            // handed it something, so there is no second notion of "is this a
            // phone" anywhere in this file.
            scoreBar(row: .second)
            // THE TRAY (design/DESIGN_SYSTEM.md §7.7): always there while
            // reading -- there is no "show transport" any more -- and gone
            // with the bar in performance mode. It is the transport and the
            // mixer on one line.
            if state.scoreMode != .performance {
                Tray(setlistLabel: setlistLabel,
                     canStep: setlistPosition != nil,
                     onPrevious: { stepSetlist(-1) },
                     onNext: { stepSetlist(1) },
                     playback: state.playback,
                     unavailable: state.playbackAvailability,
                     preparing: state.playbackPreparing,
                     onPlay: { state.togglePlayback() },
                     onResolve: {
                         // The remote-engine case is fixed in Settings, which
                         // this view owns; the scan case is the engine's.
                         if state.playbackAvailability == .needsLocalEngine {
                             scoreScreen = .settings
                         } else {
                             state.resolvePlaybackAvailability()
                         }
                     },
                     // A phone on its side carries the page scrubber in the
                     // tray (§3 E-B), until 0.8.4's phone layout.
                     leading: mergedScrubber,
                     dimmed: state.annotation.isOn)
                    // Once the arrangement's pages are on screen, not before:
                    // loading the sound (the audio session, a sampler and its
                    // instrument per part) holds the main thread for 170 ms
                    // on "Espresso" (simulator), and when it landed beside the
                    // first page that page waited for it. An op keeps the
                    // previous version's pages up, so after one this starts
                    // at once, as it always did.
                    .task(id: PlaybackPreparation(version: state.displayedVersionID,
                                                  pagesShown: state.showsSelectedArrangement)) {
                        guard state.showsSelectedArrangement else { return }
                        await state.preparePlayback()
                    }
            }
        }
        // The title block's menu is a panel state now (SC4): the bar's own
        // flag says it is open and which mode, and the panel follows.
        .onChange(of: state.titleMenuOpen) { _, open in titleMenuChanged(open: open) }
        .onChange(of: titleMenuMode) { _, _ in titleMenuChanged(open: state.titleMenuOpen) }
        // SC13: the scan opens its own offer. Keyed on the displayed VERSION
        // rather than on the arrangement, because converting produces a new
        // version of the same slug and the offer must go when it does.
        .task(id: state.displayedVersionID) { offerConversionIfScan() }
        .background {
            GeometryReader { geo in
                Color.clear
                    .onAppear { scoreHeight = geo.size.height }
                    .onChange(of: geo.size.height) { _, new in scoreHeight = new }
            }
        }
        // The ink bar, over the WHOLE score screen -- strip and transport
        // included, so it can be moved anywhere on it (#46).
        .overlay(alignment: .bottom) {
            AnnotationBarLayer(controller: state.annotation)
        }
        // Lane 2 (§4): the sync chip, centred, 12pt above the ink bar's lane.
        // It is transient, so it gets a lane rather than a slot in a row that
        // would reflow around it as it comes and goes.
        .overlay(alignment: .bottom) {
            if state.scoreMode != .performance {
                SyncChipLayer(state: state, playback: state.playback)
                    .padding(.bottom, syncLaneInset)
            }
        }
        .background(Theme.Surface.band)
        // #59: the music is not resized by a text field taking focus. The
        // avoidance inset is a safe-area inset on the WHOLE screen -- the
        // canvas lost the keyboard's height and the page re-fitted to what was
        // left, collapsing a full page to a thumbnail. The pushed screens over
        // this one are ZStack siblings and keep their avoidance, so their
        // fields still lift; the chat panel, which lives inside here, lifts
        // itself in `overlayLayer`.
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .onChange(of: state.annotation.isOn) { _, on in
            // the ink bar can be dismissed from its own control, and the mode
            // must follow it or the top bar would lie about the Pencil
            if on { state.scoreMode = .edit } else if state.scoreMode == .edit { state.scoreMode = .read }
        }
        .task {
            Theme.verifyFontsRegistered()
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: Self.scoreTypes,
                      allowsMultipleSelection: true) { result in
            let piece = importTargetPiece
            importTargetPiece = nil
            if case .success(let urls) = result {
                for url in urls { state.receiveFile(at: url, intoPiece: piece) }
            }
        }
        // Panel dialogs, not system ones: a sheet is 620 wide over a 34% dim and
        // an alert has a band footer whose verb names the action (§7.15, §7.16).

    }

    // MARK: - The setlist, which is what the transport steps

    private var setlistPosition: (setlist: SetlistDoc, index: Int)? {
        guard let slug = state.currentSetlist, let current = state.selectedSlug,
              let setlist = state.manifest?.setlists?.first(where: { $0.slug == slug }),
              let index = setlist.arrangements.firstIndex(of: current) else { return nil }
        return (setlist, index)
    }

    private var setlistLabel: String? {
        guard let position = setlistPosition else { return nil }
        return "setlist · \(position.index + 1) of \(position.setlist.arrangements.count)"
    }

    private func stepSetlist(_ delta: Int) {
        guard let position = setlistPosition else { return }
        let next = position.index + delta
        guard position.setlist.arrangements.indices.contains(next) else { return }
        state.select(slug: position.setlist.arrangements[next])
    }

    // MARK: - The two menus the top bar opens

            // MARK: - Identity, counters

    private var scoreTitle: String {
        guard let score = state.selectedScore else { return "No arrangement" }
        // Never the slug. Scores imported before the engine learned to refuse
        // a file name as a title still carry one, and rewriting someone's
        // names underneath them is not the fix -- so the view says what it
        // does know instead (L18).
        let piece = state.manifest?.pieces?.first { $0.arrangements.contains(score.slug) }
        return ScoreTitle.display(title: score.title, name: score.name,
                                  slug: score.slug, pieceName: piece?.name,
                                  parts: (state.displayedVersion?.parts ?? []).map(\.name))
    }

    /// Where the reader came from, for the bar's way out [C6]: the set list
    /// being played, else the arrangement's piece, else the library itself.
    private var scoreOrigin: String {
        if let slug = state.currentSetlist,
           let setlist = state.manifest?.setlists?.first(where: { $0.slug == slug }) {
            return setlist.name
        }
        if let score = state.selectedScore,
           let piece = state.placement(of: score.slug)?.piece {
            return piece.name
        }
        return "Library"
    }

    private var scoreSubtitle: String {
        guard let score = state.selectedScore else { return "" }
        let piece = state.manifest?.pieces?.first { $0.arrangements.contains(score.slug) }
        return [piece?.name, state.displayedVersionLabel]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private var pageCounter: String {
        ScorePosition.pageLabel(visible: state.visiblePageIndices,
                                total: state.showingFirstPagesOnly
                                    ? state.firstPagesTotal
                                    : state.pdfDocument?.pageCount ?? 0)
    }

    /// The bar on screen, from the geometry the selection layer already builds.
    ///
    /// The visible RECT, not the visible page: reporting every measure on the
    /// page meant the readout said "bar 1" while the reader was zoomed into
    /// bar 30. Falls back to the whole page where no rect has been reported
    /// yet -- the first frame, and the remote-engine path, which builds no
    /// geometry at all and correctly shows nothing.
    private var barCounter: Int? {
        guard let geometry = state.geometry else { return nil }
        let pages: [(visible: CGRect, bars: [BarPosition.Bar])] =
            state.visiblePageIndices.compactMap { index in
                guard let page = geometry.page(index) else { return nil }
                let bars = BarPosition.bars(onPage: page)
                let rect = state.visibleBarRects[index]
                    ?? CGRect(origin: .zero, size: page.size)
                return (rect, bars)
            }
        return BarPosition.first(inPages: pages)
    }

    // The score view's dialogs are gone (NAV_MODAL_FREE_0.4.2 §2). Details
    // and Settings are pushed screens now, reached through the "…" screen; the
    // set-list pickers and the alerts belonged to the legacy overlay, which
    // went with it. Nothing floats over the score any more except the docked
    // chrome -- chat, ink bar, strip, transport -- which blocks nothing and
    // needs no dismissing.

    // MARK: - Canvas

    /// The score, inset so it stays centred in whatever gap the overlays leave.
    /// The inset animates; the page itself does not resize unless both overlays
    /// are open (§5).
    @ViewBuilder
    private var canvasLayer: some View {
        HStack(spacing: 0) {
            // The thumbnail rail (§7.11), in paged reading on an iPad.
            if railShown, let document = state.pdfDocument {
                ThumbnailRail(document: document,
                              current: state.visiblePageIndices,
                              spread: state.twoPageSpread,
                              onJump: jumpToPage)
            }
            // reserve exactly the panels' widths, so what remains IS the canvas
            Group {
                if let score = state.selectedScore {
                    // No width cap. The spec pins the page at 520 (436 with both
                    // panels open), but those came from a 1180pt mockup; capping
                    // an iPad's 1032pt canvas to 544 left dead bands either side
                    // and made the scroll view itself too narrow, so zoom hit
                    // hard limits well inside the screen. The score gets the
                    // whole gap and ScorePagesView sizes the page from it.
                    scorePane(score)
                } else {
                    emptyState
                }
            }
            .frame(maxWidth: .infinity)
            // The panel's lane (§7.2): the score lays itself out again at
            // the narrower width while Versions, Chat or More is open.
            Color.clear.frame(width: isCompact || !panelOpen
                              ? 0 : Theme.Metric.panelWidth + Theme.Metric.pagePanelGap)
        }
        .animation(Theme.Motion.overlay(reduced: reduceMotion), value: panelOpen)
        // a finished lasso opens chat: the selection has to be visibly received,
        // not silently held
        .onChange(of: state.chatOpenRequest) { _, _ in setPanel(.chat) }
    }

    @ViewBuilder
    private func scorePane(_ score: ScoreDoc) -> some View {
        if let doc = state.pdfDocument, let vid = state.displayedVersionID {
            // ONE CANVAS, EVERY SIZE CLASS (IPHONE_0.6.14 §0, §10.4 step 1).
            //
            // Compact width used to get `ScoreZoomView`: 36 lines of PDFView
            // with `autoScales`. Everything the score view IS lived on the
            // other branch -- Pencil markup, the lasso, selection, the
            // playhead, the thumbnail rail -- and the phone had none of it,
            // with a zoom ceiling of 5 rather than the 12 a notehead needs.
            //
            // It is not that the phone had a worse canvas; it had a different
            // one, so every feature built on the real canvas simply did not
            // exist there and no test could tell. Nothing else in 0.6.14 is
            // testable until this branch goes.
            //
            // The engine is handed in rather than reached through AppState:
            // AppState publishes nothing when the play head moves, so a canvas
            // that read it that way would never follow. Same reason the ink
            // bar observes its controller directly.
            // Markup on a shared set list entry is filed under the ENTRY, not
            // under this device's copy of the arrangement: the entry id is
            // the same string on every device, and keeping the two apart is
            // what stops my own private notes on my own copy being published
            // to the band (`SharedEntryCopies.inkNamespace`).
            let namespace = state.openSharedEntry
                .map { SharedEntryCopies.inkNamespace(entryId: $0.entry) }
                ?? score.inkNamespace
            ScorePagesView(document: doc, annotationKey: "\(namespace)/\(vid)",
                           sharedInk: bandInk,
                           canvasIdentity: "\(score.slug)/\(vid)",
                           mode: state.scoreMode, playback: state.playback)
        } else if score.versions.isEmpty {
            // An arrangement with no versions has no version to display, so
            // renderIfNeeded returns at its guard and nothing is ever in
            // flight. Saying so beats a spinner that can never finish.
            StateView(systemImage: "questionmark.square.dashed",
                      title: "Nothing to show",
                      message: "This arrangement has no versions — nothing was ever "
                             + "written to it. That usually means an import stopped "
                             + "part way. You can delete it and import the score again.",
                      actionTitle: "Delete this arrangement",
                      // and step back out: what is on screen no longer exists,
                      // and the undo bar lives in the library behind this
                      action: {
                          state.deleteScore(slug: score.slug)
                          onClose()
                      })
        } else if state.loadingPDF {
            StateView(systemImage: "music.note.list", title: "Engraving…",
                      message: "Verovio is setting the page.")
        } else if let err = state.lastError {
            // The build is ON the failure, not only in Settings. A screenshot of
            // this screen is how a reader reports it, and without the build
            // stamp nobody can tell which version they are looking at -- an
            // afternoon went into establishing that from timestamps alone.
            StateView(systemImage: "exclamationmark.triangle",
                      title: "Render failed", message: "The engine could not draw this version.",
                      mono: "\(err)\n\(Self.buildStamp)")
        } else {
            StateView(systemImage: "music.note", title: "Opening…")
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if !state.libraryLoaded {
            // Still looking. Nothing here is known yet -- not whether there are
            // scores, and not whether the engine is reachable -- so neither
            // message below can be told the truth, and both were shown for a
            // moment at every launch.
            StateView(systemImage: "music.note.list",
                      title: "Opening your library…",
                      message: "")
                .accessibilityIdentifier("library-loading")
        } else if !state.engineOK && !state.useLocalEngine {
            StateView(systemImage: "bolt.horizontal.circle",
                      title: "Engine unreachable",
                      message: "Check the URL in Settings and that the engine is running on your Mac.",
                      mono: state.engineURLString,
                      actionTitle: "Settings") { showSettings = true }
        } else {
            StateView(systemImage: "music.quarternote.3",
                      title: "No arrangement open",
                      message: "Open the library to pick an arrangement, or import a score.",
                      actionTitle: "Open library") {
            }
        }
    }

    /// Put the convert offer on screen when a scan opens (SC13).
    ///
    /// Only over an empty panel: a reader who opened Chat or More before the
    /// page finished engraving asked for that, and having the offer displace
    /// it would be the app taking the screen back. They still reach it from
    /// More's row, which is the whole reason that row stayed.
    private func offerConversionIfScan() {
        guard scoreScreen == nil, state.scoreMode != .performance else { return }
        guard ConvertOffer.opens(artifact: state.displayedArtifact,
                                 slug: state.selectedScore?.slug ?? "",
                                 answered: state.convertOfferAnswered,
                                 status: state.omrHere) else { return }
        setPanel(.convert(fromMore: false))
    }

    private func titleMenuChanged(open: Bool) {
        let wanted: ScoreScreen
        switch titleMenuMode {
        case .versions:     wanted = .titleVersions
        case .arrangements: wanted = .titleArrangements
        case .setlists:     wanted = .titleSetlists
        }
        withAnimation(Theme.Motion.overlay(reduced: reduceMotion)) {
            if open {
                optionsSection = nil
                scoreScreen = wanted
            } else if scoreScreen == .titleVersions || scoreScreen == .titleArrangements
                        || scoreScreen == .titleSetlists {
                scoreScreen = nil
            }
        }
    }

    // MARK: - Overlays

    @ViewBuilder
    private var overlayLayer: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                if let screen = scoreScreen {
                    scoreScreenView(screen)
                        .environment(\.inPanel, true)
                        .environment(\.panelBack, panelBack(for: screen))
                        .environment(\.panelDone, { closePanel() })
                        .frame(maxWidth: isCompact ? .infinity : Theme.Metric.panelWidth)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .pageShape()
                        .padding(.trailing, isCompact ? 0 : Theme.Metric.s8)
                        .padding(.top, isCompact ? 0 : Theme.Metric.s8)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("score-panel")
                        .id(screen)
                        .transition(panelTransition(.trailing))
                }
            }
            // the screen ignores the keyboard so the page keeps its size; the
            // panel with the field in it takes the inset back (#59)
            .padding(.bottom,
                     KeyboardInset.panelBottom(keyboard: keyboard.height,
                                               safeAreaBottom: geo.safeAreaInsets.bottom))
            .animation(Theme.Motion.overlay(reduced: reduceMotion), value: scoreScreen)
            .animation(Theme.Motion.overlay(reduced: reduceMotion), value: keyboard.height)
        }
    }

    /// Reduce Motion swaps the slide for a cross-fade (§5, §9).
    private func panelTransition(_ edge: OverlayEdge) -> AnyTransition {
        if reduceMotion { return .opacity }
        return .move(edge: edge == .leading ? .leading : .trailing)
    }

    @ViewBuilder
    private var chatPanel: some View {
        VStack(spacing: 0) {
            PanelHeader(title: state.selectedScore?.name ?? "Chat",
                        subtitle: state.selectedScore.flatMap { state.placement(of: $0.slug)?.piece.name },
                        doneLabel: "Close chat") {
                if let catalog = state.modelCatalog {
                    // The model, named in the header (SC5); changed in Settings
                    // or here, as a panel state.
                    Button { setPanel(.chatModel) } label: {
                        Text(state.chatModel.isEmpty ? (catalog.default) : state.chatModel)
                            .typeRole(.data)
                            .foregroundStyle(Theme.Ink.ink2)
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.vertical, Theme.Metric.s4)
                            .padding(.horizontal, Theme.Metric.s6)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("chat-model")
                    .accessibilityLabel("Chat model")
                }
            }
            ChatView()
        }
    }

    // The legacy library overlay lived here: piece and set-list sections,
    // drag-to-file rows and three context menus. It is gone (0.4.1 §1).
    // Browsing is the Library tab, filing is Edit mode's Move-to-piece,
    // and reordering is the arrangement sheet -- so nothing was left that
    // only the overlay could do. The score screen now has exactly one
    // chrome: top bar, thumbnail strip, transport.

    // MARK: - Pill

    /// Wrapped in a child view so the annotation controller can be observed:
    /// the pill shows markup state and the live ink colour.

    @ViewBuilder
    private var versionMenuItems: some View {
        if let score = state.selectedScore {
            ForEach(state.versionGroups(for: score)) { group in
                Button {
                    state.pinnedVersion = (group.face.id == score.latest) ? nil : group.face.id
                    Task { await state.renderIfNeeded() }
                } label: {
                    if group.face.id == state.displayedVersionID {
                        Label("\(group.face.name) · \(shortTitle(group.title))",
                              systemImage: "checkmark")
                    } else {
                        Text("\(group.face.name) · \(shortTitle(group.title))")
                    }
                }
            }
        }
    }

    // `optionsMenuItems` lived here: the "…" popover's rows, including the
    // last stock iOS Toggle in the app. The popover became a pushed screen in
    // the modal-free revision and nothing has rendered these since -- so this
    // is dead code that a control audit keeps finding (L33).

    private func shortTitle(_ title: String) -> String {
        title.count > 40 ? title.prefix(40).trimmingCharacters(in: .whitespaces) + "…" : title
    }

    // MARK: - Navigation

    private func openScore(_ slug: String, version: String? = nil) {
        state.select(slug: slug, version: version)
        // one pane at a time on iPhone: opening a score reveals it
        if isCompact {
        }
    }
}
/// A row inside a piece is a drop target: what lands on it takes its place in
/// the running order and everything below shifts down, which is the #N
/// renumbering the user sees. A row in Unfiled has no order to join, so it
/// accepts nothing.
private extension View {
}

/// Observes the shared annotation controller so the pill reflects markup state
/// and carries the live ink colour.
// The pill is gone from the score view: the top bar carries its duties
// (NAVIGATION_SYSTEM.md §8), and with the legacy overlay removed there is
// nothing left for its library button to open.


/// When the transport prepares the version's sound: once per version, and
/// only when the arrangement's pages are on screen.
private struct PlaybackPreparation: Equatable {
    let version: String?
    let pagesShown: Bool
}

/// The page and bar counters, wired to the transport's own clock.
///
/// It OBSERVES the engine, and that is the whole reason it exists rather than
/// `PositionCounters` being called with a boolean: the bar chip appears with
/// the play head and goes when it stops, and `AppState` publishes nothing when
/// the engine's state changes. Read through `AppState` the chip would appear
/// only when something else happened to redraw the score screen -- the same
/// fault the transport row and the ink bar each had to be fixed for.
///
/// `BarPosition.counter` is the rule, and it is tested there: bar while
/// playing, nothing while reading. The page counter is not playback's business
/// and passes straight through.
private struct LiveCounters: View {
    @ObservedObject var playback: PlaybackEngine
    let pages: String?
    let bar: Int?
    /// Test-only, under `-geometryProbe`: the per-page system count.
    let probe: String?

    var body: some View {
        PositionCounters(pages: pages,
                         bar: BarPosition.counter(bar: bar,
                                                  isPlaying: playback.isPlaying),
                         probe: probe)
    }
}
