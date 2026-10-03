import SwiftUI

/// The score view's own pushed screens (NAV_MODAL_FREE_0.4.2 §7).
///
/// The score view is a full-screen place with ✕, not a modal, so it stays --
/// but its two floating panels do not. The `…` popover becomes this screen, and
/// back returns to the score with its page and zoom intact, because the score
/// was never torn down: it is simply covered.
enum ScoreScreen: Hashable {
    case options
    case optionsSection(String)
    case details
    // 0.8: the score's panel (§7.2) shows these too -- Chat, and what the
    // title block opens (SC4): Versions and the piece's other arrangements,
    // and the + button's set lists (SC11).
    case chat
    case titleVersions
    case titleArrangements
    case titleSetlists
    /// The set list checklist -- the SAME screen the pieces list pushes
    /// (Route.setlistsFor), rendered here because the score's stack is keyed by
    /// this enum and not by Route (§16). One behaviour, two entrances.
    case setlists
    case settings
    case chatModel
    /// The OMR offer, and while it runs the report (SC13, `ConvertOffer`).
    ///
    /// `fromMore` is whether More opened it: the scan itself opens it with
    /// nothing behind it, so a ‹ there would go nowhere, and More's row opens
    /// the same state with ‹ back to More.
    case convert(fromMore: Bool)
}

struct ScoreOptionsScreen: View {
    @EnvironmentObject var state: AppState
    @Binding var mode: ScoreMode
    /// What the top bar seats at its current width (0.6.8).
    ///
    /// Performance mode and Show transport are BAR controls now -- the two
    /// screens they used to be from the music. This screen keeps them at
    /// exactly the widths the bar cannot seat them, which is a phone, and
    /// shows neither anywhere else.
    ///
    /// Read from `ContentView`'s one measurement rather than measured again
    /// here: two notions of what fits would put a switch in both places at some
    /// width and in neither at another.
    var barFit: ScoreBarLayout.Fit = ScoreBarLayout.Fit(showsVersions: true,
                                                        layoutCells: 3)
    var section: String?
    var onBack: () -> Void
    var push: (String) -> Void
    var onSettings: () -> Void
    var onDetails: () -> Void
    /// Push the set list checklist -- the pieces list's own SetlistsForScreen,
    /// which is what makes this a second entrance rather than a second screen
    /// (§16). Takes the route `onDetails` and `onSettings` take.
    var onSetlists: () -> Void = {}
    /// Open the convert offer's panel state (SC13), with ‹ back to here.
    var onConvert: () -> Void = {}

    /// The format currently being written, so its row can say so: engraving a
    /// PDF of a long score takes a moment and a dead row reads as a dead app.
    @State private var exporting: ScoreExport.Format?
    @State private var bundling = false
    /// The finished file, handed to Apple's share sheet.
    ///
    /// This is the ONE modal in the app, and it is deliberate: the system share
    /// sheet is how iOS puts a file into Files, Mail or another program, and
    /// re-implementing it would be both worse and impossible.
    @State private var sharing: URL?
    var body: some View {
        Group {
            if let section {
                Screen(title: section, backLabel: "More", onBack: onBack) {
                    sectionBody(section)
                }
            } else {
                Screen(title: "More", backLabel: "Score", onBack: onBack) {
                    root
                }
            }
        }
        // Apple's own sheet, and the only one in the app: it is how iOS puts a
        // file into Files, Mail or another program.
        .sheet(item: $sharing) { url in
            SystemShareSheet(url: url)
        }
    }

    private var root: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Performance mode moved to the TOP BAR (0.6.8): it is the one
            // control that changes what every input on the music means, and it
            // sat two screens away from that music. It stays here at the widths
            // the bar cannot seat it -- a phone -- because an access path is
            // not removed until its replacement exists at that width, and on a
            // phone it does not (ScoreBarLayout).
            //
            // The app's own switch, not the system's. This was the one stock
            // iOS control left anywhere in it (L33).
            // Print, where the bar has no room for it (ScoreBarLayout), and
            // only on the pages: the strip cannot be printed.
            if barFit.optionsCarriesPrint, ScorePrinting.available(in: state.layoutChoice),
               state.pdfDocument != nil {
                ScreenRow(title: "Print", leads: false, identifier: "more-print") {
                    onBack()
                    ScorePrinting.present(state.pdfDocument,
                                          title: state.selectedScore?.name ?? "Score")
                }
            }

            if barFit.optionsCarriesPerformanceToggle {
                PanelToggle(title: "Performance mode",
                            isOn: Binding(get: { mode == .performance },
                                          set: { on in
                                              mode = on ? .performance : .read
                                              if on { state.annotation.isOn = false }
                                              onBack()
                                          }))
                    .accessibilityIdentifier("more-performance")
                    .padding(.horizontal, Theme.Metric.s20)
                    .padding(.vertical, 11)
                    .background(Theme.Accent.clayTint)
                    .overlay(alignment: .bottom) {
                        Theme.Rule()
                    }
            }

            // Only for a scan, and only while it IS one: once OMR has run, the
            // arrangement has a notation version and the row has nothing left
            // to offer. A row that stays and does nothing is worse than a row
            // that goes.
            // A PDF or a picture (0.8.0 build 194, Ali's item 6: the gate
            // said PDF only since 0.5.0, and 0.6.13's image path never
            // reached it).
            // 0.8.2: a ROW that opens the offer's own panel state, not the
            // switch that used to perform here (SC13). The question, its cost
            // and the draft caution belong on one surface the scan opens by
            // itself; what More owes is a way back to it.
            if ScoreArtifact.canBeMadeEditable(state.displayedArtifact) {
                ScreenRow(title: ConvertOffer.convert,
                          value: ConvertOffer.rowValue(status: state.omrHere),
                          identifier: "more-make-editable") { onConvert() }
                note(ScoreArtifact.makeEditableNote(state.displayedArtifact))
            }
            // "Score display" is gone (0.6.3 #6). It held page/spread/
            // continuous -- which are three buttons at the TOP of the score,
            // where a reader can see what they are looking at -- and the
            // transport switch, which is now beside them. What was left behind
            // it was chord symbols, so chord symbols come up a level rather
            // than sitting two screens deep (#7).
            //
            // The transport switch is a BAR control (0.6.3 #6), and since 0.6.8
            // it is here ONLY where the bar has yielded it -- the same rule
            // Performance mode follows above. It was in both places at every
            // width, which is one switch too many on an iPad and the reason the
            // bar's copy read as a duplicate rather than as the control.
            ScreenRow(title: "Chord symbols", value: "\(state.chordDefaultSize) pt",
                      identifier: "more-chords") { push("Chord symbols") }
            // Every row states its current answer where it has one. A screen of
            // bare labels is a menu; the answers are what make it a summary of
            // where the score stands (L34).
            ScreenRow(title: "Annotations",
                      value: state.annotation.isOn ? "on" : "off",
                      identifier: "more-annotations") {
                push("Annotations")
            }
            ScreenRow(title: "Select",
                      value: state.activeSelection.map {
                          "\($0.addresses.count) selected"
                      } ?? "nothing selected",
                      identifier: "more-selection") {
                push("Select")
            }
            ScreenRow(title: "Transpose", value: "by interval",
                      identifier: "more-transpose") { push("Transpose") }
            // "Versions" is gone from here (0.6.3 #8). The versions dropdown
            // at the top of the score is the way in, and it now shows versions
            // and NOTHING ELSE -- which is what made a second list necessary.
            // The section body below is kept: "All N versions" in the dropdown
            // still pushes it.
            ScreenRow(title: "Details",
                      value: state.selectedScore.flatMap { score in
                          state.placement(of: score.slug)?.piece.name
                      },
                      identifier: "more-details") {
                onDetails()
            }
            // Set lists (§16, Ali). The "+" on the bar opens the same
            // membership -- and is the FIRST control the bar yields as it
            // narrows, so on a phone it is never there at all
            // (ScoreBarLayoutTests has asserted exactly that since the day it
            // was made to yield). The reasoning then was written down: "the
            // library's set list picker still offers the same operation, so
            // this costs a shortcut rather than a feature." True about the
            // operation, wrong about the reader -- someone deciding what goes
            // in a set is looking at the music while they decide.
            //
            // It PUSHES the pieces list's own screen, and that is the ruling:
            // not a popover (the app has none, and this is not the place to
            // introduce one), not a band, and not a second copy of the
            // checklist. Both entrances land on SetlistsForScreen, so the
            // membership, the wording and the way out are one thing.
            //
            // Grouped with details and filing, above Share & export: these
            // three rows are about where this arrangement SITS and who it
            // belongs to, and the two below are about the app.
            ScreenRow(title: "Set lists",
                      value: state.selectedScore.map { score in
                          SetlistMembership.rowValue(
                              for: score.slug, in: state.manifest?.setlists ?? [])
                      },
                      identifier: "more-setlists") {
                onSetlists()
            }
            ScreenRow(title: "Export", value: "MusicXML · MIDI · PDF",
                      identifier: "more-export") {
                push("Export")
            }
            ScreenRow(title: "Settings",
                      value: state.useLocalEngine ? "on-device" : "remote",
                      identifier: "more-settings") { onSettings() }
        }
        .padding(.bottom, Theme.Metric.s32)
    }

    /// The part-wide half of size and position: the default every chord symbol
    /// in the part inherits, and the way back out of every override.
    ///
    /// Per-element values are absolute points in the notation, so they survive
    /// this default changing -- which is the point of storing them that way.
    @ViewBuilder
    private var chordSymbolRows: some View {
        HStack(spacing: Theme.Metric.s8) {
            Text("Default size").typeRole(.row).foregroundStyle(Theme.Ink.ink)
            Spacer(minLength: Theme.Metric.s8)
            Button {
                state.stepChordDefault(.smaller)
            } label: {
                Image(systemName: "textformat.size.smaller")
                    .frame(width: 34, height: 32).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!state.canStepChordDefault(.smaller))
            .opacity(state.canStepChordDefault(.smaller) ? 1 : 0.42)
            .accessibilityLabel("Smaller default chord size")
            .accessibilityIdentifier("chords-smaller")

            Text("\(state.chordDefaultSize) pt")
                .typeRole(.data).foregroundStyle(Theme.Ink.ink)
                .frame(minWidth: 44)
                .accessibilityIdentifier("chords-size")

            Button {
                state.stepChordDefault(.bigger)
            } label: {
                Image(systemName: "textformat.size.larger")
                    .frame(width: 34, height: 32).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!state.canStepChordDefault(.bigger))
            .opacity(state.canStepChordDefault(.bigger) ? 1 : 0.42)
            .accessibilityLabel("Bigger default chord size")
            .accessibilityIdentifier("chords-bigger")
        }
        .padding(.horizontal, Theme.Metric.s20)
        .padding(.vertical, Theme.Metric.s12)

        // The LADDER, tappable. The stepper above it was reported as a
        // control that controls nothing -- two SF Symbol glyphs and a number,
        // where the number was the obvious thing to press and was not a
        // button at all. Every rung is a button now, so "18" can be reached by
        // tapping 18. The stepper stays: it is the path for anyone stepping
        // one rung at a time, and an access path is not removed in the build
        // that adds its replacement.
        sizeLadder

        note("New chord symbols inherit this. A symbol you have nudged or "
             + "resized keeps its own size until you reset it.")

        // WHICH part it lands on. A part-wide op that names no part is
        // indistinguishable from one that never ran, which is exactly how
        // this control came to be reported as dead.
        if let part = state.chordPartName() {
            ScreenRow(title: "Applies to", value: part, leads: false,
                      identifier: "chords-part") {}
                .disabled(true)
        } else {
            note("No arrangement is open, so there is nothing to resize.")
        }

        // "Reset all adjustments" was here and is gone (0.6.3 #7): a
        // destructive part-wide op on a screen whose other control is a size
        // stepper. Per-element reset is unaffected -- it lives on the element's
        // own adjust bar, where the thing being reset is on screen.
    }

    /// Every size a chord symbol can take, as buttons.
    private var sizeLadder: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Metric.s6) {
            ForEach(ChordAdjustSession.sizeLadder, id: \.self) { size in
                let selected = size == state.chordDefaultSize
                Button {
                    state.setChordDefault(size)
                } label: {
                    Text("\(size)")
                        .typeRole(.data)
                        .foregroundStyle(selected ? Theme.Accent.clayStrong : Theme.Ink.ink2)
                        .frame(minWidth: 40, minHeight: 34)
                        .background(selected ? Theme.Accent.clayTint : Theme.Surface.panel)
                        .overlay {
                            RoundedRectangle(cornerRadius: Theme.Metric.rCtl)
                                .stroke(selected ? Theme.Accent.clay : Color.clear, lineWidth: 1.5)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Metric.rCtl))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(size) point")
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : [.isButton])
                .accessibilityIdentifier("chords-size-\(size)")
            }
            }
            .padding(.horizontal, Theme.Metric.s20)
        }
        .padding(.bottom, Theme.Metric.s12)
    }

    /// One row per format, each saying what it is FOR rather than what it is:
    /// "Open in another notation program" beats "MusicXML" for anyone who does
    /// not already know what MusicXML is.
    @ViewBuilder
    private var exportRows: some View {
        ForEach(ScoreExport.Format.allCases, id: \.rawValue) { format in
            ScreenRow(title: format.label,
                      value: exporting == format ? "preparing…" : format.detail,
                      leads: false,
                      identifier: "export-\(format.rawValue)") {
                guard exporting == nil, let score = state.selectedScore else { return }
                exporting = format
                Task {
                    let pinned = state.pinnedVersion
                    sharing = await state.exportFile(slug: score.slug,
                                                     version: pinned,
                                                     format: format)
                    exporting = nil
                }
            }
            .disabled(exporting != nil)
        }
        note("The file is named for the arrangement, and carries the version "
             + "number only when you are looking at an older one.")

        // Sharing with a person rather than with a program. The formats above
        // hand the music to other software; this hands the ARRANGEMENT to
        // another Scoranger -- the chart, and your markup on it -- with no
        // account and no network (design/FIREBASE.md §13).
        ScreenRow(title: "Send to another iPad",
                  value: bundling ? "packing…" : "AirDrop, Files, Mail",
                  leads: false,
                  identifier: "export-bundle") {
            guard !bundling, let score = state.selectedScore else { return }
            bundling = true
            Task {
                sharing = await state.exportBundle(target: score.slug)
                bundling = false
            }
        }
        .disabled(bundling)
        note("Carries this arrangement and your pencil marks as one file. "
             + "Whoever opens it is asked before anything joins their library.")
    }

    @ViewBuilder
    private func sectionBody(_ section: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            switch section {
            // "Score display" lived here (0.6.3 #6). Page / spread /
            // continuous are three buttons at the top of the score and the
            // transport switch is beside them; a second surface for the same
            // two properties is how the impossible state got in last time.
            case "Annotations":
                ScreenRow(title: "Clear markup on this version", leads: false,
                          isDestructive: true, identifier: "annotations-clear") {
                    if let score = state.selectedScore, let vid = state.displayedVersionID {
                        DrawingStore.shared.clear(prefix: "\(score.inkNamespace)/\(vid)")
                        Task { await state.renderIfNeeded(force: true) }
                    }
                    onBack()
                }
                note("Ink belongs to the version it was drawn on.")
            case "Select":
                ScreenRow(title: "Clear selection", leads: false,
                          identifier: "selection-clear") { state.clearSelection(); onBack() }
                // The mode used to be named here -- "Pencil: select" -- and
                // that label is what Ali asked off every screen. The guidance
                // under it is the part worth keeping.
                note("Hold a finger down while drawing to add to the "
                     + "selection; tap an element to drop it.")
            case "Transpose":
                ScreenRow(title: "Up a semitone", leads: false,
                          identifier: "transpose-up") { state.transpose(semitones: 1); onBack() }
                ScreenRow(title: "Down a semitone", leads: false,
                          identifier: "transpose-down") { state.transpose(semitones: -1); onBack() }
                note("Transposes the whole arrangement. To move only some notes, "
                     + "select them and ask in chat.")
            case "Versions":
                if let score = state.selectedScore {
                    ForEach(score.versions.reversed(), id: \.id) { version in
                        ScreenRow(title: version.name,
                                  value: VersionLabel.text(op: version.op,
                                                           prompt: version.turn?.prompt),
                                  leads: false,
                                  identifier: "version-\(version.name)") {
                            state.pinnedVersion = version.id == score.latest ? nil : version.id
                            Task { await state.renderIfNeeded() }
                            onBack()
                        }
                    }
                }
            case "Chord symbols":
                chordSymbolRows
            case "Export":
                exportRows
            default:
                EmptyView()
            }
        }
        .padding(.bottom, Theme.Metric.s32)
    }

    private func note(_ text: String) -> some View {
        Text(text).typeRole(.meta).foregroundStyle(Theme.Ink.ink3)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Theme.Metric.s20)
            .padding(.vertical, Theme.Metric.s8)
    }
}

/// The title switcher (§7.1): an inline band below the top bar.
///
/// It pushes the score down rather than floating over it, and the paged canvas
/// simply fits into less height -- which is the one real advantage of paging
/// here, since there is no scroll offset to preserve.
struct TitleSwitcherBand: View {
    @EnvironmentObject var state: AppState
    let score: ScoreDoc
    /// Which list this is. The band shows ONE, chosen by the control that
    /// opened it -- the versions dropdown was showing a column of other
    /// pieces beside the versions it was asked for (0.6.3 #8).
    var mode: TitleBandLayout.Mode
    var onPickArrangement: (String) -> Void
    var onPickVersion: (String?) -> Void
    var onAllVersions: () -> Void
    var available: CGFloat = 0
    /// 0.8: drawn inside the score's panel rather than as a band under the
    /// bar (SC4) -- the column at its own height, under the panel's header.
    var inPanel = false
    var onDone: () -> Void = {}

    private var piece: PieceDoc? {
        state.manifest?.pieces?.first { $0.arrangements.contains(score.slug) }
    }

    /// EVERY version, newest first. It was the last four, with the rest behind
    /// an "All N versions" row that pushed a screen -- which is the loop a
    /// reader hit when the version they wanted was the fifth one back. The band
    /// scrolls (TitleBandLayout), so a long history costs height it already
    /// knows how to cap.
    private var shownVersions: [VersionDoc] { Array(score.versions.reversed()) }
    /// The grouped history is still one row away: it shows what PROMPT made a
    /// run of versions, which this flat list cannot.
    private var hasAllVersionsRow: Bool { score.versions.count > 4 }

    private var arrangements: [String] { piece?.arrangements ?? [score.slug] }

    /// The same labels the piece screen shows, by the same rule: a title that
    /// is really the workspace's file name loses to the arrangement's own
    /// name, and no two rows may read the same.
    private var arrangementLabels: [String: String] {
        let scores = arrangements.compactMap { slug in
            state.manifest?.scores.first { $0.slug == slug }
        }
        let shown = ScoreTitle.labels(for: scores.map {
            ScoreTitle.Arrangement(title: $0.title, name: $0.name, slug: $0.slug,
                                   parts: ($0.versions.last?.parts ?? []).map(\.name),
                                   isScan: ArtifactTag.holding(of: $0) == .pdf)
        })
        return Dictionary(uniqueKeysWithValues: zip(scores.map(\.slug), shown))
    }

    private var setlistCount: Int { state.manifest?.setlists?.count ?? 0 }

    /// One row count per mode, and read from the mode rather than defaulted.
    ///
    /// It was `mode == .versions ? versions : arrangements`, so a third mode
    /// would silently have been sized by the arrangement count -- a band with
    /// eight set lists and two arrangements opening two rows tall, its
    /// checklist scrolled out of sight.
    private var contentHeight: CGFloat {
        let rows: Int
        switch mode {
        case .versions:     rows = shownVersions.count
        case .arrangements: rows = arrangements.count
        case .setlists:     rows = setlistCount
        }
        return TitleBandLayout.contentHeight(mode: mode, rows: rows,
                                             hasAllVersionsRow: hasAllVersionsRow)
    }

    var body: some View {
        if inPanel {
            Screen(title: panelTitle, backLabel: "Back",
                   subtitle: ScoreTitle.arrangementName(title: score.title, name: score.name,
                                                        slug: score.slug),
                   onBack: onDone) {
                column.padding(.vertical, Theme.Metric.s8)
            }
        } else {
            band
        }
    }

    private var panelTitle: String {
        switch mode {
        case .versions:     return "Versions"
        case .arrangements: return "Arrangements"
        case .setlists:     return "Set lists"
        }
    }

    private var band: some View {
        ScrollView {
            column
        }
        .frame(height: TitleBandLayout.height(content: contentHeight,
                                              available: available))
        .scrollDisabled(!TitleBandLayout.scrolls(content: contentHeight,
                                                 available: available))
        .background(Theme.Surface.panel)
        .overlay(alignment: .bottom) { Theme.Rule() }
        // NO identifier on this container. An identifier on a stack is taken by
        // its children: the two columns became two buttons both called
        // "title-switcher" and every row inside them -- the arrangements, the
        // versions -- stopped existing. The band was open and unusable, and the
        // only way to switch version while reading went with it.
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var column: some View {
        switch mode {
        case .arrangements: arrangementColumn
        case .versions:     versionColumn
        case .setlists:     setlistColumn
        }
    }

    private var arrangementColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelLabel(text: piece.map { "Arrangements of \($0.name)" } ?? "Arrangements", ruled: false)
            ForEach(Array(arrangements.enumerated()), id: \.offset) { index, slug in
                if let arrangement = state.manifest?.scores.first(where: { $0.slug == slug }) {
                    switchRow(title: arrangementLabels[slug]
                                     ?? ScoreTitle.arrangementName(
                                            title: arrangement.title,
                                            name: arrangement.name,
                                            slug: arrangement.slug),
                              number: index + 1,
                              selected: slug == score.slug,
                              id: "menu-arrangement-\(slug)") { onPickArrangement(slug) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var versionColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelLabel(text: "Versions", ruled: false)
            ForEach(shownVersions, id: \.id) { version in
                // What MADE the version, not just its id: "v003 / v002 /
                // v001" told a reader nothing, so switching version while
                // reading was a guess.
                switchRow(title: TitleBandLayout.versionLabel(
                                    prompt: version.turn?.prompt, op: version.op),
                          number: nil,
                          detail: version.name,
                          selected: version.id == state.displayedVersionID,
                          id: "menu-version-\(version.name)") {
                    onPickVersion(version.id == score.latest ? nil : version.id)
                }
            }
            if hasAllVersionsRow {
                ScreenRow(title: "All \(score.versions.count) versions",
                          identifier: "menu-all-versions", action: onAllVersions)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Which set lists this arrangement is in, one box each (0.6.11 #1).
    ///
    /// The rows come from `SetlistMembership`, which is where the two
    /// decisions live: the order is by NAME and never by membership, so a box
    /// checked under the finger does not move the row out from under the next
    /// tap; and a tap resolves to `.add` or `.remove` read off the row rather
    /// than a Bool a caller has to interpret.
    ///
    /// The band STAYS OPEN on a tap, like the sound picker and unlike the
    /// arrangement and version rows -- those switch what you are looking at
    /// and have nothing more to say, while this is a checklist and a reader
    /// putting one arrangement in three set lists should not reopen it twice.
    private var setlistColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelLabel(text: "Set lists", ruled: false)
            let rows = SetlistMembership.rows(for: score.slug,
                                              in: state.manifest?.setlists ?? [])
            if rows.isEmpty {
                // Not an empty band: a line saying where set lists come from.
                // The library makes them; this only files an arrangement into
                // one that exists, and a blank panel would read as broken.
                PanelNote(text: "No set lists yet. Make one in the library, "
                          + "then this arrangement can go in it.")
                    .padding(.horizontal, Theme.Metric.s16)
                    .padding(.vertical, 8)
            }
            ForEach(rows) { row in
                setlistRow(row)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One set list, with its box.
    ///
    /// The count is shown as the row's `detail` rather than in the title, so
    /// the names line up and a reader scanning for "Friday night" is not
    /// reading past a number to find it.
    private func setlistRow(_ row: SetlistMembership.Row) -> some View {
        Button {
            switch SetlistMembership.tap(row) {
            case .add(let setlist):
                Task { await state.addToSetlist(setlist: setlist, score: score.slug) }
            case .remove(let setlist):
                Task { await state.removeFromSetlist(setlist: setlist,
                                                     score: score.slug) }
            }
        } label: {
            HStack(spacing: Theme.Metric.s8) {
                // A box, not a checkmark on the trailing edge: this row is a
                // CHECKLIST entry that toggles, and the version rows' trailing
                // tick means "this is the one you are looking at". Two
                // different meanings should not share one mark.
                Image(systemName: row.isMember ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(row.isMember ? Theme.Accent.clayStrong
                                                  : Theme.Ink.ink3)
                Text(row.name).typeRole(.row).foregroundStyle(Theme.Ink.ink)
                    .lineLimit(1)
                Spacer(minLength: Theme.Metric.s8)
                Text(row.count == 1 ? "1 arrangement" : "\(row.count) arrangements")
                    .typeRole(.data).foregroundStyle(Theme.Ink.ink3).fixedSize()
            }
            .padding(.horizontal, Theme.Metric.s16)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.name)
        .accessibilityValue(row.isMember ? "in this set list" : "not in this set list")
        .accessibilityHint(row.isMember ? "Remove from this set list"
                                        : "Add to this set list")
        .accessibilityAddTraits(row.isMember ? [.isButton, .isSelected] : [.isButton])
        .accessibilityIdentifier("setlist-check-\(row.slug)")
    }

    private func switchRow(title: String, number: Int?, detail: String? = nil,
                           selected: Bool, id: String,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Theme.Metric.s8) {
                if let number { NumeralBadge(number: number, role: .numeralM) }
                if let detail {
                    Text(detail).typeRole(.data).foregroundStyle(Theme.Ink.ink3)
                        .fixedSize()
                }
                Text(title).typeRole(.row).foregroundStyle(Theme.Ink.ink).lineLimit(1)
                Spacer(minLength: Theme.Metric.s8)
                if selected {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.Accent.clayStrong)
                }
            }
            .padding(.horizontal, Theme.Metric.s16)
            .padding(.vertical, 8)
            .background(selected ? Theme.Accent.clayTint : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(detail.map { "\($0), \(title)" } ?? title)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : [.isButton])
        .accessibilityIdentifier(id)
    }
}

/// Which model answers (§7.3). The chat header's `Menu` becomes this.
struct ChatModelScreen: View {
    @EnvironmentObject var state: AppState
    var onBack: () -> Void

    var body: some View {
        Screen(title: "Model", backLabel: "Chat", onBack: onBack) {
            VStack(alignment: .leading, spacing: 0) {
                BandHeader("Models")
                if let catalog = state.modelCatalog {
                    ForEach(catalog.models.keys.sorted(), id: \.self) { alias in
                        ScreenRow(title: alias, value: catalog.models[alias],
                                  leads: false,
                                  identifier: "chat-model-\(alias)") {
                            state.chatModel = alias
                            onBack()
                        }
                    }
                } else {
                    Text("The model list loads once the engine is reachable.")
                        .typeRole(.meta).foregroundStyle(Theme.Ink.ink3)
                        .padding(Theme.Metric.s20)
                }
            }
            .padding(.bottom, Theme.Metric.s32)
        }
    }
}
